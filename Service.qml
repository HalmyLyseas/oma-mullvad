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
  // S10 (23-s10-native-process-spec.md): every `mullvad` invocation is now a
  // direct Quickshell Process child (no scripts/bounded-command wrapper) --
  // the wrapper's own bash-semantics bugs (the orphaned listener, D2; the
  // empty stdin on `account login`, exchange/22) are the entire reason this
  // exists. Deadlines are enforced here instead, one Timer-driven watchdog
  // per process. readTimeoutMs/actionTimeoutMs are plain (non-QML-readonly)
  // properties, like every other mutable-but-externally-read state in this
  // file (e.g. `installed` below) -- exposed so test/probe/service-probe.qml
  // can shorten them (the hang-mode test does not need to wait out the real
  // 10s/20s deadlines). updateCheckTimeoutMs has no such need (nothing in
  // the probe suite exercises it) so it stays a plain constant.
  property int readTimeoutMs: 10000
  property int actionTimeoutMs: 20000
  readonly property int updateCheckTimeoutMs: 130000
  // T2 (16-s8-feedback-spec.md): System-tab helper scripts, resolved via
  // Qt.resolvedUrl() relative to this file, same as installScript below.
  readonly property string packageInfoScript: String(Qt.resolvedUrl("scripts/mullvad-package-info")).replace(/^file:\/\//, "")
  readonly property string updateCheckScript: String(Qt.resolvedUrl("scripts/mullvad-update-check")).replace(/^file:\/\//, "")
  // S9 (19-s9-install-prompt-spec.md): resolved path to the sole script
  // allowed to contain package-manager/service-manager/sudo literals. Never
  // spawned directly by this service -- only Panel.qml reads this property
  // to hand it, already shell-quoted, to
  // omarchy-launch-floating-terminal-with-presentation from behind a
  // ConfirmDialog.
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

  // T2 (16-s8-feedback-spec.md): System tab -- binaries/daemon/updates.
  property string cliVersion: ""
  property string daemonVersion: ""
  property var daemonSupported: null // bool|null
  property string suggestedUpgrade: ""
  property var packages: [] // [{ name, version, installedAt, buildAt }]
  property int daemonPid: 0
  property string updateCheckStatus: "never" // never|checking|ok|unavailable
  // "double", not "int": Date.now() (ms epoch, ~13 digits, e.g.
  // 1787964699000) overflows QML's 32-bit `int` (max 2147483647) --
  // measured live, it silently truncated/wrapped to a bogus ~10-digit
  // value. Panel.qml's `nowMs` is already `double` for the same reason.
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
  // T2: updateCheckProcess's own output buffers (separate Process, see
  // checkForUpdates() below).
  property double _updateCheckAttemptedAt: 0 // ms epoch of the last started check (debounce)
  property var _updateCheckLines: []
  property var _updateCheckErrorLines: []
  property int _updateCheckOutputLines: 0
  property int _updateCheckOutputChars: 0
  readonly property bool busy: actionProcess.running || _actionQueue.length > 0
    || readProcess.running || _readQueue.length > 0

  // S10: per-process watchdog/overflow state. `_read*WatchdogFired` etc. are
  // one-shot flags consumed (and reset) by the matching onExited -- the
  // pattern is github-status's probeWatchdog/probeWatchdogFired (see
  // Service.qml there: "force-stop after Ns and treat it as a real (if
  // inconclusive) result, never a wedge"). The *Count properties are debug
  // counters test/probe/service-probe.qml reads to assert a watchdog/
  // overflow actually fired, not just that SOME failure happened.
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
  // N2 (25-fable-review-s10.md): the PID each *KillTimer is allowed to
  // signal(9), captured from Process.processId in that process's own
  // onStarted. Guards against a stale kill timer (see the timers
  // themselves, below) escalating against a DIFFERENT process than the one
  // that armed it -- e.g. a read that exits promptly on the watchdog's own
  // signal(15) lets the queue start the NEXT read before the still-ticking
  // 1s kill timer fires; without this guard that timer's `if (proc.running)
  // proc.signal(9)` would be true again (a NEW child is now running) and
  // SIGKILL the wrong process.
  property int _readArmedPid: 0
  property int _actionArmedPid: 0
  property int _updateCheckArmedPid: 0

  function _redact(value) {
    return Model.redact(String(value || ""))
  }

  function _shortError(value, fallback) {
    var text = Model.plainText(value, 181)
    if (!text) text = fallback
    return text.length > 180 ? text.slice(0, 177) + "…" : text
  }

  // S10: `_appendReadOutput`/`_appendActionOutput`/`_appendUpdateCheckOutput`
  // are thin per-kind wrappers around this one shared helper (design spec:
  // "one shared helper if it reads cleanly"). Property names are accessed
  // dynamically via bracket notation (`root["_" + kind + "Lines"]`, valid JS
  // even for QML-declared properties) so the three kinds ("read", "action",
  // "updateCheck") share one implementation instead of three copies. Arrays
  // are always REPLACED via .concat(), never mutated via .push() (QML
  // gotcha #3 -- mutation alone doesn't notify bindings; harmless today
  // since nothing binds reactively to these buffers, but replacing costs
  // nothing and removes the trap for the next reader).
  //
  // On breach (either this line alone, or the running total, would exceed
  // the cap): the line is capped so the total lands AT the nominal cap, not
  // one char over it (fixes a pre-existing +1-over-cap rounding noted while
  // building test/probe/run's flood-mode assertion), the overflow flag is
  // set exactly once, the matching process is sent SIGTERM immediately
  // (never left to keep producing output the queue no longer wants), and
  // the overflow *Count is incremented for the probe suite to assert on.
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

  // T2: an optional per-request timeoutMs override (every pre-existing
  // caller omits it, so root.readTimeoutMs -- the S10 watchdog default --
  // applies uniformly; the "packageInfo" read needs no override either, a
  // plain local file read). Keeping the queue itself generic avoids giving
  // System-tab reads a second, parallel pipeline for no reason.
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
    // T2: cheap/local System-tab reads run on every refreshAll() (install
    // detection, panel open) -- NOT the network update check, which only
    // ever runs from the hourly systemTimer or the explicit "Check now"
    // button (checkForUpdates()). "version" queries the already-running
    // daemon (no network of its own); "packageInfo" only reads local
    // pacman metadata files.
    _enqueueRead("version", ["mullvad", "version"])
    _enqueueRead("daemonPid", ["pgrep", "-x", "mullvad-daemon"])
    _enqueueRead("packageInfo", [packageInfoScript])
  }

  function refreshStatus() {
    if (installed) {
      _enqueueRead("status", ["mullvad", "status", "--json"])
      // T2: cheap (local pgrep), read alongside every routine status poll.
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
        if (listenerProcess.running) listenerProcess.running = false
      } else {
        if (lastError.indexOf("Mullvad CLI not found") === 0) lastError = ""
        cliVersion = Model.parseCliVersion(raw)
        _enqueueAuthoritativeReads()
      }
      return
    }

    // T2: daemonPid must reset to 0 when pgrep finds nothing (exitCode !==
    // 0), unlike every other kind below where a non-zero exit means "leave
    // the last known value alone" -- handled before the generic guard for
    // the same reason "account" is (a query that legitimately reports
    // "not found" via its own exit code, not a transient failure to hide).
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

  // S10: shared by _startNextAction() and login() (which bypasses the queue
  // entirely, exactly like before this rework -- only how the process is
  // armed changed). `secret`, when non-empty, is written to actionProcess's
  // stdin and cleared on `onStarted` (see the Process below), never here.
  //
  // N1 (25-fable-review-s10.md): `onStarted` below always closes stdin
  // (`stdinEnabled = false`) once a process starts, but nothing was ever
  // setting it back to `true` -- every action after the very first one in
  // the object's lifetime armed a process whose `stdinEnabled` was still
  // `false` from the PREVIOUS action, so a `write()` in a later `onStarted`
  // (e.g. a `login()` that follows a `connect()`) silently went nowhere.
  // This is the `22-login-stdin-bug.md` regression again, at the QML level
  // this time instead of bash's. Reset it here, before `running = true`,
  // exactly like every other per-arm reset in this function (label,
  // secret, command).
  function _armAction(command, label, secret) {
    // C4 (12-fable-review.md): stop the "clear actionStatus" timer before
    // arming the next action's label -- otherwise a timer started by the
    // PREVIOUS action's completion (e.g. "Selecting location complete") can
    // still be ticking when this one sets "Connecting…", and 2.5s later
    // blanks actionStatus out from under a still-busy queue.
    actionStatusTimer.stop()
    _resetActionOutput()
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
    // S10 (22-login-stdin-bug.md fix, this time at the mechanism level): no
    // wrapper, no backgrounded shell job, so bash's "backgrounded command
    // gets /dev/null as stdin" bug cannot recur -- Process.write() reaches
    // the child's real stdin directly (measured, scratchpad/pm-native).
    // _armAction hands `secret` to actionProcess.secret; onStarted below
    // writes it, clears it, and closes stdin (EOF) before this function
    // returns control to the caller.
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

  // T2 (16-s8-feedback-spec.md): the network update check. Deliberately its
  // OWN Process (updateCheckProcess below), not the shared readProcess/
  // _readQueue pipeline every other read uses -- `checkupdates` can block
  // for up to its own 120s timeout, and readProcess/_readQueue feed
  // `busy`, which gates connectTunnel()/disconnectTunnel()/toggleTunnel().
  // Routing an hourly background network check through that same queue
  // would make a slow/hung update check block the user from toggling the
  // VPN for up to two minutes -- a regression this pass does not want to
  // introduce. Debounced: a call is ignored while one is already running,
  // or within 60s of the last one that was started (see the note on
  // _updateCheckAttemptedAt vs updateCheckedAt just below).
  // Debounced on the last ATTEMPT (`_updateCheckAttemptedAt`), not the last
  // successful completion (`updateCheckedAt`, which only advances on exit 0
  // so the UI can show "last known result"): an offline box therefore
  // cannot re-run `checkupdates` more than once a minute from "Check now".
  function checkForUpdates() {
    // Nothing installed => nothing to check. Refuse instead of letting
    // checkupdates "confirm" an up-to-date package that does not exist.
    if ((packages || []).length === 0) return updateCheckStatus
    if (updateCheckStatus !== "checking" && !updateCheckProcess.running
        && (_updateCheckAttemptedAt === 0 || Date.now() - _updateCheckAttemptedAt >= 60000)) {
      _updateCheckAttemptedAt = Date.now()
      updateCheckStatus = "checking"
      _resetUpdateCheckOutput()
      updateCheckWatchdog.interval = root.updateCheckTimeoutMs
      updateCheckWatchdog.restart()
      // S10: updateCheckScript stays a direct (unwrapped) bash script child
      // -- it wraps `checkupdates`, not the Mullvad CLI, so it is outside
      // this rework's scope (spec: "bash stays"). No bounded-command layer
      // either way; the watchdog above is this process's only deadline now.
      updateCheckProcess.command = [updateCheckScript]
      updateCheckProcess.running = true
    }
    return updateCheckStatus
  }

  // F6 (D9 fix): interval assigned imperatively, never live-bound. A live
  // `interval: expr` binding restarts the countdown on any change to the
  // expression's inputs; this timer only needs to react to actual
  // pollInterval pushes from the widget (below), never to its own ticks.
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

  // T2: the human's rule (15-humand-feedback.md) -- "low refresh, at most
  // once every hour[)". Imperative interval, same reasoning as pollTimer
  // (F6/D9): never a live `interval:` binding. First run at 60s after
  // service start (fast enough to populate the System tab without a
  // network check on every single startup being the FIRST thing that
  // happens), then every hour. checkForUpdates() is itself debounced, so
  // this is also what the tab's "Check now" button calls directly.
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

  // S10: readWatchdog/readKillTimer -- pattern measured live
  // (scratchpad/pm-native/probe/shell.qml) and modeled on github-status's
  // probeWatchdog (Service.qml there, grep probeWatchdogFired): on fire,
  // SIGTERM first (`signal(15)`), then a 1s killTimer escalates to
  // SIGKILL (`signal(9)`) if the child is still alive -- `running = false`
  // on its own only sends TERM again (measured: probe A), so it would not
  // actually escalate anything if used here instead. Same-tick guard reads
  // `readProcess.running` directly (skill gotcha #1), never a derived bool.
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
    // N2: only escalate against the SAME process this timer was armed for
    // -- `readProcess.processId` at fire time might belong to a DIFFERENT
    // (later) child if the one that triggered the watchdog already exited
    // and the queue started the next read before this timer fired.
    onTriggered: {
      if (readProcess.running && readProcess.processId === root._readArmedPid) readProcess.signal(9)
    }
  }

  Process {
    id: readProcess
    command: []
    running: false
    onStarted: { root._readArmedPid = processId }
    stdout: SplitParser {
      onRead: function(line) { root._appendReadOutput(line, false) }
    }
    stderr: SplitParser {
      onRead: function(line) { root._appendReadOutput(line, true) }
    }
    // exited(exitCode, exitStatus): exitStatus === 1 is CrashExit (killed by
    // signal) regardless of exitCode -- measured live, a signalled child can
    // report exitCode 0. Treated as a failure either way; folded into a
    // nonzero exitCode so every existing per-kind branch in _applyRead()
    // (which all key off exitCode !== 0) needs no separate crash-aware path.
    onExited: function(exitCode, exitStatus) {
      readWatchdog.stop()
      readKillTimer.stop()
      var kind = root._readKind
      root._readKind = ""
      if (root._readWatchdogFired) {
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
  }

  // F2 (D2 fix): spawned as a DIRECT Process child, no bounded-command
  // wrapper. Quickshell's `quickshell kill` hard-kills only its immediate
  // child; a wrapped grandchild never receives that signal and is
  // reparented to systemd --user on every shell restart (06-verdict.md D2,
  // reproduced live in 09-s5-migration.md). The per-line size cap that the
  // wrapper's now-removed `listen` mode used to enforce is kept here in
  // QML instead (`listenerLineChars`, applied to every line in both
  // onRead handlers below) so output is still bounded.
  //
  // Residual risk (documented, not fixed by this change): an ungraceful
  // SIGKILL of the quickshell process itself (not the graceful
  // `quickshell kill` IPC omarchy-restart-shell uses) can still orphan
  // this direct child, exactly like any orphaned child of any killed
  // process. It self-terminates on its next write once its stdout pipe's
  // read end is gone (EPIPE) rather than running forever.
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

  // S10: same pattern as readWatchdog/readKillTimer above.
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
    // N2: same guard as readKillTimer above.
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
    // N3 (25-fable-review-s10.md): `secret` otherwise lingers in memory if
    // the process never actually starts (e.g. the executable fails to
    // spawn at all -- no onStarted fires, but `running` still flips back to
    // false). Cleared here on every transition to not-running, and again in
    // onExited below as a second, redundant guard for the same lifetime
    // event (harmless if onRunningChanged already cleared it).
    onRunningChanged: { if (!running) secret = "" }
    // 22-login-stdin-bug.md fix at the mechanism level: Process.write()
    // reaches the child's real stdin directly (no backgrounded shell job to
    // silently substitute /dev/null). Every action closes stdin via EOF
    // right after start -- not just login -- since no action here reads
    // further stdin once started; measured live (scratchpad/pm-native probe
    // C): write() then stdinEnabled = false delivers EOF, a following read
    // sees 0 bytes.
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
      actionWatchdog.stop()
      actionKillTimer.stop()
      secret = "" // N3: redundant with onRunningChanged above, belt-and-suspenders.
      var label = actionProcess.label
      var success = false
      if (root._actionWatchdogFired) {
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
  }

  // S10: same pattern again. updateCheckScript already enforces its own
  // internal timeout (MULLVAD_UPDATE_CHECK_TIMEOUT, test/scripts.test.sh),
  // so this watchdog is a backstop for the script hanging outright, not the
  // primary deadline -- 130s, matching the removed bounded-command call's
  // own timeout argument.
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
    // N2: same guard as readKillTimer above.
    onTriggered: {
      if (updateCheckProcess.running && updateCheckProcess.processId === root._updateCheckArmedPid) updateCheckProcess.signal(9)
    }
  }

  // T2: deliberately separate from readProcess/actionProcess -- see the
  // comment on checkForUpdates() above. Not counted in `busy`.
  Process {
    id: updateCheckProcess
    command: []
    running: false
    onStarted: { root._updateCheckArmedPid = processId }
    stdout: SplitParser {
      onRead: function(line) { root._appendUpdateCheckOutput(line, false) }
    }
    stderr: SplitParser {
      onRead: function(line) { root._appendUpdateCheckOutput(line, true) }
    }
    onExited: function(exitCode, exitStatus) {
      updateCheckWatchdog.stop()
      updateCheckKillTimer.stop()
      var timedOutOrOverflowed = root._updateCheckWatchdogFired || root._updateCheckOverflowed
      root._updateCheckWatchdogFired = false
      if (timedOutOrOverflowed) {
        // scripts/mullvad-update-check exit 3 (offline/lock/timeout): "does
        // nothing" per the human's rule -- only the status flips so the UI
        // can say so; updateAvailable/updateTargets/updateCheckedAt are
        // left exactly as they were. A watchdog/overflow kill is treated
        // the same way: inconclusive, not a parse-worthy result.
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
  }
}
