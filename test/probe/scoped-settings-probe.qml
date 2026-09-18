import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root
  readonly property string pluginId: "halmylyseas.oma-mullvad"
  readonly property string shellPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  property var host: null
  property var facade: null
  property var manifest: null
  property var diskConfig: null
  property var service: null
  property var widget: null
  property var staleWidget: null
  property var panel: widget ? widget._probePanelItem : null
  property var stalePanel: staleWidget ? staleWidget._probePanelItem : null
  property int phase: 0
  property int writes: 0
  property bool finished: false
  property var results: ({})

  QtObject {
    id: probeBar
    property color foreground: "#eeeeee"
    property color background: "#111111"
    property color urgent: "#ff5555"
    property color barForeground: "#eeeeee"
    property string fontFamily: "monospace"
    property string position: "top"
    property bool vertical: false
    property int barSize: 26
    property bool foregroundAnimationEnabled: false
    property var shell: root.facade
    property var activePopout: null
    function run(command) {}
    function shellQuote(value) { return String(value) }
    function showTooltip(target, text) {}
    function hideTooltip(target) {}
    function requestPopout(owner) { activePopout = owner }
    function releasePopout(owner) { if (activePopout === owner) activePopout = null }
    function moduleWidgets(name) { return [root.widget, root.staleWidget].filter(function(value) { return !!value }) }
    function registerClickTarget(target) {}
    function unregisterClickTarget(target) {}
  }

  FileView {
    id: manifestFile
    path: Quickshell.env("MULLVAD_PLUGIN_MANIFEST")
    printErrors: false
    onLoaded: {
      try { root.manifest = JSON.parse(text()) }
      catch (e) { root.finish("manifest parse failed") }
    }
    onLoadFailed: root.finish("manifest load failed")
  }

  FileView {
    id: diskFile
    path: root.shellPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try { root.diskConfig = JSON.parse(text()) }
      catch (e) { root.diskConfig = null }
    }
    onLoadFailed: root.diskConfig = null
    onFileChanged: reload()
  }

  Process {
    id: removeConfig
    command: ["rm", "--", root.shellPath]
    onExited: function(exitCode) {
      if (exitCode !== 0) root.finish("isolated config removal failed")
      else { root.phase = 5; root.diskConfig = null; settle.restart() }
    }
  }

  Component.onCompleted: {
    var component = Qt.createComponent("file://" + Quickshell.env("OMARCHY_SHELL_DIR") + "/shell.qml")
    if (component.status !== Component.Ready) {
      finish(component.errorString())
      return
    }
    host = component.createObject(null)
    if (!host) finish("host creation failed")
    else settle.start()
  }

  function entry(config) {
    if (!config || config.version !== 1 || !config.bar || !config.bar.layout) return null
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var rows = config.bar.layout[sections[s]] || []
      for (var i = 0; i < rows.length; i++)
        if (rows[i] && rows[i].id === pluginId) return rows[i]
    }
    return null
  }

  function clone(value) { return JSON.parse(JSON.stringify(value)) }

  function writeConfig(value) {
    diskFile.setText(JSON.stringify(value, null, 2) + "\n")
    writes++
  }

  function withEntry(config, changes) {
    var next = clone(config)
    var current = entry(next)
    for (var key in changes) current[key] = changes[key]
    return next
  }

  function createActualWidget(settings) {
    var registered = host.pluginWidgetComponents[pluginId]
    if (!registered || !registered.component) return null
    var installed = host.pluginRegistry.installedPlugins[pluginId]
    var expected = host.pluginRegistry.entryPointUrl(installed, "barWidget")
    results.actualProductComponent = String(registered.url) === String(expected)
      && String(expected).slice(-14) === "/BarWidget.qml"
    var created = registered.component.createObject(root)
    if (!created) return null
    created.bar = probeBar
    created.settings = clone(settings)
    return created
  }

  Timer { id: settle; interval: 100; onTriggered: root.advance() }

  function advance() {
    if (finished || !host || !manifest) { if (!finished) settle.restart(); return }
    var hostEntry = entry(host.shellConfig)
    var diskEntry = entry(diskConfig)

    if (phase === 0) {
      var installed = host.pluginRegistry && host.pluginRegistry.installedPlugins
        ? host.pluginRegistry.installedPlugins[pluginId] : null
      if (!installed || !hostEntry || !diskEntry) { settle.restart(); return }
      facade = host.pluginShellFor(manifest)
      service = host.ensureService(pluginId)
      host.syncPluginWidgets()
      if (!facade || !service || !host.pluginWidgetComponents[pluginId]
          || !host.pluginWidgetComponents[pluginId].component) { settle.restart(); return }
      widget = createActualWidget(hostEntry)
      staleWidget = createActualWidget(hostEntry)
      phase = 1
      settle.restart()
      return
    }

    if (phase === 1) {
      if (!panel || !stalePanel) { settle.restart(); return }
      results.serviceIsHostSingleton = service === host.serviceFor(pluginId)
      results.initialFavorites = panel.favoriteLocations.length
      results.initialRecents = panel.recentLocations.length
      results.initialApps = panel.recentExcludedApps.length
      results.panelServiceMatches = panel.service === service && stalePanel.service === service
      results.foreignRejected = facade.updateEntryInline("foreign.plugin", {}) === false
      panel.recordRecent({ countryCode: "fi", cityCode: "hel", country: "Finland", city: "Helsinki" })
      phase = 2
      settle.restart()
      return
    }

    if (phase === 2) {
      if (!diskEntry || (diskEntry.recentLocations || []).length !== 2
          || diskEntry.recentLocations[0].cityCode !== "hel") { settle.restart(); return }
      results.siblingPreserved = diskEntry.siblingValue === "preserved"
      writeConfig(withEntry(diskConfig, {
        refreshIntervalSec: 99,
        siblingValue: "fresh-sibling",
        pluginExtra: "fresh-plugin-field",
        favoriteLocations: [{ countryCode: "de", cityCode: "ber", country: "Germany", city: "Berlin" }]
      }))
      phase = 3
      settle.restart()
      return
    }

    if (phase === 3) {
      if (!hostEntry || hostEntry.refreshIntervalSec !== 99 || !widget || !staleWidget) { settle.restart(); return }
      widget.destroy()
      widget = null
      widget = createActualWidget(hostEntry)
      staleWidget.settings = clone(hostEntry)
      phase = 31
      settle.restart()
      return
    }

    if (phase === 31) {
      if (!panel || !stalePanel || panel.favoriteLocations.length !== 1) { settle.restart(); return }
      results.externalEditObserved = panel.favoriteLocations[0].cityCode === "ber"
      results.recreatedUiState = panel.setting("refreshIntervalSec", 0) === 99
      stalePanel.recordLaunchedApp("org.example.Second.desktop")
      phase = 4
      settle.restart()
      return
    }

    if (phase === 4) {
      if (!diskEntry || (diskEntry.recentExcludedApps || [])[0] !== "org.example.Second.desktop") { settle.restart(); return }
      results.stalePanelPreservedFreshFields = diskEntry.refreshIntervalSec === 99
        && diskEntry.siblingValue === "fresh-sibling" && diskEntry.pluginExtra === "fresh-plugin-field"
      diskFile.setText("{ invalid\n")
      writes++
      phase = 41
      settle.restart()
      return
    }

    if (phase === 41) {
      if (entry(host.shellConfig)) { settle.restart(); return }
      facade = host.pluginShellFor(manifest)
      if (!facade) { finish("host did not recreate invalid-state facade"); return }
      results.invalidRejected = facade.updateEntryInline(pluginId, { id: pluginId }) === false
      results.invalidWriteRefused = results.invalidRejected
      removeConfig.running = true
      return
    }

    if (phase === 5) {
      if (entry(host.shellConfig)) { settle.restart(); return }
      facade = host.pluginShellFor(manifest)
      if (!facade) { finish("host did not recreate deleted-state facade"); return }
      results.deletedRejected = facade.updateEntryInline(pluginId, { id: pluginId }) === false
      results.deletedPanelRefused = results.deletedRejected && diskConfig === null
      var recreated = {
        version: 1,
        bar: { layout: { left: [], center: [], right: [{
          id: pluginId, refreshIntervalSec: 60, siblingValue: "recreated",
          pluginExtra: "recovered-plugin-field",
          favoriteLocations: [], recentLocations: [], recentExcludedApps: []
        }] } }, plugins: [pluginId]
      }
      writeConfig(recreated)
      phase = 6
      settle.restart()
      return
    }

    if (phase === 6) {
      if (!hostEntry || hostEntry.siblingValue !== "recreated") { settle.restart(); return }
      facade = host.pluginShellFor(manifest)
      if (!facade) { finish("host did not recreate restored facade"); return }
      service = host.ensureService(pluginId)
      host.syncPluginWidgets()
      if (!service || !host.pluginWidgetComponents[pluginId]
          || !host.pluginWidgetComponents[pluginId].component) { settle.restart(); return }
      if (widget) widget.destroy()
      widget = createActualWidget(hostEntry)
      phase = 61
      settle.restart()
      return
    }

    if (phase === 61) {
      if (!panel || panel.setting("refreshIntervalSec", 0) !== 60 || panel.service !== service) { settle.restart(); return }
      results.recoveredPanelState = panel.favoriteLocations.length === 0 && panel.recentExcludedApps.length === 0
      panel.recordLaunchedApp("org.example.Safe.desktop")
      phase = 7
      settle.restart()
      return
    }

    if (phase === 7) {
      if (!diskEntry || (diskEntry.recentExcludedApps || []).length !== 1) { settle.restart(); return }
      results.recreatedSaved = diskEntry.recentExcludedApps[0] === "org.example.Safe.desktop"
      results.recreatedSiblingPreserved = diskEntry.siblingValue === "recreated"
        && diskEntry.pluginExtra === "recovered-plugin-field"
      results.finalApps = diskEntry.recentExcludedApps.length
      results.writes = writes
      finish("", results)
    }
  }

  function finish(note, values) {
    if (finished) return
    finished = true
    var result = { note: note }
    for (var key in (values || {})) result[key] = values[key]
    console.log("PROBE_RESULT " + JSON.stringify(result))
    if (host) host.destroy()
    Qt.quit()
  }

  Timer { interval: 15000; running: true; onTriggered: root.finish("overall timeout") }
}
