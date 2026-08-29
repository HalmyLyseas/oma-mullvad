import QtQuick
import Quickshell

// test/probe/service-probe.qml -- deterministic mock-CLI probe for
// Service.qml (exchange/23-s10-native-process-spec.md, extended by N6 in
// exchange/25-fable-review-s10.md). A ShellRoot that Loaders the real
// Service.qml (never a copy), waits for the initial read queue to drain,
// then drives one of a few scenarios selected by env vars test/probe/run
// sets per invocation, and prints one "PROBE_RESULT {...}" JSON line to
// stdout and quits. test/probe/run drives this once per scenario with
// PATH=test/mocks:$PATH so every `mullvad`/`checkupdates` invocation
// resolves to a mock -- this file never talks to the real daemon.
//
// Written to run unchanged against BOTH the pre-rework and post-rework
// Service.qml: debug counters (`_readWatchdogFiredCount` etc.) only exist
// after the S10 rework, so every read of one goes through hasDebugCounters
// guard below rather than assuming presence.
ShellRoot {
  id: probeRoot

  property var service: null
  property bool done: false
  property int elapsedMs: 0
  property bool hasDebugCounters: false
  // Quickshell sandboxes relative Loader.source resolution to the entry
  // file's own directory -- a plain "../../Service.qml" silently resolves to
  // "qrc:/qs-blackhole" instead of erroring (measured live on this box,
  // Quickshell 0.3.1). test/probe/run exports the plugin's absolute path so
  // this file never needs a relative upward traversal.
  property string pluginDir: Quickshell.env("MULLVAD_PLUGIN_DIR")

  // N6 (25-fable-review-s10.md): which extra scenario to drive after the
  // initial read queue drains, selected per test/probe/run invocation.
  // Exactly one of these is ever true for a given run (test/probe/run never
  // sets more than one).
  property bool doubleLogin: Quickshell.env("MULLVAD_PROBE_DOUBLE_LOGIN") === "1"
  property bool actionOnly: Quickshell.env("MULLVAD_PROBE_ACTION_ONLY") === "1"
  property bool checkUpdatesMode: Quickshell.env("MULLVAD_PROBE_CHECK_UPDATES") === "1"

  Loader {
    id: loader
    source: "file://" + probeRoot.pluginDir + "/Service.qml"
    active: true
    onLoaded: {
      probeRoot.service = item
      probeRoot.hasDebugCounters = ("_readWatchdogFiredCount" in item)
      // Short-circuit the production defaults so the hang-mode/action-hang/
      // updatecheck-hang tests don't take the full 10s/20s/130s real
      // deadlines (23-s10-native-process-spec.md "Timing"; updateCheckTimeoutMs
      // gained the same probe-shortenable treatment in N6). No-op against
      // the pre-rework Service.qml, which doesn't have these properties yet.
      if ("readTimeoutMs" in item) item.readTimeoutMs = 1500
      if ("actionTimeoutMs" in item) item.actionTimeoutMs = 1500
      if ("updateCheckTimeoutMs" in item) item.updateCheckTimeoutMs = 1200
      settleTimer.start()
    }
  }

  // Give the Service's own triggeredOnStart pollTimer a moment to enqueue
  // the initial read queue before polling `busy` for drain -- otherwise this
  // probe can race the same-tick window and see busy===false before
  // refreshAll() has actually run.
  Timer {
    id: settleTimer
    interval: 150
    repeat: false
    onTriggered: probeRoot._drainThen(probeRoot.afterReadsDrained)
  }

  // Generic "wait until the action/read queue is idle, then run a callback"
  // helper -- N6 replaces the old fixed two-step (drain reads, drain one
  // login) with a small chain of steps that varies per scenario (see
  // afterReadsDrained below), so one reusable Timer replaces what would
  // otherwise be one bespoke Timer per step.
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

  // N1 (25-fable-review-s10.md): the "ok" scenario performs an action
  // (connect) BEFORE logging in, then logs in TWICE -- proving stdin reuse
  // across actions (without the fix, only the first action's stdin write
  // ever reaches a live pipe; every later one writes into a stdin the
  // previous action's `onStarted` already closed). The "action-hang"
  // scenario performs ONLY connect (it exists to exercise the action
  // watchdog in isolation; a subsequent login would just overwrite the
  // watchdog-time lastError with its own success text). Every other
  // scenario (fail/hang/flood) keeps the original single-login shape.
  function afterReadsDrained() {
    elapsedMs = 0
    if (actionOnly) {
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

  // N6: updateCheckProcess is a separate process/timer from the read/action
  // queue (never counted in `busy`), so it is driven as its own step after
  // the queue-based scenario above finishes, only when test/probe/run asked
  // for it.
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

  // Whole-probe-run backstop: the pre-rework Service.qml recovers hang/flood
  // modes via scripts/bounded-command's own timeout/head caps (~10s), not a
  // QML watchdog -- give it enough room, but never hang test/probe/run
  // itself if something above never calls finish().
  Timer {
    interval: 25000
    running: true
    repeat: false
    onTriggered: probeRoot.finish("probe harness overall timeout (25s)")
  }
}
