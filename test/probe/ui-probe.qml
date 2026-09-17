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
      finish("", {
        cliReady: panel.cliReady,
        overviewAvailable: panel.pageAvailable(0),
        locationsAvailable: panel.pageAvailable(1),
        advancedAvailable: panel.pageAvailable(2),
        excludedAvailable: panel.pageAvailable(3),
        selectedPage: panel.pageIndex,
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
