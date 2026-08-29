import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  // Injected once by shell.ensureService() when this manifest declares
  // kind "service" (unused directly here; kept for parity with the
  // reference service pattern and any future shell-level need).
  property var shell: null
  property int pollInterval: 30000
  readonly property int finiteOutputLines: 4096
  readonly property int finiteOutputChars: 262144
  readonly property int listenerLineChars: 8192
  // Every `mullvad` call is a direct Quickshell Process child, never a shell
  // wrapper -- see docs/developers.md, Process contract. Deadlines below are
  // plain (non-readonly) so the probe suite can shorten them for tests.
  property int readTimeoutMs: 10000
  property int actionTimeoutMs: 20000
  property int updateCheckTimeoutMs: 130000
  // System-tab helper scripts, resolved via Qt.resolvedUrl() relative to
  // this file, same as installScript below.
  readonly property string packageInfoScript: String(Qt.resolvedUrl("scripts/mullvad-package-info")).replace(/^file:\/\//, "")
  readonly property string updateCheckScript: String(Qt.resolvedUrl("scripts/mullvad-update-check")).replace(/^file:\/\//, "")
  // The sole script allowed to contain package-manager/service-manager/sudo
  // literals. Never spawned here -- Panel.qml hands it, shell-quoted, to
  // omarchy-launch-floating-terminal-with-presentation behind a ConfirmDialog.
  readonly property string installScript: String(Qt.resolvedUrl("scripts/install-mullvad")).replace(/^file:\/\//, "")

  property bool installed: false
  property bool daemonRunning: false
  property bool loggedIn: false
  property bool connected: false
  property string disconnectingAction: ""
  readonly property bool transitional: state === "connecting" || state === "disconnecting"
  readonly property bool active: connected || state === "connecting" || state === "error" || state === "blocked"
    || (state === "disconnecting" && disconnectingAction !== "nothing")
  state: "checking"
  property string statusText: "Checking Mullvad…"
  property string country: ""
  property string city: ""
  property string hostname: ""
  property string ip: ""
  property string currentCountryCode: ""
  property string currentCityCode: ""
  property string accountExpiry: ""
  property int accountDaysRemaining: -1
  property bool tunnelDropWarning: false

  property var locations: []
  property var providers: []
  property var relayConstraints: ({
    location: {}, providers: [], ownership: "any", ipVersion: "any",
    multihop: false, entry: {}
  })
  property bool lockdown: false
  property bool autoConnect: false
  property bool lanSharing: false
  property var dns: ({
    mode: "default", servers: [], blockAds: false, blockTrackers: false,
    blockMalware: false, blockAdultContent: false, blockGambling: false,
    blockSocialMedia: false
  })
  property var antiCensorship: ({ mode: "auto", port: "any" })
  property var excludedPids: []

  // System tab: binaries/daemon/updates state.
  property string cliVersion: ""
  property string daemonVersion: ""
  property var daemonSupported: null // bool|null
  property string suggestedUpgrade: ""
  property var packages: [] // [{ name, version, installedAt, buildAt }]
  property int daemonPid: 0
  property string updateCheckStatus: "never" // never|checking|ok|unavailable
  // "double", not "int": Date.now() (~13-digit ms epoch) overflows QML's
  // 32-bit `int` and silently wraps. Panel.qml's `nowMs` is `double` too.
  property double updateCheckedAt: 0 // ms epoch, 0 = never
  property bool updateAvailable: false
  property var updateTargets: [] // [{ name, current, latest }]

  property string actionStatus: ""
  property string lastError: ""
  property var _readQueue: []
  property string _readKind: ""
  property var _readLines: []
  property var _readErrorLines: []
  property int _readOutputLines: 0
  property int _readOutputChars: 0
  property var _actionQueue: []
  property var _actionLines: []
  property var _actionErrorLines: []
  property int _actionOutputLines: 0
  property int _actionOutputChars: 0
  // updateCheckProcess's own output buffers (separate Process; see
  // checkForUpdates() below).
  property double _updateCheckAttemptedAt: 0 // ms epoch of the last started check (debounce)
  property var _updateCheckLines: []
  property var _updateCheckErrorLines: []
  property int _updateCheckOutputLines: 0
  property int _updateCheckOutputChars: 0
  readonly property bool busy: actionProcess.running || _actionQueue.length > 0
    || readProcess.running || _readQueue.length > 0

  // Per-process watchdog/overflow state. `_read*WatchdogFired` etc. are
  // one-shot flags consumed by the matching onExited; the `*Count`
  // properties let test/probe/service-probe.qml assert a watchdog actually fired.
  property bool _readWatchdogFired: false
  property bool _actionWatchdogFired: false
  property bool _updateCheckWatchdogFired: false
  property bool _readOverflowed: false
  property bool _actionOverflowed: false
  property bool _updateCheckOverflowed: false
  property int _readWatchdogFiredCount: 0
  property int _actionWatchdogFiredCount: 0
  property int _updateCheckWatchdogFiredCount: 0
  property int _readOverflowCount: 0
  property int _actionOverflowCount: 0
  property int _updateCheckOverflowCount: 0
  // The PID each *KillTimer may signal(9), captured at that process's own
  // onStarted -- guards a stale kill timer from escalating against a NEW
  // process the queue already started in place of the one that armed it.
  property int _readArmedPid: 0
  property int _actionArmedPid: 0
  property int _updateCheckArmedPid: 0
  // A Process whose binary is missing flips `running` false without ever
  // emitting `exited`; each finalize function below also runs from a
  // deferred check for that case. See docs/developers.md, Process contract.
  property int _readGen: 0
  property int _readExitedGen: -1
  property int _actionGen: 0
  property int _actionExitedGen: -1
  property int _updateCheckGen: 0
  property int _updateCheckExitedGen: -1

  function _redact(value) {
    return Model.redact(String(value || ""))
  }

  function _shortError(value, fallback) {
    var text = Model.plainText(value, 181)
    if (!text) text = fallback
    return text.length > 180 ? text.slice(0, 177) + "…" : text
  }

  // Read/action/updateCheck output share one bounded-append helper: arrays
  // are always replaced (never .push()ed) so bindings notice, and a breach
  // caps the total at the limit and SIGTERMs the process immediately.
  function _procForKind(kind) {
    if (kind === "read") return readProcess
    if (kind === "action") return actionProcess
    return updateCheckProcess
  }

  function _resetBoundedOutput(kind) {
    root["_" + kind + "Lines"] = []
    root["_" + kind + "ErrorLines"] = []
    root["_" + kind + "OutputLines"] = 0
    root["_" + kind + "OutputChars"] = 0
    root["_" + kind + "Overflowed"] = false
  }

  function _appendBoundedOutput(kind, line, errorStream) {
    if (root["_" + kind + "Overflowed"]) return
    var outLinesKey = "_" + kind + "OutputLines"
    var outCharsKey = "_" + kind + "OutputChars"
    var atCap = root[outLinesKey] >= finiteOutputLines || root[outCharsKey] >= finiteOutputChars
    if (!atCap) {
      var value = _redact(line)
      var remaining = finiteOutputChars - root[outCharsKey]
      if (value.length >= remaining) { value = value.slice(0, remaining); atCap = true }
      var linesKey = errorStream ? "_" + kind + "ErrorLines" : "_" + kind + "Lines"
      root[linesKey] = root[linesKey].concat([value])
      root[outLinesKey] = root[outLinesKey] + 1
      root[outCharsKey] = root[outCharsKey] + value.length
      if (root[outLinesKey] >= finiteOutputLines) atCap = true
    }
    if (atCap) {
      root["_" + kind + "Overflowed"] = true
      root["_" + kind + "OverflowCount"] = root["_" + kind + "OverflowCount"] + 1
      var proc = _procForKind(kind)
      if (proc.running) proc.signal(15)
    }
  }

  function _resetReadOutput() { _resetBoundedOutput("read") }

  function _appendReadOutput(line, errorStream) { _appendBoundedOutput("read", line, errorStream) }

  function _resetActionOutput() { _resetBoundedOutput("action") }

  function _appendActionOutput(line, errorStream) { _appendBoundedOutput("action", line, errorStream) }

  function _resetUpdateCheckOutput() { _resetBoundedOutput("updateCheck") }

  function _appendUpdateCheckOutput(line, errorStream) { _appendBoundedOutput("updateCheck", line, errorStream) }

  function _hasRead(kind) {
    if (readProcess.running && _readKind === kind) return true
    for (var i = 0; i < _readQueue.length; i++)
      if (_readQueue[i].kind === kind) return true
    return false
  }

  // Optional per-request timeoutMs override; omitted callers fall back to
  // root.readTimeoutMs. Keeps System-tab reads on the same generic queue
  // instead of a second pipeline.
  function _enqueueRead(kind, command, timeoutMs) {
    if (_hasRead(kind)) return
    _readQueue = _readQueue.concat([{ kind: kind, command: command, timeoutMs: timeoutMs || 0 }])
    _startNextRead()
  }

  function _startNextRead() {
    if (readProcess.running || _readQueue.length === 0) return
    var queue = _readQueue.slice(0)
    var request = queue.shift()
    _readQueue = queue
    _readKind = request.kind
    _resetReadOutput()
    _readGen = _readGen + 1
    readWatchdog.interval = request.timeoutMs || root.readTimeoutMs
    readWatchdog.restart()
    readProcess.command = request.command
    readProcess.running = true
  }

  function refreshAll() {
    _enqueueRead("probe", ["/usr/bin/env", "mullvad", "--version"])
  }

  function _enqueueAuthoritativeReads() {
    _enqueueRead("status", ["mullvad", "status", "--json"])
    _enqueueRead("account", ["mullvad", "account", "get"])
    _enqueueRead("relays", ["mullvad", "relay", "list"])
    _enqueueRead("constraints", ["mullvad", "relay", "get"])
    _enqueueRead("lockdown", ["mullvad", "lockdown-mode", "get"])
    _enqueueRead("autoconnect", ["mullvad", "auto-connect", "get"])
    _enqueueRead("lan", ["mullvad", "lan", "get"])
    _enqueueRead("dns", ["mullvad", "dns", "get"])
    _enqueueRead("antiCensorship", ["mullvad", "anti-censorship", "get"])
    _enqueueRead("excludedPids", ["mullvad", "split-tunnel", "list"])
    // Cheap/local System-tab reads run on every refreshAll(); the network
    // update check only ever runs from systemTimer or "Check now"
    // (checkForUpdates()), never here.
    _enqueueRead("version", ["mullvad", "version"])
    _enqueueRead("daemonPid", ["pgrep", "-x", "mullvad-daemon"])
    _enqueueRead("packageInfo", [packageInfoScript])
  }

  // While the daemon is reported down, go through the full probe path
  // instead of the cheap status poll -- otherwise a CLI removed mid-session
  // stays misreported as "daemon unavailable" until refreshed by hand.
  function refreshStatus() {
    if (installed && daemonRunning) {
      _enqueueRead("status", ["mullvad", "status", "--json"])
      // Cheap (local pgrep), read alongside every routine status poll.
      _enqueueRead("daemonPid", ["pgrep", "-x", "mullvad-daemon"])
    } else refreshAll()
  }

  function _applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    state = String(parsed.state || "unknown")
    connected = parsed.connected === true
    disconnectingAction = String(parsed.disconnectingAction || "")
    daemonRunning = true
    tunnelDropWarning = !!parsed.error || !!parsed.warning || state === "error"
    var location = parsed.location || {}
    country = String(location.country || "")
    city = String(location.city || "")
    hostname = String(location.hostname || "")
    ip = String(location.ipv4 || location.ipv6 || "")
    if (parsed.lockedDown !== undefined) lockdown = parsed.lockedDown === true
    _updateCurrentCodes()
    if (state === "connected") statusText = "Connected"
    else if (state === "connecting") statusText = "Connecting…"
    else if (state === "disconnecting") statusText = "Disconnecting…"
    else if (state === "disconnected") statusText = "Disconnected"
    else if (state === "error") statusText = "Tunnel error"
    else statusText = state ? state.charAt(0).toUpperCase() + state.slice(1) : "Unknown"
  }

  function _updateCurrentCodes() {
    currentCountryCode = ""
    currentCityCode = ""
    if (!connected) return
    var match = hostname.toLowerCase().match(/^([a-z]{2})-([a-z0-9]{3})(?:-|$)/)
    if (match) {
      currentCountryCode = match[1]
      currentCityCode = match[2]
      return
    }
    for (var i = 0; i < locations.length; i++) {
      var location = locations[i]
      if (String(location.name || "").toLowerCase() === city.toLowerCase()
          && String(location.country || "").toLowerCase() === country.toLowerCase()) {
        currentCountryCode = String(location.countryCode || "")
        currentCityCode = String(location.code || "")
        return
      }
    }
  }

  function _applyRead(kind, raw, error, exitCode) {
    if (kind === "probe") {
      installed = exitCode === 0
      if (!installed) {
        daemonRunning = false
        connected = false
        state = "unavailable"
        statusText = "Mullvad is not installed"
        lastError = "Mullvad CLI not found. Use the install button below, or install the mullvad-vpn package and refresh."
        cliVersion = ""
        // Reset alongside cliVersion so the System tab never keeps showing
        // a stale daemon version/support string after the CLI disappears.
        daemonVersion = ""
        daemonSupported = null
        suggestedUpgrade = ""
        if (listenerProcess.running) listenerProcess.running = false
      } else {
        if (lastError.indexOf("Mullvad CLI not found") === 0) lastError = ""
        cliVersion = Model.parseCliVersion(raw)
        _enqueueAuthoritativeReads()
      }
      return
    }

    // daemonPid resets to 0 when pgrep finds nothing, unlike every other
    // kind (where a nonzero exit just leaves the last known value alone) --
    // handled here, before the generic guard, for the same reason "account" is.
    if (kind === "daemonPid") {
      daemonPid = exitCode === 0 ? (parseInt(String(raw || "").split("\n")[0], 10) || 0) : 0
      return
    }

    var combined = String(raw || "") + "\n" + String(error || "")
    if (kind === "status") {
      if (exitCode !== 0) {
        daemonRunning = false
        connected = false
        state = "unavailable"
        statusText = "Mullvad daemon unavailable"
        var daemonDetail = _shortError(combined, "")
        lastError = "Mullvad daemon unavailable. Open Mullvad VPN or start mullvad-daemon, then refresh."
          + (daemonDetail ? " " + daemonDetail : "")
        return
      }
      try {
        _applyStatus(raw)
        if (lastError.indexOf("Mullvad daemon unavailable") === 0) lastError = ""
        _ensureListener()
      } catch (e) {
        lastError = _shortError(e, "Could not parse Mullvad status")
      }
      return
    }

    if (kind === "account") {
      try {
        var account = Model.parseAccount(combined, Date.now())
        loggedIn = account.loggedIn === true
        accountExpiry = String(account.expiresAt || "")
        accountDaysRemaining = account.daysRemaining === undefined || account.daysRemaining === null
          ? -1 : Number(account.daysRemaining)
      } catch (e) {
        loggedIn = false
        accountExpiry = ""
        accountDaysRemaining = -1
      }
      return
    }
    if (exitCode !== 0) return

    try {
      if (kind === "relays") {
        var relayData = Model.parseRelayList(raw)
        var parsedLocations = relayData.locations || []
        var nextLocations = []
        for (var i = 0; i < parsedLocations.length; i++) {
          var relayLocation = parsedLocations[i] || {}
          nextLocations.push({
            country: String(relayLocation.country || ""),
            countryCode: String(relayLocation.countryCode || ""),
            city: String(relayLocation.city || relayLocation.name || ""),
            cityCode: String(relayLocation.cityCode || relayLocation.code || ""),
            name: String(relayLocation.name || relayLocation.city || ""),
            code: String(relayLocation.code || relayLocation.cityCode || ""),
            key: String(relayLocation.key || ""),
            latitude: Number(relayLocation.latitude),
            longitude: Number(relayLocation.longitude),
            servers: relayLocation.servers || []
          })
        }
        locations = nextLocations
        providers = relayData.providers || []
        _updateCurrentCodes()
      } else if (kind === "constraints") {
        relayConstraints = Model.parseRelayConstraints(raw)
      } else if (kind === "lockdown") {
        var lockdownValue = Model.parseToggle(raw)
        if (lockdownValue !== null) lockdown = lockdownValue === true
      } else if (kind === "autoconnect") {
        var autoValue = Model.parseToggle(raw)
        if (autoValue !== null) autoConnect = autoValue === true
      } else if (kind === "lan") {
        var lanValue = Model.parseToggle(raw)
        if (lanValue !== null) lanSharing = lanValue === true
      } else if (kind === "dns") {
        var dnsValue = Model.parseDns(raw)
        dns = {
          mode: String(dnsValue.mode || "default"),
          servers: dnsValue.customServers || [],
          blockAds: dnsValue.blockAds === true,
          blockTrackers: dnsValue.blockTrackers === true,
          blockMalware: dnsValue.blockMalware === true,
          blockAdultContent: dnsValue.blockAdultContent === true,
          blockGambling: dnsValue.blockGambling === true,
          blockSocialMedia: dnsValue.blockSocialMedia === true
        }
      } else if (kind === "antiCensorship") {
        var anti = Model.parseAntiCensorship(raw)
        var mode = String(anti.mode || "auto")
        var portKey = mode === "wireguard-port" ? "wireguardPort"
          : mode === "shadowsocks" ? "shadowsocksPort"
          : mode === "udp2tcp" ? "udp2tcpPort"
          : mode === "lwo" ? "lwoPort" : ""
        antiCensorship = {
          mode: mode,
          port: portKey ? String(anti[portKey] === undefined ? "any" : anti[portKey]) : "any",
          udp2tcpPort: anti.udp2tcpPort,
          shadowsocksPort: anti.shadowsocksPort,
          wireguardPort: anti.wireguardPort,
          lwoPort: anti.lwoPort
        }
      } else if (kind === "excludedPids") {
        excludedPids = Model.parseExcludedPids(raw)
      } else if (kind === "version") {
        var daemonInfo = Model.parseDaemonVersion(raw)
        daemonVersion = String(daemonInfo.version || "")
        daemonSupported = daemonInfo.supported === true ? true : daemonInfo.supported === false ? false : null
        suggestedUpgrade = String(daemonInfo.suggestedUpgrade || "")
      } else if (kind === "packageInfo") {
        packages = Model.parsePackageInfo(raw)
      }
    } catch (e) {
      lastError = _shortError(e, "Could not parse Mullvad " + kind)
    }
  }

  function _ensureListener() {
    if (!installed || !daemonRunning || listenerProcess.running) return
    listenerRestart.stop()
    listenerProcess.running = true
  }

  function _command(action, params) {
    if (!installed) {
      lastError = "Mullvad CLI not found. Use the install button below, or install the mullvad-vpn package and refresh."
      return null
    }
    try {
      return Model.argv(action, params || {})
    } catch (e) {
      lastError = _shortError(e, "Invalid Mullvad setting")
      actionStatus = lastError
      return null
    }
  }

  function _enqueueAction(command, label) {
    if (!command || command.length === 0) return false
    _actionQueue = _actionQueue.concat([{ command: command, label: label }])
    _startNextAction()
    return true
  }

  function _runAction(action, params, label) {
    return _enqueueAction(_command(action, params), label)
  }

  // Shared by _startNextAction() and login() (which bypasses the queue).
  // stdinEnabled is reset true here, at arm time -- onStarted always closes
  // it after use, so a later action's write() would otherwise land nowhere.
  function _armAction(command, label, secret) {
    // Stop the "clear actionStatus" timer before arming the next label --
    // otherwise a timer from the PREVIOUS action's completion can still
    // fire later and blank actionStatus out from under a busy queue.
    actionStatusTimer.stop()
    _resetActionOutput()
    _actionGen = _actionGen + 1
    actionWatchdog.interval = root.actionTimeoutMs
    actionWatchdog.restart()
    actionProcess.label = label
    actionProcess.secret = secret || ""
    actionProcess.command = command
    actionStatus = label + "…"
    actionProcess.stdinEnabled = true
    actionProcess.running = true
  }

  function _startNextAction() {
    if (actionProcess.running || _actionQueue.length === 0) return
    var queue = _actionQueue.slice(0)
    var action = queue.shift()
    _actionQueue = queue
    _armAction(action.command, action.label, "")
  }

  function connectTunnel() {
    if (busy) { actionStatus = "Wait for the current Mullvad action to finish."; return }
    if (!_relayAvailable(_relaySettings())) return
    _runAction("connect", {}, "Connecting")
  }

  function disconnectTunnel() {
    if (busy) { actionStatus = "Wait for the current Mullvad action to finish."; return }
    _runAction("disconnect", {}, "Disconnecting")
  }

  function toggleTunnel() {
    if (busy) { actionStatus = "Wait for the current Mullvad action to finish."; return }
    if (active) disconnectTunnel()
    else connectTunnel()
  }

  function login(account) {
    var secret = String(account || "").replace(/\s+/g, "")
    if (!/^\d{16}$/.test(secret)) {
      lastError = "Enter a valid 16-digit Mullvad account number."
      actionStatus = lastError
      secret = ""
      return
    }
    if (busy) {
      lastError = "Wait for the current Mullvad action to finish."
      actionStatus = lastError
      secret = ""
      return
    }
    var command = _command("login", {})
    if (!command) {
      secret = ""
      return
    }
    // No wrapper, no backgrounded shell job: a backgrounded command gets
    // /dev/null as stdin, but Process.write() reaches this child's real
    // stdin directly. _armAction hands `secret` over; onStarted writes it.
    _armAction(command, "Logging in", secret)
    secret = ""
  }

  function logout() { _runAction("logout", {}, "Logging out") }

  function _relaySettings(location, field, value) {
    var current = relayConstraints || ({})
    var next = {
      location: location || current.location || ({}),
      providers: current.providers || [],
      ownership: String(current.ownership || "any"),
      ipVersion: String(current.ipVersion || "any"),
      multihop: current.multihop === true,
      entry: current.entry || ({})
    }
    if (field) next[field] = value
    return next
  }

  function _relayAvailable(settings) {
    if (locations.length === 0)
      lastError = "Mullvad relay data is still loading. Refresh and try again."
    else if (Model.relayConstraintAvailable(locations, settings.location, settings))
      return true
    else
      lastError = "No Mullvad relays match that location and the active filters. Choose another location or clear a filter."
    actionStatus = lastError
    return false
  }

  function selectLocation(countryCode, cityCode, shouldConnect, hostname) {
    if (busy) { actionStatus = "Wait for the current Mullvad action to finish."; return false }
    var target = {
      type: hostname ? "hostname" : "city",
      countryCode: String(countryCode || "").toLowerCase(),
      cityCode: String(cityCode || "").toLowerCase(),
      hostname: String(hostname || "")
    }
    var nextSettings = _relaySettings(target)
    if (!_relayAvailable(nextSettings)) return false
    var locationCommand = _command("location", {
      country: countryCode, city: cityCode, hostname: hostname || ""
    })
    if (!locationCommand) return false
    var followup = null
    if (shouldConnect === true)
      followup = _command(active ? "reconnect" : "connect", {})
    _enqueueAction(locationCommand, "Selecting location")
    relayConstraints = nextSettings
    if (followup) _enqueueAction(followup, active ? "Reconnecting" : "Connecting")
    return true
  }

  function setLockdown(enabled) { _runAction("lockdown", { enabled: enabled }, "Updating lockdown") }
  function setAutoConnect(enabled) { _runAction("autoConnect", { enabled: enabled }, "Updating auto-connect") }
  function setLanSharing(enabled) { _runAction("lanSharing", { enabled: enabled }, "Updating LAN sharing") }
  function setProviders(values) {
    var next = _relaySettings(null, "providers", values)
    if (_relayAvailable(next) && _runAction("providers", { providers: values }, "Updating providers"))
      relayConstraints = next
  }
  function setOwnership(value) {
    var next = _relaySettings(null, "ownership", value)
    if (_relayAvailable(next) && _runAction("ownership", { ownership: value }, "Updating ownership"))
      relayConstraints = next
  }
  function setIpVersion(value) {
    var next = _relaySettings(null, "ipVersion", value)
    if (_relayAvailable(next) && _runAction("ipVersion", { ipVersion: value }, "Updating IP version"))
      relayConstraints = next
  }
  function setMultihop(enabled) { _runAction("multihop", { enabled: enabled }, "Updating multihop") }
  function setEntryLocation(countryCode, cityCode) {
    _runAction("entryLocation", { country: countryCode, city: cityCode }, "Updating entry location")
  }
  function setDnsDefault(flags) { _runAction("dnsDefault", { flags: flags || {} }, "Updating DNS") }
  function setDnsCustom(servers) { _runAction("dnsCustom", { servers: servers }, "Updating DNS") }

  function setAntiCensorshipMode(mode) {
    _runAction("antiCensorshipMode", { mode: mode }, "Updating anti-censorship")
  }
  function setAntiCensorshipPort(mode, port) {
    _runAction("antiCensorshipPort", { mode: mode, port: port }, "Updating anti-censorship port")
  }

  function launchExcludedApp(desktopId) {
    var id = String(desktopId || "").trim()
    if (id.slice(-8) === ".desktop") id = id.slice(0, -8)
    var command = _command("launchExcluded", { desktopId: id + ".desktop" })
    if (!command) return
    Quickshell.execDetached(command)
    actionStatus = "Launched outside the VPN"
    actionStatusTimer.restart()
    excludedRefresh.restart()
  }

  function removeExcludedPid(pid) {
    _runAction("excludedPidDelete", { pid: pid }, "Removing excluded process")
  }

  // The network update check runs on its own Process, never the shared
  // read queue that gates `busy` -- a slow/hung checkupdates must not block
  // toggling the VPN. Debounced on the last ATTEMPT, not last success.
  function checkForUpdates() {
    // Nothing installed => nothing to check. Refuse instead of letting
    // checkupdates "confirm" an up-to-date package that does not exist.
    if ((packages || []).length === 0) return updateCheckStatus
    if (updateCheckStatus !== "checking" && !updateCheckProcess.running
        && (_updateCheckAttemptedAt === 0 || Date.now() - _updateCheckAttemptedAt >= 60000)) {
      _updateCheckAttemptedAt = Date.now()
      updateCheckStatus = "checking"
      _resetUpdateCheckOutput()
      _updateCheckGen = _updateCheckGen + 1
      updateCheckWatchdog.interval = root.updateCheckTimeoutMs
      updateCheckWatchdog.restart()
      // updateCheckScript stays a direct bash-script child -- it wraps
      // checkupdates, not the Mullvad CLI. The watchdog above is its only deadline.
      updateCheckProcess.command = [updateCheckScript]
      updateCheckProcess.running = true
    }
    return updateCheckStatus
  }

  // interval assigned imperatively, never live-bound -- a live binding
  // restarts the countdown on any change to its own inputs, which this
  // timer must not do on its own ticks.
  Timer {
    id: pollTimer
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.installed ? root.refreshStatus() : root.refreshAll()
    Component.onCompleted: interval = Math.max(5000, Math.min(3600000, root.pollInterval))
  }

  onPollIntervalChanged: {
    pollTimer.interval = Math.max(5000, Math.min(3600000, pollInterval))
    pollTimer.restart()
  }

  Timer {
    id: listenerRestart
    interval: 5000
    repeat: false
    onTriggered: root._ensureListener()
  }

  Timer {
    id: actionStatusTimer
    interval: 2500
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    id: excludedRefresh
    interval: 1000
    repeat: false
    onTriggered: root._enqueueRead("excludedPids", ["mullvad", "split-tunnel", "list"])
  }

  // At most once an hour, imperative interval like pollTimer. First run at
  // 60s so the System tab populates without a network check on startup;
  // checkForUpdates() is itself debounced, and also what "Check now" calls.
  Timer {
    id: systemTimer
    repeat: true
    running: true
    onTriggered: {
      if (interval !== 3600000) interval = 3600000
      root._enqueueRead("packageInfo", [root.packageInfoScript])
      root.checkForUpdates()
    }
    Component.onCompleted: interval = 60000
  }

  // On fire: SIGTERM first, then a 1s killTimer escalates to SIGKILL if the
  // child is still alive (`running = false` alone only re-sends TERM).
  // Same-tick guard reads `readProcess.running` directly, never a derived bool.
  Timer {
    id: readWatchdog
    repeat: false
    onTriggered: {
      if (readProcess.running) {
        root._readWatchdogFired = true
        root._readWatchdogFiredCount++
        readProcess.signal(15)
        readKillTimer.restart()
      }
    }
  }

  Timer {
    id: readKillTimer
    interval: 1000
    repeat: false
    // Only escalate against the SAME process this timer was armed for --
    // by fire time the queue may already have started a different child
    // if the one that triggered the watchdog already exited.
    onTriggered: {
      if (readProcess.running && readProcess.processId === root._readArmedPid) readProcess.signal(9)
    }
  }

  // Shared by the real onExited and the synthetic failed-start path below.
  // exitStatus === 1 (killed by signal) folds into a nonzero exit code
  // regardless of exitCode, so a signalled child never reads as success.
  function _readFinalize(exitCode, exitStatus, syntheticError) {
    readWatchdog.stop()
    readKillTimer.stop()
    var kind = root._readKind
    root._readKind = ""
    if (syntheticError) {
      root._applyRead(kind, "", syntheticError, exitCode)
    } else if (root._readWatchdogFired) {
      root._readWatchdogFired = false
      root._applyRead(kind, "", "timed out", 124)
    } else if (root._readOverflowed) {
      root._applyRead(kind, "", "output limit exceeded", 137)
    } else {
      var raw = root._readLines.join("\n")
      var error = root._readErrorLines.join("\n")
      var effectiveExitCode = (exitStatus === 1 && exitCode === 0) ? 1 : exitCode
      root._applyRead(kind, raw, error, effectiveExitCode)
    }
    Qt.callLater(root._startNextRead)
  }

  Process {
    id: readProcess
    command: []
    running: false
    onStarted: { root._readArmedPid = processId }
    // Quickshell flips `running` false without ever emitting `exited` when
    // the binary can't be found. `Qt.callLater` defers this check so a
    // normal exit's own (synchronous) `exited` handler runs first.
    onRunningChanged: {
      if (!running) {
        var gen = root._readGen
        Qt.callLater(function() {
          if (root._readGen === gen && root._readExitedGen !== gen) {
            root._readExitedGen = gen
            root._readFinalize(127, 0, "failed to start (binary missing?)")
          }
        })
      }
    }
    stdout: SplitParser {
      onRead: function(line) { root._appendReadOutput(line, false) }
    }
    stderr: SplitParser {
      onRead: function(line) { root._appendReadOutput(line, true) }
    }
    // exited(exitCode, exitStatus): see _readFinalize above for the
    // CrashExit fold-in.
    onExited: function(exitCode, exitStatus) {
      root._readExitedGen = root._readGen
      root._readFinalize(exitCode, exitStatus, null)
    }
  }

  // A direct Process child, never a wrapper -- `quickshell kill` only
  // hard-kills its immediate child, so a wrapped grandchild would leak on
  // every shell restart. See docs/developers.md, "Why no shell wrapper".
  Process {
    id: listenerProcess
    command: ["mullvad", "status", "--json", "listen"]
    running: false
    stdout: SplitParser {
      onRead: function(line) {
        var boundedLine = String(line || "").slice(0, root.listenerLineChars)
        if (!boundedLine.trim()) return
        try {
          root._applyStatus(boundedLine)
        } catch (e) {
          root.lastError = root._shortError(e, "Could not parse live Mullvad status")
        }
      }
    }
    stderr: SplitParser {
      onRead: function(line) {
        var boundedLine = String(line || "").slice(0, root.listenerLineChars)
        if (boundedLine.trim()) root.lastError = root._shortError(boundedLine, "Mullvad status listener failed")
      }
    }
    onExited: function() {
      if (root.installed) {
        root.refreshStatus()
        listenerRestart.restart()
      }
    }
  }

  // Same pattern as readWatchdog/readKillTimer above.
  Timer {
    id: actionWatchdog
    repeat: false
    onTriggered: {
      if (actionProcess.running) {
        root._actionWatchdogFired = true
        root._actionWatchdogFiredCount++
        actionProcess.signal(15)
        actionKillTimer.restart()
      }
    }
  }

  Timer {
    id: actionKillTimer
    interval: 1000
    repeat: false
    // Same guard as readKillTimer above.
    onTriggered: {
      if (actionProcess.running && actionProcess.processId === root._actionArmedPid) actionProcess.signal(9)
    }
  }

  Process {
    id: actionProcess
    property string label: ""
    property string secret: ""
    command: []
    running: false
    stdinEnabled: true
    // Clears `secret` even if the process never starts at all (no onStarted
    // fires). Also carries the synthetic failed-start guard shared with
    // readProcess/updateCheckProcess -- a Process allows only one handler.
    onRunningChanged: {
      if (!running) {
        secret = ""
        var gen = root._actionGen
        Qt.callLater(function() {
          if (root._actionGen === gen && root._actionExitedGen !== gen) {
            root._actionExitedGen = gen
            root._actionFinalize(127, 0, "failed to start (binary missing?)")
          }
        })
      }
    }
    // Process.write() reaches the child's real stdin directly -- no
    // backgrounded shell job to silently substitute /dev/null. Every action
    // closes stdin via EOF right after start, since none reads further.
    onStarted: {
      root._actionArmedPid = processId
      if (secret.length > 0) {
        var value = secret
        secret = ""
        write(value + "\n")
        value = ""
      }
      stdinEnabled = false
    }
    stdout: SplitParser {
      onRead: function(line) { root._appendActionOutput(line, false) }
    }
    stderr: SplitParser {
      onRead: function(line) { root._appendActionOutput(line, true) }
    }
    onExited: function(exitCode, exitStatus) {
      root._actionExitedGen = root._actionGen
      root._actionFinalize(exitCode, exitStatus, null)
    }
  }

  // Shared by actionProcess's real onExited and its synthetic failed-start
  // path above. `syntheticError`, when set, means the binary never started.
  function _actionFinalize(exitCode, exitStatus, syntheticError) {
    actionWatchdog.stop()
    actionKillTimer.stop()
    actionProcess.secret = "" // redundant with onRunningChanged above, belt-and-suspenders.
    var label = actionProcess.label
    var success = false
    if (syntheticError) {
      root.lastError = root._shortError(syntheticError, label + " failed")
      root.actionStatus = root.lastError
      root._actionQueue = []
    } else if (root._actionWatchdogFired) {
      root._actionWatchdogFired = false
      root.lastError = label + " timed out"
      root.actionStatus = root.lastError
      root._actionQueue = []
    } else if (root._actionOverflowed) {
      root.lastError = label + " failed: output limit exceeded"
      root.actionStatus = root.lastError
      root._actionQueue = []
    } else {
      var effectiveExitCode = (exitStatus === 1 && exitCode === 0) ? 1 : exitCode
      var output = root._actionLines.join("\n")
      var error = root._actionErrorLines.join("\n")
      if (effectiveExitCode !== 0) {
        root.lastError = root._shortError(error || output, label + " failed")
        root.actionStatus = root.lastError
        root._actionQueue = []
      } else {
        root.lastError = ""
        root.actionStatus = label + " complete"
        actionStatusTimer.restart()
        success = true
      }
    }
    root.refreshAll()
    if (success) Qt.callLater(root._startNextAction)
  }

  // Same watchdog pattern again. updateCheckScript enforces its own
  // internal timeout already, so this is a backstop for the script hanging
  // outright, not the primary deadline.
  Timer {
    id: updateCheckWatchdog
    repeat: false
    onTriggered: {
      if (updateCheckProcess.running) {
        root._updateCheckWatchdogFired = true
        root._updateCheckWatchdogFiredCount++
        updateCheckProcess.signal(15)
        updateCheckKillTimer.restart()
      }
    }
  }

  Timer {
    id: updateCheckKillTimer
    interval: 1000
    repeat: false
    // Same guard as readKillTimer above.
    onTriggered: {
      if (updateCheckProcess.running && updateCheckProcess.processId === root._updateCheckArmedPid) updateCheckProcess.signal(9)
    }
  }

  // Deliberately separate from readProcess/actionProcess; not counted in
  // `busy`. A synthetic failed-start call always reaches the final nonzero-
  // exit branch below, same as timing out or being killed for overflow.
  function _updateCheckFinalize(exitCode, exitStatus) {
    updateCheckWatchdog.stop()
    updateCheckKillTimer.stop()
    var timedOutOrOverflowed = root._updateCheckWatchdogFired || root._updateCheckOverflowed
    root._updateCheckWatchdogFired = false
    if (timedOutOrOverflowed) {
      // Offline/lock/timeout (exit 3) or a watchdog/overflow kill: only the
      // status flips so the UI can say so; updateAvailable/updateTargets/
      // updateCheckedAt are left exactly as they were.
      root.updateCheckStatus = "unavailable"
      return
    }
    var effectiveExitCode = (exitStatus === 1 && exitCode === 0) ? 1 : exitCode
    var raw = root._updateCheckLines.join("\n")
    if (effectiveExitCode === 0) {
      try {
        root.updateTargets = Model.parseUpdateCheck(raw)
      } catch (e) {
        root.updateTargets = []
      }
      root.updateAvailable = root.updateTargets.length > 0
      root.updateCheckStatus = "ok"
      root.updateCheckedAt = Date.now()
    } else {
      root.updateCheckStatus = "unavailable"
    }
  }

  Process {
    id: updateCheckProcess
    command: []
    running: false
    onStarted: { root._updateCheckArmedPid = processId }
    // Same synthetic-failed-start guard as readProcess/actionProcess --
    // without it, a script whose interpreter disappeared left
    // updateCheckStatus stuck at "checking" forever.
    onRunningChanged: {
      if (!running) {
        var gen = root._updateCheckGen
        Qt.callLater(function() {
          if (root._updateCheckGen === gen && root._updateCheckExitedGen !== gen) {
            root._updateCheckExitedGen = gen
            root._updateCheckFinalize(127, 0)
          }
        })
      }
    }
    stdout: SplitParser {
      onRead: function(line) { root._appendUpdateCheckOutput(line, false) }
    }
    stderr: SplitParser {
      onRead: function(line) { root._appendUpdateCheckOutput(line, true) }
    }
    onExited: function(exitCode, exitStatus) {
      root._updateCheckExitedGen = root._updateCheckGen
      root._updateCheckFinalize(exitCode, exitStatus)
    }
  }
}
