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

  QtObject {
    id: shell
    property var serviceInstance: null
    readonly property var appLibrary: null
    property string lastUpdateId: ""
    property var lastUpdatePayload: null
    function serviceFor(id) {
      return id === "io.github.kallupx.oma-mullvad" ? serviceInstance : null
    }
    function updateEntryInline(id, entry) {
      if (id !== "io.github.kallupx.oma-mullvad") return
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
    if (scenario === "state-icons") {
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
        sameService: shell.serviceFor("io.github.kallupx.oma-mullvad") === originalService,
        panelServiceMatches: widget._probePanelItem && widget._probePanelItem.service === originalService
      })
    } else if (scenario === "replacement-bar") {
      bar.shell = replacementShell
      replacementWait.start()
    } else if (scenario === "facade-contract") {
      shell.updateEntryInline("foreign.plugin", { value: 1 })
      var foreignIgnored = shell.lastUpdateId === ""
      shell.updateEntryInline("io.github.kallupx.oma-mullvad", { refreshIntervalSec: 45 })
      bar.requestPopout(widget)
      var popupOwned = bar.activePopout === widget
      bar.releasePopout(widget)
      finish("", {
        ownService: shell.serviceFor("io.github.kallupx.oma-mullvad") === service,
        foreignServiceNull: shell.serviceFor("foreign.plugin") === null,
        appLibraryNull: shell.appLibrary === null,
        foreignUpdateIgnored: foreignIgnored,
        ownUpdateRecorded: shell.lastUpdateId === "io.github.kallupx.oma-mullvad",
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
          ownService: shell.serviceFor("io.github.kallupx.oma-mullvad") === service,
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
      service.locations = [{
        countryCode: "se", cityCode: "got", country: "Sweden", city: "Gothenburg",
        latitude: 57.7, longitude: 11.9,
        servers: [{ hostname: "se-got-wg-001", provider: "Example", ownership: "owned",
                    ipv4: "192.0.2.1", ipv6: "2001:db8::1", active: true }]
      }]
      service.relayConstraints = {
        location: { type: "city", countryCode: "se", cityCode: "got" },
        providers: [], ownership: "any", ipVersion: "any", multihop: false, entry: {}
      }
      controlsPanel.showPage(1)
      var locations = controlsPanel.locationOptions()
      var servers = controlsPanel.serverOptions(service.locations[0])
      controlsPanel.toggleFavorite(service.locations[0])
      controlsPanel.recordRecent(service.locations[0])
      controlsPanel.movePage(1)
      var tabsWorked = controlsPanel.pageIndex === 2 && controlsPanel._probePageItem !== null

      var accountRan = false
      controlsPanel.confirmAction("Account action?", function() { accountRan = true })
      controlsPanel.pendingConfirmation = null
      var removalRan = false
      controlsPanel.confirmAction("Removal action?", function() { removalRan = true })
      controlsPanel.pendingConfirmation = null

      var dropdownComponent = Qt.createComponent("file://" + root.pluginDir + "/OmaDropdown.qml")
      var dropdown = dropdownComponent.createObject(root, {
        options: [{ value: "got", label: "Gothenburg" }], value: "got"
      })
      var searchableComponent = Qt.createComponent("file://" + root.pluginDir + "/OmaSearchableDropdown.qml")
      var searchable = searchableComponent.createObject(root, {
        options: [{ value: "se", label: "Sweden", description: "Gothenburg Example" }], value: "se"
      })
      var mapComponent = Qt.createComponent("file://" + root.pluginDir + "/WorldMap.qml")
      var map = mapComponent.createObject(root, { width: 360, height: 180 })

      service.disconnectTunnel()
      var busyBlocks = controlsPanel.chooseLocation(service.locations[0], false) === false
      interactionValues = {
        tabsWorked: tabsWorked, locationCount: locations.length, serverCount: servers.length,
        favoriteCount: controlsPanel.favoriteLocations.length,
        recentCount: controlsPanel.recentLocations.length,
        mapProjection: map && map.pointX(service.locations[0]) > 0 && map.pointY(service.locations[0]) > 0,
        filtersVisible: controlsPanel.pageIndex === 2,
        dropdownLabel: dropdown ? dropdown.currentLabel() : "",
        searchableLabel: searchable ? searchable.currentLabel() : "",
        busyBlocksLocation: busyBlocks,
        accountCanceled: !accountRan,
        removalCanceled: !removalRan
      }
      if (dropdown) dropdown.destroy()
      if (searchable) searchable.destroy()
      if (map) map.destroy()
      interactionWait.start()
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
        stop()
        root.finish("", root.interactionValues)
      } else if (elapsed > 5000) root.finish("interactive controls did not drain")
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
