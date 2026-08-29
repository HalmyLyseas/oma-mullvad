// BarWidget.qml -- bar entry point for halmylyseas.mullvad.
//
// F1 (D1 fix, exchange/10-s6-fix-spec.md): Service.qml is now a machine-wide
// singleton (manifest kind "service", created once by shell.ensureService()).
// This widget only ever binds to it via shell.serviceFor(moduleName) --
// reactive, because shell._services is reassigned (never mutated) on every
// service add (see /usr/share/omarchy/shell/shell.qml ensureService()).
//
// Panel.qml is hosted from here via a Loader gated on `svc !== null`
// (deliberate, not a lazy-load optimisation): Panel.qml keeps its ~150
// unguarded `service.` bindings because it is only ever instantiated once
// the singleton service actually exists, so it never needs a null-service
// stub state of its own. Every `svc` read in THIS file, by contrast, must be
// guarded -- the bar paints this widget before the service resolves on
// first load.
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
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.svc
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

  onBarChanged: injectPanel()
  onSettingsChanged: { injectPanel(); _pushPollInterval() }
  onSvcChanged: { injectPanel(); _pushPollInterval() }

  Loader {
    id: panelLoader
    // Deliberate gate -- see file header. Panel.qml is only ever created
    // once the singleton service actually resolves.
    active: root.svc !== null
    source: Qt.resolvedUrl("Panel.qml")
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
