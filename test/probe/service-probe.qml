import QtQuick
import Quickshell

// test/probe/service-probe.qml -- deterministic mock-CLI probe for
// Service.qml (exchange/23-s10-native-process-spec.md). A ShellRoot that
// Loaders the real Service.qml (never a copy), waits for the initial read
// queue to drain, drives login("1234567890123456"), then prints ONE
// "PROBE_RESULT {...}" JSON line to stdout and quits. test/probe/run drives
// this once per MULLVAD_MOCK_MODE (ok/hang/flood/fail) with
// PATH=test/mocks:$PATH so every `mullvad` invocation resolves to the mock
// -- this file never talks to the real daemon.
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

  Loader {
    id: loader
    source: "file://" + probeRoot.pluginDir + "/Service.qml"
    active: true
    onLoaded: {
      probeRoot.service = item
      probeRoot.hasDebugCounters = ("_readWatchdogFiredCount" in item)
      // Short-circuit the production defaults so the hang-mode test doesn't
      // take the full 10s/20s real deadlines (23-s10-native-process-spec.md
      // "Timing"). No-op against the pre-rework Service.qml, which doesn't
      // have these properties yet.
      if ("readTimeoutMs" in item) item.readTimeoutMs = 1500
      if ("actionTimeoutMs" in item) item.actionTimeoutMs = 3000
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
    onTriggered: drainTimer.start()
  }

  Timer {
    id: drainTimer
    interval: 100
    repeat: true
    onTriggered: {
      probeRoot.elapsedMs += interval
      if (!probeRoot.service.busy) {
        drainTimer.stop()
        probeRoot.afterReadsDrained()
      } else if (probeRoot.elapsedMs > 20000) {
        drainTimer.stop()
        probeRoot.finish("read queue did not drain within 20s")
      }
    }
  }

  function afterReadsDrained() {
    elapsedMs = 0
    service.login("1234567890123456")
    loginDrainTimer.start()
  }

  Timer {
    id: loginDrainTimer
    interval: 100
    repeat: true
    onTriggered: {
      probeRoot.elapsedMs += interval
      if (!probeRoot.service.busy) {
        loginDrainTimer.stop()
        probeRoot.finish("")
      } else if (probeRoot.elapsedMs > 20000) {
        loginDrainTimer.stop()
        probeRoot.finish("login action did not drain within 20s")
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
