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
    if (removedScenario) {
      removeLinkProcess.command = ["rm", "-f", Quickshell.env("MULLVAD_MOCK_LINK")]
      removeLinkProcess.running = true
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

  function finish(note) {
    if (done) return
    done = true
    var summary = {
      installed: service.installed,
      daemonRunning: service.daemonRunning,
      state: service.state,
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
      updateCheckStatus: service.updateCheckStatus,
      updateTargetsLength: (service.updateTargets || []).length,
      updateCheckWatchdogFiredCount: debugProp("_updateCheckWatchdogFiredCount"),
      note: note
    }
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
