import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root
  readonly property string pluginId: "io.github.kallupx.oma-mullvad"
  property var config: null
  property bool finished: false
  property int writes: 0
  property var facade: null

  FileView {
    id: shellFile
    path: Quickshell.env("MULLVAD_SHELL_JSON")
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try { root.config = JSON.parse(text()) } catch (e) { root.config = null }
      if (!root.finished) settle.restart()
    }
    onLoadFailed: root.config = null
    onFileChanged: reload()
  }

  QtObject { id: serviceToken }

  Component.onCompleted: {
    var component = Qt.createComponent("file://" + Quickshell.env("OMARCHY_SHELL_DIR")
                                       + "/services/PluginShellApi.qml")
    if (component.status !== Component.Ready) {
      console.log("PROBE_RESULT " + JSON.stringify({ note: component.errorString() }))
      Qt.quit()
      return
    }
    facade = component.createObject(root, {
      pluginId: pluginId,
      _serviceLookup: function(id) { return id === root.pluginId ? serviceToken : null },
      _updateSettings: function(id, settings) { return root.updateSettings(id, settings) }
    })
  }

  function currentEntry() {
    if (!config || config.version !== 1 || !config.bar || !config.bar.layout) return null
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var rows = config.bar.layout[sections[s]] || []
      for (var i = 0; i < rows.length; i++) if (rows[i] && rows[i].id === pluginId) return rows[i]
    }
    return null
  }

  function updateSettings(id, settings) {
    if (id !== pluginId || !config || config.version !== 1) return false
    var entry = currentEntry()
    if (!entry) return false
    var next = JSON.parse(JSON.stringify(config))
    var rows = next.bar.layout.right || []
    var replaced = false
    for (var i = 0; i < rows.length; i++) if (rows[i] && rows[i].id === pluginId) {
      rows[i] = JSON.parse(JSON.stringify(settings))
      rows[i].id = pluginId
      replaced = true
    }
    if (!replaced) return false
    config = next
    shellFile.setText(JSON.stringify(next, null, 2) + "\n")
    writes++
    return true
  }

  Timer {
    id: settle
    interval: 80
    onTriggered: root.runProbe()
  }

  function runProbe() {
    if (finished || !facade || !currentEntry()) return
    var initial = currentEntry()
    var initialFavorites = (initial.favoriteLocations || []).length
    var initialRecents = (initial.recentLocations || []).length
    var initialApps = (initial.recentExcludedApps || []).length
    var foreignRejected = facade.updateEntryInline("foreign.plugin", {}) === false
    var ownService = facade.serviceFor(pluginId) === serviceToken
    var foreignService = facade.serviceFor("foreign.plugin") === null

    var saved = facade.updateEntryInline(pluginId, {
      id: pluginId, refreshIntervalSec: 45, siblingValue: "preserved",
      favoriteLocations: initial.favoriteLocations,
      recentLocations: [{ countryCode: "fi", cityCode: "hel", country: "Finland", city: "Helsinki" }],
      recentExcludedApps: initial.recentExcludedApps
    })
    var siblingPreserved = currentEntry().siblingValue === "preserved"

    shellFile.setText("{ invalid\n")
    config = null
    var invalidRejected = facade.updateEntryInline(pluginId, { id: pluginId }) === false
    shellFile.setText("")
    config = null
    var deletedRejected = facade.updateEntryInline(pluginId, { id: pluginId }) === false

    var recreated = {
      version: 1,
      bar: { layout: { left: [], center: [], right: [{
        id: pluginId, refreshIntervalSec: 60, siblingValue: "recreated",
        favoriteLocations: [], recentLocations: [], recentExcludedApps: []
      }] } }, plugins: []
    }
    config = recreated
    shellFile.setText(JSON.stringify(recreated, null, 2) + "\n")
    var recreatedSaved = facade.updateEntryInline(pluginId, {
      id: pluginId, refreshIntervalSec: 60, siblingValue: "recreated",
      favoriteLocations: [], recentLocations: [], recentExcludedApps: ["org.example.Safe.desktop"]
    })

    var replacementComponent = Qt.createComponent("file://" + Quickshell.env("OMARCHY_SHELL_DIR")
                                                   + "/services/PluginShellApi.qml")
    var replacement = replacementComponent.createObject(root, {
      pluginId: pluginId,
      _serviceLookup: function(id) { return id === root.pluginId ? serviceToken : null },
      _updateSettings: function(id, settings) { return root.updateSettings(id, settings) }
    })
    var replacementWorks = replacement && replacement.serviceFor(pluginId) === serviceToken
    if (replacement) replacement.destroy()

    finished = true
    console.log("PROBE_RESULT " + JSON.stringify({
      note: "", initialFavorites: initialFavorites, initialRecents: initialRecents,
      initialApps: initialApps, foreignRejected: foreignRejected,
      ownService: ownService, foreignService: foreignService,
      saved: saved, siblingPreserved: siblingPreserved,
      invalidRejected: invalidRejected, deletedRejected: deletedRejected,
      recreatedSaved: recreatedSaved, replacementWorks: replacementWorks,
      finalApps: (currentEntry().recentExcludedApps || []).length, writes: writes
    }))
    Qt.quit()
  }

  Timer {
    interval: 5000
    running: true
    onTriggered: {
      console.log("PROBE_RESULT " + JSON.stringify({ note: "overall timeout" }))
      Qt.quit()
    }
  }
}
