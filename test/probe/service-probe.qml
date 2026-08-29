import QtQuick
import Quickshell
import Quickshell.Io

// Loads the real Service.qml, waits for its read queue to drain, drives one
// env-selected scenario and prints a single "PROBE_RESULT {...}" JSON line.
// Debug counters are read through hasDebugCounters so older builds still run.
ShellRoot {
  id: probeRoot

  property var service: null
  property bool done: false
  property int elapsedMs: 0
  property bool hasDebugCounters: false
  // Quickshell sandboxes relative Loader.source to the entry file's own
  // directory -- a plain "../../Service.qml" silently resolves to a
  // blackhole. test/probe/run exports the plugin's absolute path instead.
  property string pluginDir: Quickshell.env("MULLVAD_PLUGIN_DIR")

  // Which extra scenario to drive after the initial read queue drains --
  // exactly one of these is ever true for a given run.
  property bool doubleLogin: Quickshell.env("MULLVAD_PROBE_DOUBLE_LOGIN") === "1"
  property bool actionOnly: Quickshell.env("MULLVAD_PROBE_ACTION_ONLY") === "1"
  property bool checkUpdatesMode: Quickshell.env("MULLVAD_PROBE_CHECK_UPDATES") === "1"
  // The `mullvad` binary vanishes mid-run: test/probe/run points
  // MULLVAD_MOCK_LINK at a temp symlink; this scenario deletes it to
  // simulate an uninstall, then drives Service.qml's own recovery path.
  property bool removedScenario: Quickshell.env("MULLVAD_PROBE_REMOVED") === "1"
  // daemon-down mode: toggleTunnel() must spawn nothing while daemonRunning
  // is false. noop just drains the read queue and reports, no action.
  property bool daemonDownScenario: Quickshell.env("MULLVAD_PROBE_DAEMON_DOWN") === "1"
  property bool noopScenario: Quickshell.env("MULLVAD_PROBE_NOOP") === "1"
  // State-truthfulness matrix: one of a/b/c/d/e/race/race-fail, or "" for
  // the scenarios above. Drives a scripted mullvad listener, recording
  // every observed transition until the expected final state settles.
  property string matrixKind: Quickshell.env("MULLVAD_PROBE_MATRIX") || ""
  property bool isRaceLike: matrixKind === "race" || matrixKind === "race-fail"
  property string matrixExpectFinal: ({
    a: "connected", b: "disconnected", c: "blocked", d: "connected", e: "connected",
    race: "connected", "race-fail": "connected"
  })[matrixKind] || ""
  property var matrixSteps: []
  property string _lastMatrixKey: ""
  property int _matrixStableTicks: 0
  property int _matrixElapsedMs: 0
  // _statusHistory entries before this offset predate the scenario (the
  // baseline pre-listener poll always applies once) -- excluded so
  // "a poll observed disconnected" proves the SCENARIO's poll, not that one.
  property int _matrixHistoryOffset: 0

  Loader {
    id: loader
    source: "file://" + probeRoot.pluginDir + "/Service.qml"
    active: true
    onLoaded: {
      probeRoot.service = item
      probeRoot.hasDebugCounters = ("_readWatchdogFiredCount" in item)
      // Short-circuit the production defaults so the hang-mode/action-hang/
      // updatecheck-hang tests don't take the full real deadlines. No-op
      // against an older Service.qml that doesn't have these properties yet.
      if ("readTimeoutMs" in item) item.readTimeoutMs = 1500
      if ("actionTimeoutMs" in item) item.actionTimeoutMs = 1500
      if ("updateCheckTimeoutMs" in item) item.updateCheckTimeoutMs = 1200
      if ("listenerRestartMs" in item) item.listenerRestartMs = 300
      // The race scenario's deliberately-slow poll (~1500ms) must not trip
      // the generic 1500ms read watchdog before it even returns its data.
      if (isRaceLike && "readTimeoutMs" in item) item.readTimeoutMs = 4000
      settleTimer.start()
    }
  }

  // Give the Service's own triggeredOnStart pollTimer a moment to enqueue
  // the initial read queue before polling `busy` for drain -- otherwise
  // this probe can race the same tick and see busy===false too early.
  Timer {
    id: settleTimer
    interval: 150
    repeat: false
    onTriggered: probeRoot._drainThen(probeRoot.afterReadsDrained)
  }

  // Generic "wait until the action/read queue is idle, then run a callback"
  // helper -- one reusable Timer drives the small chain of steps that
  // varies per scenario (see afterReadsDrained below).
  property var _afterBusy: null

  Timer {
    id: busyDrainTimer
    interval: 100
    repeat: true
    onTriggered: {
      probeRoot.elapsedMs += interval
      if (!probeRoot.service.busy) {
        busyDrainTimer.stop()
        var cb = probeRoot._afterBusy
        probeRoot._afterBusy = null
        if (cb) cb()
      } else if (probeRoot.elapsedMs > 20000) {
        busyDrainTimer.stop()
        probeRoot.finish("queue did not drain within 20s")
      }
    }
  }

  function _drainThen(cb) {
    elapsedMs = 0
    _afterBusy = cb
    busyDrainTimer.start()
  }

  // The "ok" scenario performs an action (connect) BEFORE logging in, then
  // logs in TWICE, proving stdin reuse across actions. "action-hang"
  // performs ONLY connect, to exercise the action watchdog in isolation.
  function afterReadsDrained() {
    elapsedMs = 0
    if (isRaceLike) {
      _matrixHistoryOffset = (debugProp("_statusHistory") || []).length
      raceTriggerProcess.command = ["touch", Quickshell.env("MULLVAD_MOCK_STATUS_DELAY_TRIGGER")]
      raceTriggerProcess.running = true
    } else if (matrixKind) {
      _matrixHistoryOffset = (debugProp("_statusHistory") || []).length
      matrixTimer.start()
    } else if (removedScenario) {
      removeLinkProcess.command = ["rm", "-f", Quickshell.env("MULLVAD_MOCK_LINK")]
      removeLinkProcess.running = true
    } else if (daemonDownScenario) {
      service.toggleTunnel()
      _drainThen(afterActions)
    } else if (noopScenario) {
      finish("")
    } else if (actionOnly) {
      service.connectTunnel()
      _drainThen(afterActions)
    } else if (doubleLogin) {
      service.connectTunnel()
      _drainThen(function() {
        service.login("1234567890123456")
        _drainThen(function() {
          service.login("1234567890123456")
          _drainThen(afterActions)
        })
      })
    } else {
      service.login("1234567890123456")
      _drainThen(afterActions)
    }
  }

  // Removes the temp `mullvad` symlink, then connectTunnel() while `installed`
  // is still stale-true (reaches the action failed-start path), then
  // refreshStatus() twice: the second one runs the probe that flips `installed`.
  Process {
    id: removeLinkProcess
    running: false
    onExited: function() {
      probeRoot.elapsedMs = 0
      probeRoot.service.connectTunnel()
      probeRoot._drainThen(function() {
        probeRoot.service.refreshStatus()
        probeRoot._drainThen(function() {
          probeRoot.service.refreshStatus()
          probeRoot._drainThen(probeRoot.afterActions)
        })
      })
    }
  }

  // Fires one manually-triggered, mock-delayed status poll (the poll vs.
  // listener race). touch's own exit guarantees the trigger file is
  // visible before refreshStatus() starts the real read.
  Process {
    id: raceTriggerProcess
    running: false
    onExited: function() {
      probeRoot.service.refreshStatus()
      matrixTimer.start()
      raceWaitTimer.start()
    }
  }

  // Fixed wait for the race scenario only: it must observe the outcome
  // AFTER the slow poll has had time to return and possibly (wrongly)
  // apply, not stop early just because the listener's value looked stable.
  Timer {
    id: raceWaitTimer
    interval: 2400
    repeat: false
    onTriggered: {
      matrixTimer.stop()
      probeRoot._matrixFinish("")
    }
  }

  // Records every distinct (state, disconnectingAction, tunnelDropWarning,
  // lastError) combination seen -- timing-robust against exact mock delay
  // drift, and it naturally captures every intermediate step.
  function _matrixSnapshot() {
    matrixSteps = matrixSteps.concat([{
      state: service.state,
      connected: service.connected,
      active: service.active,
      tunnelDropWarning: service.tunnelDropWarning,
      statusText: service.statusText,
      lastError: service.lastError,
      stateIcon: service.stateIcon,
      disconnectingAction: service.disconnectingAction,
      lastListenerLineChars: debugProp("_lastListenerLineChars")
    }])
  }

  Timer {
    id: matrixTimer
    interval: 50
    repeat: true
    onTriggered: {
      probeRoot._matrixElapsedMs += interval
      var key = probeRoot.service.state + "|" + probeRoot.service.disconnectingAction
        + "|" + probeRoot.service.tunnelDropWarning + "|" + probeRoot.service.lastError
      if (key !== probeRoot._lastMatrixKey) {
        probeRoot._lastMatrixKey = key
        probeRoot._matrixStableTicks = 0
        probeRoot._matrixSnapshot()
      } else {
        probeRoot._matrixStableTicks++
      }
      if (probeRoot.isRaceLike) return // raceWaitTimer owns finishing
      var settled = probeRoot.service.state === probeRoot.matrixExpectFinal && probeRoot._matrixStableTicks >= 6
      if (settled || probeRoot._matrixElapsedMs > 15000) {
        matrixTimer.stop()
        probeRoot._matrixFinish(settled ? "" : "matrix scenario did not reach its expected final state within 15s")
      }
    }
  }

  function _matrixFinish(note) {
    var trace = matrixSteps.map(function(s) { return s.state }).join(">")
    var sawDisconnectedMid = matrixSteps.some(function(s) { return s.state === "disconnected" })
    var history = (debugProp("_statusHistory") || []).slice(_matrixHistoryOffset)
    var sawPollDisconnected = false
    for (var i = 0; i < history.length; i++)
      if (history[i].source === "poll" && history[i].state === "disconnected") sawPollDisconnected = true
    var last = matrixSteps.length ? matrixSteps[matrixSteps.length - 1] : {}
    finish(note, {
      matrixKind: matrixKind,
      stepsTrace: trace,
      steps: matrixSteps,
      stepsCount: matrixSteps.length,
      sawDisconnectedMid: sawDisconnectedMid,
      sawPollDisconnected: sawPollDisconnected,
      lastListenerLineChars: debugProp("_lastListenerLineChars"),
      finalState: last.state,
      finalConnected: last.connected,
      finalActive: last.active,
      finalTunnelDropWarning: last.tunnelDropWarning,
      finalStatusText: last.statusText,
      finalStateIcon: last.stateIcon,
      finalLastError: last.lastError,
      finalDisconnectingAction: last.disconnectingAction
    })
  }

  // updateCheckProcess is a separate process/timer, never counted in
  // `busy`, so it is driven as its own step after the scenario above
  // finishes, only when test/probe/run asked for it.
  function afterActions() {
    if (checkUpdatesMode) {
      service.checkForUpdates()
      elapsedMs = 0
      updateCheckDrainTimer.start()
    } else {
      finish("")
    }
  }

  Timer {
    id: updateCheckDrainTimer
    interval: 100
    repeat: true
    onTriggered: {
      probeRoot.elapsedMs += interval
      if (probeRoot.service.updateCheckStatus !== "checking") {
        updateCheckDrainTimer.stop()
        probeRoot.finish("")
      } else if (probeRoot.elapsedMs > 10000) {
        updateCheckDrainTimer.stop()
        probeRoot.finish("update check did not settle within 10s")
      }
    }
  }

  function debugProp(name) {
    return (service && (name in service)) ? service[name] : null
  }

  function finish(note, extra) {
    if (done) return
    done = true
    var summary = {
      installed: service.installed,
      daemonRunning: service.daemonRunning,
      state: service.state,
      cliVersion: service.cliVersion,
      cliVersionSupported: service.cliVersionSupported,
      locationsLength: (service.locations || []).length,
      lastError: service.lastError,
      actionStatus: service.actionStatus,
      busy: service.busy,
      hasDebugCounters: hasDebugCounters,
      readWatchdogFiredCount: debugProp("_readWatchdogFiredCount"),
      actionWatchdogFiredCount: debugProp("_actionWatchdogFiredCount"),
      readOverflowCount: debugProp("_readOverflowCount"),
      actionOverflowCount: debugProp("_actionOverflowCount"),
      readOutputChars: debugProp("_readOutputChars"),
      packagesLength: (service.packages || []).length,
      excludedProcessesLength: (service.excludedProcesses || []).length,
      excludedGroupCount: debugProp("excludedGroupCount"),
      updateCheckStatus: service.updateCheckStatus,
      updateTargetsLength: (service.updateTargets || []).length,
      updateCheckWatchdogFiredCount: debugProp("_updateCheckWatchdogFiredCount"),
      note: note
    }
    for (var key in (extra || {})) summary[key] = extra[key]
    console.log("PROBE_RESULT " + JSON.stringify(summary))
    Qt.quit()
  }

  // Whole-probe-run backstop: never hang test/probe/run itself if
  // something above never calls finish().
  Timer {
    interval: 25000
    running: true
    repeat: false
    onTriggered: probeRoot.finish("probe harness overall timeout (25s)")
  }
}
