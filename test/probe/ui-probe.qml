import QtQuick
import Quickshell
import Quickshell.Io

// Instantiates the REAL BarWidget.qml + Panel.qml against a stub bar/shell
// and the real Service.qml against the mock CLI. Drives one env-selected
// scenario and prints one "PROBE_RESULT {...}" line for run-ui to grep.
ShellRoot {
  id: probeRoot

  property string pluginDir: Quickshell.env("MULLVAD_PLUGIN_DIR")
  property string scenario: Quickshell.env("MULLVAD_UI_SCENARIO") || ""
  property bool done: false
  property int elapsedMs: 0

  property var barWidget: null
  property var svc: null

  QtObject {
    id: stubAppLibrary
    signal appsChanged()
    function sortedEntries(query) { return [] }
    function entryName(entry) { return String((entry && entry.name) || "") }
    function entrySubtext(entry) { return "" }
    function iconSource(icon) { return "" }
    function refreshIcons() {}
  }

  QtObject {
    id: stubShell
    property var svcInstance: null
    property var updateEntryInlineCalls: []
    readonly property var appLibrary: stubAppLibrary
    function serviceFor(id) { return id === "io.github.kallupx.oma-mullvad" ? stubShell.svcInstance : null }
    function updateEntryInline(id, entry) {
      stubShell.updateEntryInlineCalls = stubShell.updateEntryInlineCalls.concat([{ id: id, entry: entry }])
    }
  }

  // Every property/method the bar-widget README documents (line 120-170)
  // plus what WidgetButton/BarIconButton read -- a name missing here is a
  // TypeError the moment the real widget touches it.
  QtObject {
    id: stubBar
    property color foreground: "#e6e6e6"
    property color background: "#1a1a1a"
    property color urgent: "#ff5555"
    property color barForeground: "#e6e6e6"
    property string fontFamily: "monospace"
    property string position: "top"
    property bool vertical: false
    property int barSize: 26
    property bool foregroundAnimationEnabled: true
    property var shell: stubShell
    property var activePopout: null
    property var clickTargets: []
    property var runCalls: []
    property var tooltipCalls: []
    function run(command) { stubBar.runCalls = stubBar.runCalls.concat([command]) }
    function shellQuote(value) { return "'" + String(value).replace(/'/g, "'\\''") + "'" }
    function showTooltip(target, text) { stubBar.tooltipCalls = stubBar.tooltipCalls.concat([text]) }
    function hideTooltip(target) {}
    function requestPopout(owner) { stubBar.activePopout = owner }
    function releasePopout(owner) { if (stubBar.activePopout === owner) stubBar.activePopout = null }
    function moduleWidgets(name) { return probeRoot.barWidget ? [probeRoot.barWidget] : [] }
    function registerClickTarget(target) {}
    function unregisterClickTarget(target) {}
  }

  Loader {
    id: svcLoader
    source: "file://" + probeRoot.pluginDir + "/Service.qml"
    active: true
    onLoaded: {
      probeRoot.svc = item
      stubShell.svcInstance = item
      if ("listenerRestartMs" in item) item.listenerRestartMs = 300
      barLoader.active = true
    }
  }

  Loader {
    id: barLoader
    active: false
    source: "file://" + probeRoot.pluginDir + "/BarWidget.qml"
    onLoaded: {
      probeRoot.barWidget = item
      item.bar = stubBar
      item.settings = ({})
      settleTimer.start()
    }
  }

  Timer {
    id: settleTimer
    interval: 200
    repeat: false
    onTriggered: probeRoot._drainThen(probeRoot.runScenario)
  }

  property var _afterBusy: null

  Timer {
    id: busyDrainTimer
    interval: 100
    repeat: true
    onTriggered: {
      probeRoot.elapsedMs += interval
      if (!probeRoot.svc.busy) {
        busyDrainTimer.stop()
        var cb = probeRoot._afterBusy
        probeRoot._afterBusy = null
        if (cb) cb()
      } else if (probeRoot.elapsedMs > 20000) {
        busyDrainTimer.stop()
        probeRoot.finish("queue did not drain within 20s")
      }
    }
  }

  function _drainThen(cb) {
    elapsedMs = 0
    _afterBusy = cb
    busyDrainTimer.start()
  }

  // Generic poll-until helper: calls `check()` every 50ms until it returns
  // true or `timeoutMs` elapses, then calls `cb(timedOut)`.
  function _waitUntil(check, timeoutMs, cb) {
    var waited = 0
    var timer = Qt.createQmlObject(
      'import QtQuick; Timer { interval: 50; repeat: true }', probeRoot)
    timer.triggered.connect(function() {
      waited += 50
      if (check()) {
        timer.stop(); timer.destroy()
        cb(false)
      } else if (waited > timeoutMs) {
        timer.stop(); timer.destroy()
        cb(true)
      }
    })
    timer.start()
  }

  function panel() { return barWidget ? barWidget._debugPanelItem : null }

  // Depth-first search of the Item tree for a descendant whose `label`
  // property matches (OmaDropdown/OmaSearchableDropdown identification --
  // there is no other way to name a QML instance from outside its file).
  function findByLabel(item, label) {
    if (!item) return null
    if (item.label === label) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) {
      var found = findByLabel(kids[i], label)
      if (found) return found
    }
    return null
  }

  // Depth-first search for a Text whose `text` contains the given
  // substring -- how the version-warning notice is identified, since
  // plain Text items have no `label` property of their own.
  function findTextContaining(item, substring) {
    if (!item) return null
    if (typeof item.text === "string" && item.text.indexOf(substring) !== -1) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) {
      var found = findTextContaining(kids[i], substring)
      if (found) return found
    }
    return null
  }

  // Order-independent, index-based equality: excludedGroups() is
  // unmemoized, so a fresh read and the Repeater's cached model are
  // never the same array/Array.isArray()-passing instance.
  function sameIndexable(a, b, cmp) {
    if (!a || !b || a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) if (!cmp(a[i], b[i])) return false
    return true
  }
  function samePids(a, b) { return sameIndexable(a, b, function(x, y) { return x === y }) }
  function sameGroups(a, b) {
    return sameIndexable(a, b, function(x, y) {
      return x.key === y.key && x.label === y.label && x.rootPid === y.rootPid
        && x.count === y.count && samePids(x.pids, y.pids)
    })
  }

  // Depth-first search for a Repeater whose `model` matches the given
  // groups array by content.
  function findRepeaterByContent(item, expected) {
    if (!item) return null
    if (item.count !== undefined && item.model !== undefined && sameGroups(item.model, expected)) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) {
      var found = findRepeaterByContent(kids[i], expected)
      if (found) return found
    }
    return null
  }

  function runScenario() {
    if (scenario === "locked") scenarioLocked()
    else if (scenario === "ready") scenarioReady()
    else if (scenario === "dropdown") scenarioDropdown()
    else if (scenario === "excluded") scenarioExcluded()
    else if (scenario === "lifecycle") scenarioLifecycle()
    else if (scenario === "versionwarning") scenarioVersionWarning()
    else finish("unknown MULLVAD_UI_SCENARIO: " + scenario)
  }

  // (1) CLI absent (mock --version fails): pages 1-3 locked, Overview
  // shows the install action, header page-switch disabled for them.
  function scenarioLocked() {
    var p = panel()
    finish("", {
      installed: svc.installed,
      cliReady: p ? p.cliReady : null,
      pageAvailable: p ? [0, 1, 2, 3, 4].map(function(i) { return p.pageAvailable(i) }) : null,
      installActionLabel: p ? p.installActionLabel() : null
    })
  }

  // (2) ready: CLI + daemon usable, all pages unlocked.
  function scenarioReady() {
    var p = panel()
    var notice = p ? findTextContaining(p._debugPageItem, "is untested with this plugin") : null
    finish("", {
      installed: svc.installed,
      daemonRunning: svc.daemonRunning,
      cliReady: p ? p.cliReady : null,
      pageAvailable: p ? [0, 1, 2, 3, 4].map(function(i) { return p.pageAvailable(i) }) : null,
      cliVersionSupported: svc.cliVersionSupported,
      versionNoticeVisible: notice ? notice.visible : false
    })
  }

  // (6) version warning: an untested CLI version shows the Overview notice
  // and the System tab's "(untested)" suffix next to the CLI line.
  function scenarioVersionWarning() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }
    var notice = findTextContaining(p._debugPageItem, "is untested with this plugin")
    // Read eagerly: p.showPage(4) below destroys the Overview page delegate
    // (and `notice` with it), the same destroy-before-read trap as scenario 5.
    var overviewNoticeVisible = notice ? notice.visible : false
    var overviewNoticeText = notice ? notice.text : ""
    var prevPage = p._debugPageItem
    p.showPage(4) // System
    _waitUntil(function() { return p._debugPageItem !== null && p._debugPageItem !== prevPage }, 3000, function(timedOut) {
      if (timedOut) { finish("System page did not load within 3s"); return }
      var cliLine = findTextContaining(p._debugPageItem, "CLI: ")
      finish("", {
        cliVersion: svc.cliVersion,
        cliVersionSupported: svc.cliVersionSupported,
        overviewNoticeVisible: overviewNoticeVisible,
        overviewNoticeText: overviewNoticeText,
        systemCliLineText: cliLine ? cliLine.text : "",
        systemCliLineMentionsUntested: cliLine ? cliLine.text.indexOf("(untested)") !== -1 : false
      })
    })
  }

  // (3) dropdown binding truth: direct model mutation is followed live;
  // a failed setOwnership() settles back to the model's real value, not
  // the attempted one, once the post-action refreshAll() re-reads truth.
  function scenarioDropdown() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }
    var prevPage = p._debugPageItem
    p.showPage(1) // Locations -- has the RELAY FILTERS Ownership dropdown
    _waitUntil(function() { return p._debugPageItem !== null && p._debugPageItem !== prevPage }, 3000, function(timedOut) {
      if (timedOut) { finish("Locations page did not load within 3s"); return }
      scenarioDropdownContinued(p)
    })
  }

  function scenarioDropdownContinued(p) {
    var dropdown = findByLabel(p._debugPageItem, "Ownership")
    if (!dropdown) { finish("Ownership dropdown not found in Locations page"); return }
    var before = dropdown.value
    var current = svc.relayConstraints || {}
    svc.relayConstraints = {
      location: current.location || {}, providers: current.providers || [],
      ownership: "rented", ipVersion: current.ipVersion || "any",
      multihop: current.multihop === true, entry: current.entry || {}
    }
    var afterDirectSet = dropdown.value
    svc.setOwnership("rented")
    var immediatelyAfterCall = dropdown.value
    _drainThen(function() {
      finish("", {
        beforeValue: before,
        afterDirectSetValue: afterDirectSet,
        immediatelyAfterSetOwnershipCall: immediatelyAfterCall,
        finalValue: dropdown.value,
        finalLastError: svc.lastError,
        finalRelayConstraintsOwnership: (svc.relayConstraints || {}).ownership
      })
    })
  }

  // (4) Excluded: groups render (Repeater count matches the data), and
  // appRows() is memoized (repeat call, same array reference).
  function scenarioExcluded() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }
    var prevPage = p._debugPageItem
    p.showPage(3) // Excluded -- Loader.sourceComponent swap settles next tick
    _waitUntil(function() { return p._debugPageItem !== null && p._debugPageItem !== prevPage }, 3000, function(timedOut) {
      if (timedOut) { finish("Excluded page did not load within 3s"); return }
      scenarioExcludedContinued(p)
    })
  }

  function scenarioExcludedContinued(p) {
    var page = p._debugPageItem
    var groups = page ? page.groups : null
    var repeater = groups ? findRepeaterByContent(page, groups) : null
    var first = p.appRows()
    var second = p.appRows()
    finish("", {
      excludedProcessesLength: (svc.excludedProcesses || []).length,
      groupsLength: groups ? groups.length : null,
      repeaterFound: repeater !== null,
      repeaterCount: repeater ? repeater.count : null,
      appRowsMemoized: first === second,
      appRowsLength: first ? first.length : null
    })
  }

  // (5) svc -> null -> new service: the Loader deactivates, then a fresh
  // Panel is created for the new service. Booleans are computed eagerly,
  // never held as a QObject reference across the destroy (Qt auto-nulls those).
  property bool _lcPanel1WasNonNull: false
  property bool _lcActive1: false
  property int _lcStatus1: -1
  property bool _lcActiveAfterNull: true
  property int _lcStatusAfterNull: -1
  property bool _lcItemAfterNullWasNull: false

  function scenarioLifecycle() {
    _lcPanel1WasNonNull = panel() !== null
    _lcActive1 = barWidget._debugPanelActive
    _lcStatus1 = barWidget._debugPanelStatus
    stubShell.svcInstance = null
    svcLoader.active = false
    _waitUntil(function() { return barWidget.svc === null }, 5000, function(timedOut) {
      _lcActiveAfterNull = barWidget._debugPanelActive
      _lcStatusAfterNull = barWidget._debugPanelStatus
      _lcItemAfterNullWasNull = barWidget._debugPanelItem === null
      if (timedOut) { finish("svc did not go null within 5s"); return }
      svcLoader2.active = true
    })
  }

  Loader {
    id: svcLoader2
    active: false
    source: "file://" + probeRoot.pluginDir + "/Service.qml"
    onLoaded: probeRoot._lifecyclePhase2(item)
  }

  function _lifecyclePhase2(svc2) {
    stubShell.svcInstance = svc2
    _waitUntil(function() { return barWidget.svc === svc2 && barWidget._debugPanelItem !== null }, 5000, function(timedOut) {
      var panel2 = panel()
      finish(timedOut ? "fresh panel did not appear within 5s" : "", {
        panel1WasNonNull: _lcPanel1WasNonNull,
        panelActive1: _lcActive1,
        panelStatus1: _lcStatus1,
        panelActiveAfterNull: _lcActiveAfterNull,
        panelStatusAfterNull: _lcStatusAfterNull,
        panelItemAfterNullWasNull: _lcItemAfterNullWasNull,
        panel2IsNonNull: panel2 !== null,
        panel2ServiceIsSvc2: panel2 ? panel2.service === svc2 : null,
        svcNowIsSvc2: barWidget.svc === svc2
      })
    })
  }

  function finish(note, extra) {
    if (done) return
    done = true
    var summary = { scenario: scenario, note: note }
    for (var key in (extra || {})) summary[key] = extra[key]
    console.log("PROBE_RESULT " + JSON.stringify(summary))
    Qt.quit()
  }

  Timer {
    interval: 25000
    running: true
    repeat: false
    onTriggered: probeRoot.finish("probe harness overall timeout (25s)")
  }
}
