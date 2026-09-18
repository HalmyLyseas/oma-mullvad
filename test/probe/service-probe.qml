import QtQuick
import Quickshell
import Quickshell.Io
import "../../Model.js" as Model

ShellRoot {
  id: root
  property var service: null
  property int elapsed: 0
  property bool finished: false
  property bool removedRefreshStarted: false
  property bool busyGateObserved: false
  property int mutationStep: 0
  property bool partialFailureObserved: false
  property bool recoverySucceeded: false
  property int availabilityRecoveryPhase: 0
  property bool cliDisappeared: false
  property bool cliRecovered: false
  property bool daemonDisappeared: false
  property bool daemonRecovered: false
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
          root.service.login(Array(17).join("0"))
          actionDrain.start()
        } else if (root.scenario === "mutations") {
          root.elapsed = 0
          root.runMutationStep()
        } else if (root.scenario === "partial-batch") {
          root.mutationStep = 1
          root.service.removeExcludedPid(1234)
          root.service.removeExcludedPid(5678)
          actionDrain.start()
        } else if (root.scenario === "availability-recovery") {
          if (root.availabilityRecoveryPhase === 0) {
            root.availabilityRecoveryPhase = 1
            root.elapsed = 0
            availabilityTrigger.command = ["touch", Quickshell.env("MULLVAD_MOCK_AVAILABILITY_TRIGGER")]
            availabilityTrigger.running = true
          } else if (root.availabilityRecoveryPhase === 1) {
            root.cliDisappeared = root.cliDisappeared || !root.service.installed
            root.availabilityRecoveryPhase = 2
            root.elapsed = 0
            root.service.refreshStatus()
            drain.start()
          } else if (root.availabilityRecoveryPhase === 2) {
            root.cliRecovered = root.cliRecovered || root.service.installed
            root.daemonDisappeared = root.daemonDisappeared || !root.service.daemonRunning
            root.availabilityRecoveryPhase = 3
            root.elapsed = 0
            root.service.refreshStatus()
            drain.start()
          } else {
            root.cliRecovered = root.cliRecovered || root.service.installed
            root.daemonRecovered = root.daemonRecovered || root.service.daemonRunning
            root.finish("")
          }
        } else if (root.scenario === "listener-flood") {
          root.elapsed = 0
          listenerDrain.start()
        } else if (root.scenario === "state-sequence" || root.scenario === "listener-malformed") {
          sequenceWait.start()
        } else if (root.scenario === "status-race") {
          raceTrigger.command = ["touch", Quickshell.env("MULLVAD_MOCK_STATUS_DELAY_TRIGGER")]
          raceTrigger.running = true
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
    onTriggered: root.finish(root.scenario === "listener-malformed" ? root.checkListenerChunks() : "")
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

  Process {
    id: availabilityTrigger
    running: false
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.finish("availability trigger failed"); return }
      root.service.refreshAll()
      drain.start()
    }
  }

  Timer {
    id: raceWait
    interval: 1800
    onTriggered: root.finish("")
  }

  Timer {
    id: actionDrain
    interval: 50
    repeat: true
    onTriggered: {
      root.elapsed += interval
      if (!root.service.busy && root.service._readQueue.length === 0 && root.service._readKind === "") {
        stop()
        if (root.scenario === "mutations") root.runMutationStep()
        else if (root.scenario === "partial-batch" && root.mutationStep === 1) {
          root.partialFailureObserved = root.service.lastError !== ""
          root.mutationStep = 2
          root.service.disconnectTunnel()
          start()
        } else if (root.scenario === "partial-batch") {
          root.recoverySucceeded = root.service.lastError === ""
          root.finish("")
        } else root.finish("")
      }
      else if (root.elapsed > 10000) root.finish("action did not drain")
    }
  }

  function runMutationStep() {
    mutationStep++
    if (mutationStep === 1) {
      prepareMutationRelay()
      service.connectTunnel()
      service.connectTunnel()
      busyGateObserved = service.actionStatus.indexOf("Wait for") !== -1
    } else if (mutationStep === 2) service.disconnectTunnel()
    else if (mutationStep === 3) {
      prepareMutationRelay()
      service.selectLocation("se", "got", true)
    } else if (mutationStep === 4) {
      prepareMutationRelay()
      service.selectLocation("se", "got", false, "se-got-wg-001")
    } else if (mutationStep === 5) {
      prepareMutationRelay()
      service.setLockdown(true)
      service.setAutoConnect(true)
      service.setLanSharing(true)
      service.setProviders(["Example"])
      service.setOwnership("owned")
      service.setIpVersion("ipv4")
      service.setMultihop(true)
      service.setEntryLocation("se", "got")
      service.setDnsDefault({ blockAds: true, blockMalware: true })
      service.setDnsCustom(" 1.1.1.1, ")
      service.setAntiCensorshipMode("udp2tcp")
      service.setAntiCensorshipPort("udp2tcp", 443)
    } else if (mutationStep === 6) service.login(Array(17).join("0"))
    else if (mutationStep === 7) {
      service.launchExcludedApp("org.example.Safe.desktop")
      service.logout()
      service.removeExcludedPid(1234)
      service.removeExcludedPid(5678)
    } else {
      finish("")
      return
    }
    actionDrain.start()
  }

  function prepareMutationRelay() {
      service.locations = [{
        countryCode: "se", cityCode: "got", country: "Sweden", city: "Gothenburg",
        latitude: 57.7, longitude: 11.9,
        servers: [{ hostname: "se-got-wg-001", provider: "Example", ownership: "owned",
                    ips: ["192.0.2.1", "2001:db8::1"], active: true }]
      }]
      service.relayConstraints = {
        location: { type: "city", countryCode: "se", cityCode: "got" },
        providers: [], ownership: "any", ipVersion: "any", multihop: false, entry: {}
      }
  }

  function checkListenerChunks() {
    if (service.state !== "disconnected" || service.connected)
      return "malformed mock listener event swallowed the disconnect"
    service._applyListenerLine('{"state":"connected","details":{}}', false)
    var seq = service._statusSeq
    try {
      service._appendListenerChunk('{"state":{"toString":null}}\n{"settings":{}}\n{"relay_list":{}}\n'
        + '{"state":"connected","details":7}\n{"state":"disconnected","details":{}}\n', false)
    } catch (e) { return "listener chunk escaped: " + e }
    if (service.state !== "disconnected" || service.connected)
      return "malformed line swallowed the same-chunk disconnect"
    if (service._statusSeq !== seq + 1 || service._statusApplySeq !== seq + 1)
      return "invalid or non-tunnel lines consumed status sequence numbers"
    return ""
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
      busyGateObserved: root.busyGateObserved,
      mutationStep: root.mutationStep,
      partialFailureObserved: root.partialFailureObserved,
      recoverySucceeded: root.recoverySucceeded,
      cliDisappeared: root.cliDisappeared,
      cliRecovered: root.cliRecovered,
      daemonDisappeared: root.daemonDisappeared,
      daemonRecovered: root.daemonRecovered,
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
