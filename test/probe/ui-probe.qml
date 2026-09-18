import QtQuick
import Quickshell

ShellRoot {
  id: root
  property string pluginDir: Quickshell.env("MULLVAD_PLUGIN_DIR")
  property string scenario: Quickshell.env("MULLVAD_UI_SCENARIO")
  property var service: null
  property var widget: null
  property bool finished: false
  property int reloadPhase: 0
  property var originalService: null
  property var interactionValues: null
  property int interactionPhase: 0
  property var advancedControl: null


  QtObject {
    id: shell
    property var serviceInstance: null
    readonly property var appLibrary: null
    property string lastUpdateId: ""
    property var lastUpdatePayload: null
    function serviceFor(id) {
      return id === "halmylyseas.oma-mullvad" ? serviceInstance : null
    }
    function updateEntryInline(id, entry) {
      if (id !== "halmylyseas.oma-mullvad") return
      lastUpdateId = id
      lastUpdatePayload = entry
    }
  }

  QtObject {
    id: replacementShell
    readonly property var appLibrary: null
    function serviceFor(id) { return null }
    function updateEntryInline(id, entry) {}
  }

  QtObject {
    id: bar
    property color foreground: "#eeeeee"
    property color background: "#111111"
    property color urgent: "#ff5555"
    property color barForeground: "#eeeeee"
    property string fontFamily: "monospace"
    property string position: "top"
    property bool vertical: false
    property int barSize: 26
    property bool foregroundAnimationEnabled: false
    property var shell: shell
    property var activePopout: null
    property var clickTargets: []
    function run(command) {}
    function shellQuote(value) { return String(value) }
    function showTooltip(target, text) {}
    function hideTooltip(target) {}
    function requestPopout(owner) { activePopout = owner }
    function releasePopout(owner) { if (activePopout === owner) activePopout = null }
    function moduleWidgets(name) { return root.widget ? [root.widget] : [] }
    function registerClickTarget(target) {}
    function unregisterClickTarget(target) {}
  }

  Loader {
    id: serviceLoader
    source: "file://" + root.pluginDir + "/Service.qml"
    onLoaded: {
      root.service = item
      shell.serviceInstance = item
      widgetLoader.active = true
    }
  }

  Loader {
    id: widgetLoader
    active: false
    source: "file://" + root.pluginDir + "/BarWidget.qml"
    onLoaded: {
      root.widget = item
      item.bar = bar
      item.settings = ({ refreshIntervalSec: 30 })
      settle.start()
    }
  }

  Timer {
    id: settle
    interval: 200
    onTriggered: waitForReady.start()
  }

  Timer {
    id: waitForReady
    property int elapsed: 0
    interval: 50
    repeat: true
    onTriggered: {
      elapsed += interval
      var idle = root.service && !root.service.busy
        && root.service._readQueue.length === 0 && root.service._readKind === ""
      if (idle && root.widget && root.widget._probePanelItem) {
        stop()
        root.runScenario()
      } else if (elapsed > 10000) root.finish("UI did not become ready")
    }
  }

  function runScenario() {
    if (scenario === "action-feedback") {
      var feedbackPanel = widget._probePanelItem
      feedbackPanel.open()
      service.lastError = ""
      service.actionStatus = "Updating lockdown…"
      Qt.callLater(function() {
        var label = root.findNamed(feedbackPanel._probePageItem, "overviewActionStatus")
        if (!label) { root.finish("Overview action feedback is missing"); return }
        var message = label.text
        service.lastError = service.actionStatus
        root.finish("", { message: message, duplicateHidden: !label.visible,
          plainText: label.textFormat === Text.PlainText })
      })
    } else if (scenario === "state-icons") {
      service.installed = true
      service.daemonRunning = true
      service.state = "connected"
      service.connected = true
      var connectedIcon = widget.stateIcon
      service.state = "error"
      service.connected = false
      service.tunnelDropWarning = true
      finish("", {
        panelLoaded: widget._probePanelItem !== null,
        panelServiceMatches: widget._probePanelItem.service === service,
        connectedIcon: connectedIcon,
        errorIcon: widget.stateIcon,
        errorTooltip: widget.barTooltip
      })
    } else if (scenario === "widget-reload") {
      if (reloadPhase === 0) {
        reloadPhase = 1
        originalService = service
        widgetLoader.active = false
        reloadWait.start()
      } else finish("", {
        sameService: shell.serviceFor("halmylyseas.oma-mullvad") === originalService,
        panelServiceMatches: widget._probePanelItem && widget._probePanelItem.service === originalService
      })
    } else if (scenario === "replacement-bar") {
      bar.shell = replacementShell
      replacementWait.start()
    } else if (scenario === "facade-contract") {
      shell.updateEntryInline("foreign.plugin", { value: 1 })
      var foreignIgnored = shell.lastUpdateId === ""
      shell.updateEntryInline("halmylyseas.oma-mullvad", { refreshIntervalSec: 45 })
      bar.requestPopout(widget)
      var popupOwned = bar.activePopout === widget
      bar.releasePopout(widget)
      finish("", {
        ownService: shell.serviceFor("halmylyseas.oma-mullvad") === service,
        foreignServiceNull: shell.serviceFor("foreign.plugin") === null,
        appLibraryNull: shell.appLibrary === null,
        foreignUpdateIgnored: foreignIgnored,
        ownUpdateRecorded: shell.lastUpdateId === "halmylyseas.oma-mullvad",
        scalarPropertiesUsable: widget.foreground === bar.foreground && widget.barForeground === bar.barForeground,
        popupOwned: popupOwned,
        popupReleased: bar.activePopout === null
      })
    } else if (scenario === "lifecycle") {
      var firstLoaded = widget._probePanelItem !== null
      shell.serviceInstance = null
      serviceLoader.active = false
      lifecycleWait.start()
      lifecycleWait.firstLoaded = firstLoaded
    } else if (scenario === "availability-cli" || scenario === "availability-daemon" || scenario === "availability-ready") {
      var panel = widget._probePanelItem
      service.installed = scenario !== "availability-cli"
      service.daemonRunning = scenario === "availability-ready"
      panel.showPage(2)
      var dependentSelectedPage = panel.pageIndex
      panel.showPage(4)
      finish("", {
        cliReady: panel.cliReady,
        overviewAvailable: panel.pageAvailable(0),
        locationsAvailable: panel.pageAvailable(1),
        advancedAvailable: panel.pageAvailable(2),
        excludedAvailable: panel.pageAvailable(3),
        systemAvailable: panel.pageAvailable(4),
        selectedPage: dependentSelectedPage,
        systemSelectedPage: panel.pageIndex,
        systemPageLoaded: panel._probePageItem !== null,
        barTooltip: widget.barTooltip
      })
    } else if (scenario === "local-app-catalogue") {
      var cataloguePanel = widget._probePanelItem
      service.installed = true
      service.daemonRunning = true
      cataloguePanel.showPage(3)
      Qt.callLater(function() {
        root.finish("", {
          selectedPage: cataloguePanel.pageIndex,
          appLibraryNull: shell.appLibrary === null,
          ownService: shell.serviceFor("halmylyseas.oma-mullvad") === service,
          foreignServiceNull: shell.serviceFor("foreign.plugin") === null,
          excludedMetadataCount: cataloguePanel.excludedApps().length,
          emptyText: cataloguePanel.appEmptyText
        })
      })
    } else if (scenario === "recent-apps") {
      var recentPanel = widget._probePanelItem
      service.installed = true
      service.daemonRunning = true
      recentPanel.showPage(3)
      var values = DesktopEntries.applications.values || []
      var usable = []
      for (var i = 0; i < values.length && usable.length < 2; i++)
        if (values[i] && values[i].id && !values[i].noDisplay) usable.push(values[i])
      if (!usable.length) {
        finish("desktop entry catalogue is empty")
        return
      }
      recentPanel.recentExcludedApps = usable.map(function(entry) { return String(entry.id) })
      recentPanel.appQuery = ""
      var recentRows = recentPanel.appRows()
      recentPanel.appQuery = String(usable[0].name || usable[0].id).slice(0, 3)
      var searchRows = recentPanel.appRows()
      recentPanel.recordLaunchedApp(String(usable[0].id))
      var queryAfterLaunch = recentPanel.appQuery
      recentPanel.appQuery = "stale"
      recentPanel.showPage(2)
      finish("", {
        recentCount: recentRows.length,
        recentFirst: recentRows.length ? String(recentRows[0].id) : "",
        searchCount: searchRows.length,
        queryAfterLaunch: queryAfterLaunch,
        queryAfterLeave: recentPanel.appQuery,
        updateId: shell.lastUpdateId,
        savedRecentFirst: shell.lastUpdatePayload && shell.lastUpdatePayload.recentExcludedApps
          ? String(shell.lastUpdatePayload.recentExcludedApps[0]) : "",
        refreshIntervalSec: shell.lastUpdatePayload ? shell.lastUpdatePayload.refreshIntervalSec : 0
      })
    } else if (scenario === "launch-result") {
      var launchPanel = widget._probePanelItem
      service.installed = true
      service.daemonRunning = true
      launchPanel.open()
      launchPanel.appQuery = "keep"
      var rejected = launchPanel.launchExcludedApp("../bad.desktop") === false
      var failurePreserved = launchPanel.opened && launchPanel.appQuery === "keep"
        && shell.lastUpdateId === ""
      launchResultWait.panel = launchPanel
      launchResultWait.rejected = rejected
      launchResultWait.failurePreserved = failurePreserved
      launchResultWait.start()
    } else if (scenario === "settings-fresh-merge") {
      var settingsPanel = widget._probePanelItem
      widget.settings = ({ refreshIntervalSec: 99, siblingValue: "preserve-me",
                           favoriteLocations: [], recentLocations: [], recentExcludedApps: [] })
      settingsPanel.settings = ({ refreshIntervalSec: 30, siblingValue: "stale",
                                  favoriteLocations: [], recentLocations: [], recentExcludedApps: [] })
      settingsPanel.toggleFavorite({ countryCode: "se", cityCode: "got", country: "Sweden", city: "Gothenburg" })
      finish("", {
        refreshIntervalSec: shell.lastUpdatePayload ? shell.lastUpdatePayload.refreshIntervalSec : 0,
        siblingValue: shell.lastUpdatePayload ? String(shell.lastUpdatePayload.siblingValue || "") : "",
        favoriteCount: shell.lastUpdatePayload && shell.lastUpdatePayload.favoriteLocations
          ? shell.lastUpdatePayload.favoriteLocations.length : 0
      })
    } else if (scenario === "interactive-controls") {
      var controlsPanel = widget._probePanelItem
      service.installed = true
      service.daemonRunning = true
      service.locations = [
        { countryCode: "se", cityCode: "got", country: "Sweden", city: "Gothenburg",
          latitude: 57.7, longitude: 11.9,
          servers: [{ hostname: "se-got-wg-001", provider: "Example", ownership: "owned", active: true }] },
        { countryCode: "de", cityCode: "ber", country: "Germany", city: "Berlin",
          latitude: 52.5, longitude: 13.4,
          servers: [{ hostname: "de-ber-wg-001", provider: "Example", ownership: "owned", active: true }] }
      ]
      service.relayConstraints = {
        location: { type: "city", countryCode: "se", cityCode: "got" },
        providers: [], ownership: "any", ipVersion: "any", multihop: false, entry: {}
      }
      Qt.callLater(function() {
        controlsPanel.handleTextKey("2")
        var tabsWorked = controlsPanel.pageIndex === 1 && controlsPanel._probePageItem !== null
        var visualParent = controlsPanel._probePageItem
        var dropdownComponent = Qt.createComponent("file://" + root.pluginDir + "/OmaDropdown.qml")
        var dropdown = dropdownComponent.createObject(visualParent, {
          x: 0, y: 0, width: 320, options: [
            { value: "se", label: "Sweden" }, { value: "ber", label: "Berlin" }
          ], value: "se"
        })
        var searchableComponent = Qt.createComponent("file://" + root.pluginDir + "/OmaSearchableDropdown.qml")
        var searchable = searchableComponent.createObject(visualParent, {
          x: 0, y: 70, width: 320, options: [
            { value: "se", label: "Sweden" }, { value: "de", label: "Germany" }
          ], value: ""
        })
        var mapComponent = Qt.createComponent("file://" + root.pluginDir + "/WorldMap.qml")
        var map = mapComponent.createObject(visualParent, {
          x: 0, y: 140, width: 360, height: 180, locations: service.locations,
          selectedPoint: service.locations[1]
        })
        var dropdownChanged = ""
        dropdown.changed.connect(function(value) {
          dropdownChanged = value
          if (value === "ber") controlsPanel.chooseLocation(service.locations[1], false)
        })
        dropdown.focusTrigger()
        dropdown.handleTriggerKey(Qt.Key_Space)
        dropdown.handlePopupKey(Qt.Key_Down, "")
        dropdown.handlePopupKey(Qt.Key_Return, "")
        var searchableChanged = ""
        searchable.changed.connect(function(value) { searchableChanged = value })
        searchable.focusTrigger()
        searchable.handleTriggerKey(Qt.Key_Space)
        searchable.handleSearchKey(Qt.Key_Return)

        var accountRan = false
        controlsPanel.confirmAction("Account action?", function() { accountRan = true })
        controlsPanel._probeConfirmDialog.handleKey({ key: Qt.Key_Escape })
        var confirmationRan = false
        controlsPanel.confirmAction("Accept action?", function() { confirmationRan = true })
        controlsPanel._probeConfirmDialog.selectedIndex = 1
        controlsPanel._probeConfirmDialog.handleKey({ key: Qt.Key_Return })

        root.interactionValues = {
          tabsWorked: tabsWorked,
          dropdownChanged: dropdownChanged,
          searchableChanged: searchableChanged,
          locationSelected: service.relayConstraints.location.cityCode === "ber",
          mapProjection: map && map.visible && map.pointX(service.locations[1]) > 0 && map.pointY(service.locations[1]) > 0,
          confirmationClosed: !controlsPanel._probeConfirmDialog.opened,
          accountCanceled: !accountRan,
          confirmationAccepted: confirmationRan
        }
        root.interactionPhase = 0
        interactionWait.start()
      })
    } else if (scenario === "excluded-groups") {
      var excludedPanel = widget._probePanelItem
      service.installed = true
      service.daemonRunning = true
      excludedPanel.showPage(3)
      Qt.callLater(function() {
        var groups = excludedPanel.excludedGroups()
        root.finish("", {
          selectedPage: excludedPanel.pageIndex,
          processCount: service.excludedProcesses.length,
          groupCount: groups.length,
          firstLabel: groups.length ? groups[0].label : "",
          firstCount: groups.length ? groups[0].count : 0,
          pageLoaded: excludedPanel._probePageItem !== null,
          pageGroupCount: excludedPanel._probePageItem ? excludedPanel._probePageItem.groups.length : -1
        })
      })
    } else finish("unknown scenario")
  }

  Timer {
    id: interactionWait
    property int elapsed: 0
    interval: 50
    repeat: true
    onTriggered: {
      elapsed += interval
      if (!root.service.busy && root.service._readQueue.length === 0 && root.service._readKind === "") {
        var panel = root.widget._probePanelItem
        if (root.interactionPhase === 0) {
          root.interactionPhase = 1
          root.service.locations = [{
            countryCode: "se", cityCode: "got", country: "Sweden", city: "Gothenburg",
            latitude: 57.7, longitude: 11.9,
            servers: [{ hostname: "se-got-wg-001", provider: "Example", ownership: "owned",
                        ipv4: "192.0.2.1", ipv6: "2001:db8::1", active: true }]
          }]
          root.service.relayConstraints = {
            location: { type: "city", countryCode: "se", cityCode: "got" },
            providers: [], ownership: "any", ipVersion: "any", multihop: false, entry: {}
          }
          root.service.state = "disconnected"
          root.service.connected = false
          panel.handleTextKey("1")
        } else if (root.interactionPhase === 1) {
          root.interactionPhase = 2
          panel.handleTextKey("t")
        } else if (root.interactionPhase === 2) {
          root.interactionPhase = 3
          root.service.state = "connected"
          root.service.connected = true
          root.interactionValues.connectControlRan = true
        } else if (root.interactionPhase === 3) {
          root.interactionPhase = 4
          panel.handleTextKey("t")
        } else if (root.interactionPhase === 4) {
          root.interactionPhase = 5
          root.interactionValues.disconnectControlRan = true
          panel.handleTextKey("3")
          root.interactionValues.advancedPageLoaded = panel.pageIndex === 2 && panel._probePageItem !== null
          var component = Qt.createComponent("file://" + root.pluginDir + "/OmaDropdown.qml")
          root.advancedControl = component.createObject(panel._probePageItem, {
            x: 0, y: 0, width: 320,
            options: [{ value: "auto", label: "Automatic" }, { value: "off", label: "Off" }],
            value: "auto"
          })
          root.advancedControl.changed.connect(function(value) { root.service.setAntiCensorshipMode(value) })
          root.advancedControl.focusTrigger()
          root.advancedControl.handleTriggerKey(Qt.Key_Space)
          root.advancedControl.handlePopupKey(Qt.Key_Down, "")
          root.advancedControl.handlePopupKey(Qt.Key_Return, "")
        } else {
          stop()
          root.interactionValues.advancedRejectedTruthful = root.service.antiCensorship.mode === "auto"
            && root.service.lastError.indexOf("mock advanced rejection") !== -1
          root.finish("", root.interactionValues)
        }
      } else if (elapsed > 8000) root.finish("interactive controls did not drain")
    }
  }

  Timer {
    id: launchResultWait
    property var panel: null
    property bool rejected: false
    property bool failurePreserved: false
    property int elapsed: 0
    interval: 50
    repeat: true
    onTriggered: {
      elapsed += interval
      if (!root.service.busy && root.service._readQueue.length === 0 && root.service._readKind === "") {
        stop()
        var accepted = panel.launchExcludedApp("Zoom (Web).desktop") === true
        root.finish("", {
          rejected: rejected,
          failurePreserved: failurePreserved,
          accepted: accepted,
          closedAfterSuccess: !panel.opened,
          queryClearedAfterSuccess: panel.appQuery === "",
          savedRecentFirst: shell.lastUpdatePayload && shell.lastUpdatePayload.recentExcludedApps
            ? String(shell.lastUpdatePayload.recentExcludedApps[0]) : ""
        })
      } else if (elapsed > 5000) root.finish("launch refresh did not drain")
    }
  }

  Timer {
    id: reloadWait
    interval: 50
    onTriggered: widgetLoader.active = true
  }

  Timer {
    id: replacementWait
    property int elapsed: 0
    interval: 50
    repeat: true
    onTriggered: {
      elapsed += interval
      if (root.widget.svc === null && root.widget._probePanelItem === null) {
        stop()
        root.finish("", {
          unavailableTooltip: root.widget.barTooltip,
          panelDestroyed: root.widget._probePanelItem === null
        })
      } else if (elapsed > 5000) root.finish("replacement bar did not settle")
    }
  }

  Timer {
    id: lifecycleWait
    property bool firstLoaded: false
    property int elapsed: 0
    interval: 50
    repeat: true
    onTriggered: {
      elapsed += interval
      if (root.widget.svc === null && root.widget._probePanelItem === null) {
        stop()
        root.finish("", {
          firstPanelLoaded: firstLoaded,
          loaderInactive: !root.widget._probePanelActive,
          loaderStatusNull: root.widget._probePanelStatus === Loader.Null,
          panelDestroyed: root.widget._probePanelItem === null
        })
      } else if (elapsed > 5000) root.finish("service lifecycle did not settle")
    }
  }

  function findNamed(item, name) {
    if (!item) return null
    if (item.objectName === name) return item
    var children = item.children || []
    for (var i = 0; i < children.length; i++) {
      var found = findNamed(children[i], name)
      if (found) return found
    }
    return null
  }

  function finish(note, values) {
    if (finished) return
    finished = true
    var result = { scenario: scenario, note: note }
    for (var key in (values || {})) result[key] = values[key]
    console.log("PROBE_RESULT " + JSON.stringify(result))
    Qt.quit()
  }

  Timer {
    interval: 15000
    running: true
    onTriggered: root.finish("overall timeout")
  }
}
