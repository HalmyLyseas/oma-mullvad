// BarWidget.qml -- bar entry point for halmylyseas.mullvad.
//
// F1 (D1 fix, exchange/10-s6-fix-spec.md): Service.qml is now a machine-wide
// singleton (manifest kind "service", created once by shell.ensureService()).
// This widget only ever binds to it via shell.serviceFor(moduleName) --
// reactive, because shell._services is reassigned (never mutated) on every
// service add (see /usr/share/omarchy/shell/shell.qml ensureService()).
//
// Panel.qml is hosted from here via a Loader gated `active: root.svc !==
// null` (N4, 25-fable-review-s10.md). _loadPanel() calls
// panelLoader.setSource(Qt.resolvedUrl("Panel.qml"), { bar, settings,
// anchorItem, hostWidget, service }) whenever the Loader is active and not
// yet loaded (checked via `panelLoader.status === Loader.Null`) -- i.e. on
// Component.onCompleted and on every onSvcChanged, whichever fires first, or
// again after a later re-arm (see below). Quickshell's
// `Loader.setSource(url, initialProperties)` applies those properties as
// the component's initial property values, evaluated before the component's
// own bindings run -- so Panel.qml's ~150 unguarded `service.`/`bar.`/etc.
// reads never evaluate against `null` for even a single frame on a freshly
// loaded Panel.
//
// C3 (12-fable-review.md) removed this `active` gate on the theory that the
// setSource-with-initial-properties mechanism alone was sufficient, since
// two restarts + a panel open produced zero TypeErrors with it removed at
// the time. That measurement was real but incomplete: it did not cover the
// DESTROY path. `/usr/share/omarchy/shell/shell.qml`'s `_syncServices()`
// destroys and recreates a plugin's service instance if the plugin registry
// transiently reports it disabled at startup (a real, observed race, not
// hypothetical -- exchange/24-s10-native-process.md deviation 5's ~35-88
// line TypeError bursts on `omarchy restart shell`). Without the gate, `svc`
// transitions non-null -> null -> (new instance) non-null on the SAME
// BarWidget instance; `onSvcChanged` still fires `injectPanel()` while
// `svc` is null, which used to write `service = null` straight into the
// ALREADY-LIVE Panel instance from the first (now-destroyed) service --
// every one of Panel's ~150 unguarded `service.` reads then throws. Putting
// the gate back fixes this at the root: when `svc` goes null, the Loader
// deactivates (destroying the stale Panel, resetting `status` to
// `Loader.Null`); when a NEW `svc` arrives, `_loadPanel()`'s `status ===
// Loader.Null` check re-fires `setSource` with the new instance, producing
// a fresh, properly-initialized Panel instead of mutating a live one to
// null and back. `injectPanel()` additionally returns early whenever
// `root.svc` is null, as a second, redundant guard for the same event (see
// docs/developers.md "How the Panel Loader avoids a null-service Panel
// (C3)" for the corrected writeup). Every `svc` read in THIS file must
// still be guarded -- the bar paints this widget before the service
// resolves on first load.
import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "halmylyseas.mullvad"

  readonly property var shell: bar && bar.shell ? bar.shell : null
  readonly property var svc: shell ? shell.serviceFor("halmylyseas.mullvad") : null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color barForeground: bar ? bar.barForeground : Color.foreground

  // Moved verbatim from Panel.qml (was computed against the local `service`
  // id there); every `service.` read becomes `svc ? svc.x : <default>`.
  readonly property string stateIcon: !svc ? "connecting"
    : svc.state === "checking" ? "connecting"
    : !svc.installed || (svc.installed && !svc.daemonRunning) || svc.state === "error" ? "error"
    : svc.state === "blocked" ? "warning"
    : svc.tunnelDropWarning || (svc.loggedIn && svc.accountDaysRemaining >= 0 && svc.accountDaysRemaining <= 7) ? "warning"
    : svc.transitional ? "connecting"
    : svc.connected ? "connected" : "disconnected"
  readonly property color stateColor: stateIcon === "error" || stateIcon === "warning" ? urgent
    : (svc && svc.connected) ? foreground
    : Qt.darker(foreground, 1.55)
  readonly property string tunnelHint: (svc && svc.active) ? "Disconnect Mullvad VPN" : "Connect Mullvad VPN"
  readonly property string barTooltip: !svc ? "Checking Mullvad…"
    : !svc.installed ? "Mullvad CLI is not installed"
    : !svc.daemonRunning ? "Mullvad daemon is unavailable"
    : stateIcon === "error" ? "Mullvad tunnel error"
    : stateIcon === "warning" ? (svc.state === "blocked" ? "Mullvad is blocking network traffic"
      : svc.tunnelDropWarning
      ? "Mullvad tunnel dropped unexpectedly"
      : "Mullvad account credit expires soon")
    : tunnelHint

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  // The panel is loaded standalone once svc exists, so it needs everything
  // handed to it: the bar, this widget's settings, the button to anchor
  // against, this widget (hostWidget), and the resolved service instance.
  function injectPanel() {
    // N4: never write into a live Panel while svc is null (see file header)
    // -- redundant with the Loader's own `active` gate, but cheap and
    // catches this even if injectPanel() is ever called from somewhere the
    // gate doesn't cover.
    if (!root.svc) return
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.svc
  }

  // N4/C3: creates Panel.qml once the Loader is active (svc non-null) and
  // not already loaded, passing every dependency as an INITIAL property via
  // setSource(url, props) rather than a `source:` binding + post-hoc
  // injection -- see the file-header comment. The `status === Loader.Null`
  // check makes this idempotent: harmless to call again from
  // Component.onCompleted, onSvcChanged (whichever fires first), or a LATER
  // onSvcChanged after the Loader deactivated (svc went null) and then
  // reactivated (a new svc instance arrived) -- each such cycle gets a
  // fresh Panel, never a stale one mutated back to non-null.
  function _loadPanel() {
    if (!root.svc || panelLoader.status !== Loader.Null) return
    panelLoader.setSource(Qt.resolvedUrl("Panel.qml"), {
      bar: root.bar, settings: root.settings, anchorItem: button,
      hostWidget: root, service: root.svc
    })
  }

  // Pushes the widget's own refreshIntervalSec setting down onto the
  // singleton service -- the service does not read bar-widget `settings`
  // itself (it is shared machine-wide and has no single owning widget), so
  // the widget is responsible for translating its setting into the
  // service's plain `pollInterval` (ms), clamped the same way the service
  // clamps it internally.
  function _pushPollInterval() {
    if (!svc) return
    var seconds = Number(root.setting("refreshIntervalSec", 30)) || 30
    svc.pollInterval = Math.max(5000, Math.min(3600000, seconds * 1000))
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: _loadPanel()
  onBarChanged: injectPanel()
  onSettingsChanged: { injectPanel(); _pushPollInterval() }
  onSvcChanged: { _loadPanel(); injectPanel(); _pushPollInterval() }

  Loader {
    id: panelLoader
    // N4 (25-fable-review-s10.md): re-instated -- see file header. No
    // `source` binding; created via root._loadPanel()'s setSource(url,
    // initialProps) call, which only ever runs while this is active.
    active: root.svc !== null
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.barTooltip
    iconComponent: Component {
      Item {
        ThemeIcon {
          anchors.centerIn: parent
          iconSize: Style.bar.iconCanvas
          state: root.stateIcon
          color: root.svc && root.svc.connected ? root.barForeground : Qt.darker(root.barForeground, 1.5)
          urgentColor: root.urgent
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) { if (root.svc) root.svc.toggleTunnel() }
      else if (buttonCode === Qt.MiddleButton) { if (root.svc) root.svc.refreshAll() }
      else root.toggle()
    }
  }
}
