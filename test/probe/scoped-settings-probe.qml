import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root
  readonly property string pluginId: "io.github.kallupx.oma-mullvad"
  readonly property string shellPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  property var host: null
  property var facade: null
  property var manifest: null
  property var diskConfig: null
  property int phase: 0
  property int writes: 0
  property bool finished: false
  property var results: ({})

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
      else { root.phase = 4; root.diskConfig = null; settle.restart() }
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

  function withCollections(source, changes) {
    var next = clone(source)
    for (var key in changes) next[key] = changes[key]
    return next
  }

  Timer {
    id: settle
    interval: 100
    onTriggered: root.advance()
  }

  function advance() {
    if (finished || !host || !manifest) { if (!finished) settle.restart(); return }
    var hostEntry = entry(host.shellConfig)
    var diskEntry = entry(diskConfig)

    if (phase === 0) {
      var installed = host.pluginRegistry && host.pluginRegistry.installedPlugins
        ? host.pluginRegistry.installedPlugins[pluginId] : null
      if (!installed || !hostEntry || !diskEntry) { settle.restart(); return }
      facade = host.pluginShellFor(manifest)
      if (!facade) { finish("host did not create scoped facade"); return }
      results.initialFavorites = (hostEntry.favoriteLocations || []).length
      results.initialRecents = (hostEntry.recentLocations || []).length
      results.initialApps = (hostEntry.recentExcludedApps || []).length
      results.foreignRejected = facade.updateEntryInline("foreign.plugin", {}) === false
      results.saved = facade.updateEntryInline(pluginId, withCollections(hostEntry, {
        recentLocations: [{ countryCode: "fi", cityCode: "hel", country: "Finland", city: "Helsinki" }]
      }))
      phase = 1
      settle.restart()
      return
    }

    if (phase === 1) {
      if (!diskEntry || diskEntry.refreshIntervalSec !== 30
          || (diskEntry.recentLocations || []).length !== 1
          || diskEntry.recentLocations[0].cityCode !== "hel") { settle.restart(); return }
      results.siblingPreserved = diskEntry.siblingValue === "preserved"
      writeConfig(withCollections(diskConfig, { externalMarker: "fresh" }))
      phase = 2
      settle.restart()
      return
    }

    if (phase === 2) {
      if (!host.shellConfig || host.shellConfig.externalMarker !== "fresh") { settle.restart(); return }
      var fresh = entry(host.shellConfig)
      results.externalEditObserved = !!fresh
      results.externalMergeSaved = facade.updateEntryInline(pluginId, withCollections(fresh, {
        favoriteLocations: [{ countryCode: "de", cityCode: "ber", country: "Germany", city: "Berlin" }]
      }))
      phase = 3
      settle.restart()
      return
    }

    if (phase === 3) {
      if (!diskEntry || (diskEntry.favoriteLocations || []).length !== 1) { settle.restart(); return }
      results.externalSiblingPreserved = diskConfig.externalMarker === "fresh"
      diskFile.setText("{ invalid\n")
      writes++
      phase = 31
      settle.restart()
      return
    }

    if (phase === 31) {
      if (entry(host.shellConfig)) { settle.restart(); return }
      facade = host.pluginShellFor(manifest)
      if (!facade) { finish("host did not recreate invalid-state facade"); return }
      results.invalidRejected = facade.updateEntryInline(pluginId, { id: pluginId }) === false
      removeConfig.running = true
      return
    }

    if (phase === 4) {
      if (entry(host.shellConfig)) { settle.restart(); return }
      facade = host.pluginShellFor(manifest)
      if (!facade) { finish("host did not recreate deleted-state facade"); return }
      results.deletedRejected = facade.updateEntryInline(pluginId, { id: pluginId }) === false
      var recreated = {
        version: 1,
        bar: { layout: { left: [], center: [], right: [{
          id: pluginId, refreshIntervalSec: 60, siblingValue: "recreated",
          favoriteLocations: [], recentLocations: [], recentExcludedApps: []
        }] } }, plugins: []
      }
      writeConfig(recreated)
      phase = 5
      settle.restart()
      return
    }

    if (phase === 5) {
      if (!hostEntry || hostEntry.siblingValue !== "recreated") { settle.restart(); return }
      facade = host.pluginShellFor(manifest)
      if (!facade) { finish("host did not recreate restored facade"); return }
      results.recreatedObserved = true
      results.recreatedSaved = facade.updateEntryInline(pluginId, withCollections(hostEntry, {
        recentExcludedApps: ["org.example.Safe.desktop"]
      }))
      phase = 6
      settle.restart()
      return
    }

    if (phase === 6) {
      if (!diskEntry || (diskEntry.recentExcludedApps || []).length !== 1) { settle.restart(); return }
      var replacement = host.pluginShellFor(manifest)
      results.facadeRecreated = replacement && replacement.updateEntryInline("foreign.plugin", {}) === false
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

  Timer {
    interval: 12000
    running: true
    onTriggered: root.finish("overall timeout")
  }
}
