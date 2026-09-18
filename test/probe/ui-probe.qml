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
        sameService: shell.serviceFor("io.github.kallupx.oma-mullvad") === originalService,
        panelServiceMatches: widget._probePanelItem && widget._probePanelItem.service === originalService
      })
    } else if (scenario === "replacement-bar") {
      bar.shell = replacementShell
      replacementWait.start()
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
      service.lastError = ""
      if (scenario !== "availability-ready") {
        for (var i = 0; i < widget.children.length; i++) {
          var child = widget.children[i]
          if (child.tooltipText !== undefined && typeof child.pressed === "function") child.pressed(Qt.RightButton)
        }
      }
      var barGuarded = service.lastError === ""
      panel.showPage(2)
      var dependentSelectedPage = panel.pageIndex
      finish("", {
        barGuarded: barGuarded,
        cliReady: panel.cliReady,
        overviewAvailable: panel.pageAvailable(0),
        locationsAvailable: panel.pageAvailable(1),
        advancedAvailable: panel.pageAvailable(2),
        excludedAvailable: panel.pageAvailable(3),
        selectedPage: dependentSelectedPage,
        barTooltip: widget.barTooltip
      })
    } else if (scenario === "settings-fresh-merge") {
      var settingsPanel = widget._probePanelItem
      widget.settings = ({ refreshIntervalSec: 99, siblingValue: "preserve-me",
                           favoriteLocations: [], recentLocations: [] })
      settingsPanel.settings = ({ refreshIntervalSec: 30, siblingValue: "stale",
                                  favoriteLocations: [], recentLocations: [] })
      settingsPanel.toggleFavorite({ countryCode: "se", cityCode: "got", country: "Sweden", city: "Gothenburg" })
      finish("", {
        refreshIntervalSec: shell.lastUpdatePayload ? shell.lastUpdatePayload.refreshIntervalSec : 0,
        siblingValue: shell.lastUpdatePayload ? String(shell.lastUpdatePayload.siblingValue || "") : "",
        favoriteCount: shell.lastUpdatePayload && shell.lastUpdatePayload.favoriteLocations
          ? shell.lastUpdatePayload.favoriteLocations.length : 0
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
