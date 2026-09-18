import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root
  property var service: null
  property int elapsed: 0
  property bool finished: false
  property bool removedRefreshStarted: false
  property bool launchRejected: false
  property bool launchAccepted: false
  property bool busyDuringUpdateCheck: false
  property string scenario: Quickshell.env("MULLVAD_PROBE_SCENARIO")
  property var observedStates: []
  property string lastObservedState: ""

  Loader {
    id: loader
    source: "file://" + Quickshell.env("MULLVAD_PLUGIN_DIR") + "/Service.qml"
    onLoaded: {
      root.service = item
      item.readTimeoutMs = 800
      item.actionTimeoutMs = 800
      item.updateCheckTimeoutMs = 800
      stateSampler.start()
      settle.start()
    }
  }

  Timer {
    id: settle
    interval: 100
    onTriggered: drain.start()
  }

  Timer {
    id: drain
    interval: 50
    repeat: true
    onTriggered: {
      root.elapsed += interval
      if (!root.service.busy && root.service._readQueue.length === 0 && root.service._readKind === "") {
        stop()
        if (root.scenario === "removed" && !root.removedRefreshStarted) {
          root.removedRefreshStarted = true
          root.elapsed = 0
          root.service._enqueueRead("probe", ["/definitely/missing/oma-mullvad-test"])
          start()
        } else if (root.scenario === "action-hang") {
          root.elapsed = 0
          root.service.logout()
          actionDrain.start()
        } else if (root.scenario === "login") {
          root.elapsed = 0
          root.service.login("1234567890123456")
          actionDrain.start()
        } else if (root.scenario === "listener-flood") {
          root.elapsed = 0
          listenerDrain.start()
        } else if (root.scenario === "state-sequence") {
          sequenceWait.start()
        } else if (root.scenario === "status-race") {
          raceTrigger.command = ["touch", Quickshell.env("MULLVAD_MOCK_STATUS_DELAY_TRIGGER")]
          raceTrigger.running = true
        } else if (root.scenario === "launch-result") {
          root.service.installed = true
          root.launchRejected = root.service.launchExcludedApp("../bad.desktop") === false
          root.launchAccepted = root.service.launchExcludedApp("Zoom (Web).desktop") === true
          root.finish("")
        } else if (root.scenario === "system") {
          root.service.checkForUpdates()
          root.busyDuringUpdateCheck = root.service.busy
          root.elapsed = 0
          updateDrain.start()
        } else if (root.scenario === "stale-diagnostics") {
          root.service.daemonVersion = "stale"
          root.service.daemonSupported = true
          root.service.suggestedUpgrade = "stale"
          root.service.packages = [{ name: "mullvad-vpn", version: "stale" }]
          root.service._applyRead("daemonVersion", "", "failed", 1)
          root.service._applyRead("packageInfo", "", "failed", 1)
          root.finish("")
        } else if (root.scenario === "automatic-update-refresh") {
          root.service.updateCheckStatus = "never"
          root.service.updateCheckedAt = 0
          root.service._updateCheckAttemptedAt = 0
          root.service._autoUpdateCheckPending = true
          root.service._applyRead("packageInfo", "mullvad-vpn\t2026.4-1\tMullvad VPN\t2026-09-01 12:00", "", 0)
          root.elapsed = 0
          updateDrain.start()
        } else root.finish("")
      } else if (root.elapsed > 10000) root.finish("read queue did not drain")
    }
  }

  Timer {
    id: listenerDrain
    interval: 50
    repeat: true
    onTriggered: {
      root.elapsed += interval
      if (root.service._listenerOverflowCount > 0) {
        stop()
        root.finish("")
      } else if (root.elapsed > 5000) root.finish("listener output limit did not fire")
    }
  }

  Timer {
    id: stateSampler
    interval: 20
    repeat: true
    onTriggered: {
      if (!root.service || root.service.state === root.lastObservedState) return
      root.lastObservedState = root.service.state
      root.observedStates = root.observedStates.concat([root.service.state])
    }
  }

  Timer {
    id: sequenceWait
    interval: 1300
    onTriggered: root.finish("")
  }

  Process {
    id: raceTrigger
    running: false
    onExited: function() {
      root.service.readTimeoutMs = 3000
      root.service.refreshStatus()
      raceWait.start()
    }
  }

  Timer {
    id: raceWait
    interval: 1800
    onTriggered: root.finish("")
  }

  Timer {
    id: updateDrain
    interval: 50
    repeat: true
    onTriggered: {
      root.elapsed += interval
      if (root.service.updateCheckStatus !== "checking") {
        stop()
        root.finish("")
      } else if (root.elapsed > 5000) root.finish("update check did not finish")
    }
  }

  Timer {
    id: actionDrain
    interval: 50
    repeat: true
    onTriggered: {
      root.elapsed += interval
      if (!root.service.busy && root.service._readQueue.length === 0 && root.service._readKind === "") {
        stop()
        root.finish("")
      }
      else if (root.elapsed > 10000) root.finish("action did not drain")
    }
  }

  function finish(note) {
    if (finished) return
    finished = true
    console.log("PROBE_RESULT " + JSON.stringify({
      installed: service.installed,
      cliVersion: service.cliVersion,
      cliVersionSupported: service.cliVersionSupported,
      daemonRunning: service.daemonRunning,
      locations: service.locations.length,
      excludedProcessesLength: service.excludedProcesses.length,
      excludedGroupCount: service.excludedGroupCount,
      lastError: service.lastError,
      actionStatus: service.actionStatus,
      readWatchdogs: service._readWatchdogFiredCount,
      actionWatchdogs: service._actionWatchdogFiredCount,
      readOverflows: service._readOverflowCount,
      listenerOverflows: service._listenerOverflowCount,
      readChars: service._readOutputChars,
      stateTrace: root.observedStates.join(">"),
      finalState: service.state,
      finalConnected: service.connected,
      scenario: root.scenario,
      removedRefreshStarted: root.removedRefreshStarted,
      launchRejected: root.launchRejected,
      launchAccepted: root.launchAccepted,
      daemonVersion: service.daemonVersion,
      daemonSupported: service.daemonSupported,
      daemonPid: service.daemonPid,
      packageCount: service.packages.length,
      updateCheckStatus: service.updateCheckStatus,
      updateCheckedAt: service.updateCheckedAt,
      updateResultCount: service.updateResults.length,
      updateCheckWatchdogs: service._updateCheckWatchdogFiredCount,
      updateCheckOverflows: service._updateCheckOverflowCount,
      busyDuringUpdateCheck: root.busyDuringUpdateCheck,
      note: note
    }))
    Qt.quit()
  }

  Timer {
    interval: 15000
    running: true
    onTriggered: root.finish("overall timeout")
  }
}
