import QtQuick
import QtTest
import qs.Ui as Ui
import "../.." as Plugin

Item {
  id: scene
  width: 720
  height: 640

  QtObject {
    id: fakeShell
    function updateEntryInline(id, entry) {}
  }

  QtObject {
    id: fakeBar
    property color foreground: "#eeeeee"
    property color urgent: "#ff5555"
    property string fontFamily: "monospace"
    property string position: "top"
    property int barSize: 26
    property var shell: fakeShell
  }

  QtObject {
    id: fakeHost
    property color stateColor: "#eeeeee"
    property string stateIcon: "disconnected"
    property var settings: ({})
  }

  QtObject {
    id: fakeService
    property bool installed: true
    property bool daemonRunning: true
    property bool active: false
    property bool connected: false
    property bool busy: false
    property string state: "disconnected"
    property string statusText: "Disconnected"
    property string country: ""
    property string city: ""
    property string hostname: ""
    property string ip: ""
    property string lastError: ""
    property bool cliVersionSupported: true
    property string cliVersion: "2026.4"
    property bool tunnelDropWarning: false
    property bool loggedIn: false
    property int accountDaysRemaining: -1
    property string accountExpiry: ""
    property bool lockdown: false
    property bool autoConnect: false
    property bool lanSharing: false
    property var locations: []
    property var providers: []
    property var relayConstraints: ({ location: { type: "any" }, providers: [], ownership: "any", ipVersion: "any", multihop: false, entry: {} })
    property var dns: ({})
    property var antiCensorship: ({ mode: "auto" })
    property var excludedProcesses: []
    property int toggleCount: 0
    property int refreshCount: 0
    property int selectCount: 0
    property string selectedCountry: ""
    property string selectedCity: ""
    function refreshAll() { refreshCount++ }
    function refreshExcluded() {}
    function toggleTunnel() { toggleCount++ }
    function selectLocation(countryCode, cityCode, reconnect, hostname) {
      selectCount++
      selectedCountry = countryCode
      selectedCity = cityCode
      return true
    }
    function launchExcludedApp(desktopId) { return false }
  }

  Component {
    id: panelComponent
    Plugin.Panel {
      service: fakeService
      bar: fakeBar
      anchorItem: scene
      hostWidget: fakeHost
      settings: ({ favoriteLocations: [], recentLocations: [], recentExcludedApps: [] })
    }
  }

  Component {
    id: dropdownComponent
    Plugin.OmaDropdown {
      width: 320
      showLabel: false
      options: [
        { value: "se", label: "Sweden" },
        { value: "de", label: "Germany" }
      ]
      value: "se"
    }
  }

  Component {
    id: searchableComponent
    Plugin.OmaSearchableDropdown {
      width: 320
      showLabel: false
      options: [
        { value: "se", label: "Sweden" },
        { value: "de", label: "Germany" },
        { value: "us", label: "United States" }
      ]
    }
  }

  Component {
    id: dialogComponent
    Ui.ConfirmDialog {
      width: 600
      height: 300
      message: "Proceed?"
      focus: opened
      Keys.onPressed: function(event) {
        if (handleKey(event)) event.accepted = true
      }
    }
  }

  Component {
    id: mapComponent
    Plugin.WorldMap {
      width: 500
      height: 250
      locations: [{ value: "origin", latitude: 0, longitude: 0 }]
    }
  }

  TestCase {
    name: "PhysicalInput"
    when: windowShown

    SignalSpy { id: changedSpy; signalName: "changed" }
    SignalSpy { id: cancelSpy; signalName: "canceled" }
    SignalSpy { id: confirmSpy; signalName: "confirmed" }
    SignalSpy { id: mapSpy; signalName: "locationSelected" }

    function init() {
      changedSpy.clear()
      cancelSpy.clear()
      confirmSpy.clear()
      mapSpy.clear()
      changedSpy.target = null
      cancelSpy.target = null
      confirmSpy.target = null
      mapSpy.target = null
      fakeService.locations = []
      fakeService.selectCount = 0
      fakeService.selectedCountry = ""
      fakeService.selectedCity = ""
    }

    function findWorldMap(item) {
      if (!item) return null
      if (typeof item._probeMarkerHitTarget === "function") return item
      var children = item.children || []
      for (var i = 0; i < children.length; i++) {
        var found = findWorldMap(children[i])
        if (found) return found
      }
      return null
    }

    function findTextItem(item, text) {
      if (!item) return null
      if (item.text === text) return item
      var children = item.children || []
      for (var i = 0; i < children.length; i++) {
        var found = findTextItem(children[i], text)
        if (found) return found
      }
      return null
    }

    function test_dropdown_keyboard_open_move_select() {
      var control = createTemporaryObject(dropdownComponent, scene, { x: 30, y: 30 })
      verify(control !== null)
      changedSpy.target = control
      control.focusTrigger()
      tryCompare(control, "triggerFocused", true)
      keyClick(Qt.Key_Space)
      tryCompare(control, "popupOpen", true)
      keyClick(Qt.Key_Down)
      keyClick(Qt.Key_Return)
      tryCompare(changedSpy, "count", 1)
      compare(changedSpy.signalArguments[0][0], "de")
      tryCompare(control, "popupOpen", false)
    }

    function test_panel_keyboard_numeric_navigation_and_tunnel_shortcut() {
      var panel = createTemporaryObject(panelComponent, scene)
      verify(panel !== null)
      fakeService.toggleCount = 0
      panel._probeKeyCatcher.forceActiveFocus()
      tryCompare(panel._probeKeyCatcher, "activeFocus", true)
      keyClick(Qt.Key_2)
      tryCompare(panel, "pageIndex", 1)
      verify(panel._probePageItem !== null)
      keyClick(Qt.Key_1)
      tryCompare(panel, "pageIndex", 0)
      keyClick(Qt.Key_T)
      compare(fakeService.toggleCount, 1)
    }


    function test_dropdown_pointer_trigger_and_row_selection() {
      var control = createTemporaryObject(dropdownComponent, scene, { x: 30, y: 30 })
      verify(control !== null)
      changedSpy.target = control
      mouseClick(control, control.width / 2, control.rowHeight / 2)
      tryCompare(control, "popupOpen", true)
      tryCompare(control, "popupFocused", true)
      compare(control._probeCurrentIndex, 0)
      var row = control._probeOptionHitTarget(1)
      verify(row !== null)
      mouseClick(row, row.width / 2, row.height / 2)
      tryCompare(changedSpy, "count", 1)
      compare(changedSpy.signalArguments[0][0], "de")
      tryCompare(control, "popupOpen", false)
    }

    function test_searchable_keyboard_open_text_filter_select() {
      var control = createTemporaryObject(searchableComponent, scene, { x: 30, y: 30 })
      verify(control !== null)
      changedSpy.target = control
      control.focusTrigger()
      tryCompare(control, "triggerFocused", true)
      keyClick(Qt.Key_Space)
      tryCompare(control, "popupOpen", true)
      keyClick(Qt.Key_G)
      keyClick(Qt.Key_E)
      keyClick(Qt.Key_R)
      keyClick(Qt.Key_M)
      tryCompare(control.filtered, "length", 1)
      keyClick(Qt.Key_Return)
      tryCompare(changedSpy, "count", 1)
      compare(changedSpy.signalArguments[0][0], "de")
      tryCompare(control, "popupOpen", false)
    }

    function test_searchable_pointer_trigger_and_row_selection() {
      var control = createTemporaryObject(searchableComponent, scene, { x: 30, y: 30 })
      verify(control !== null)
      changedSpy.target = control
      mouseClick(control, control.width / 2, control.rowHeight / 2)
      tryCompare(control, "popupOpen", true)
      tryCompare(control, "popupFocused", true)
      var row = control._probeOptionHitTarget(1)
      verify(row !== null)
      verify(row.visible && row.width > 0 && row.height > 0)
      tryVerify(function() { return row.parent.y > 0 })
      var point = control._probeOptionCenter(1, scene)
      verify(point.x >= 0 && point.y >= 0)
      mouseMove(scene, point.x, point.y)
      tryCompare(control, "_probeCurrentIndex", 1)
      mouseClick(scene, point.x, point.y)
      tryCompare(changedSpy, "count", 1)
      compare(changedSpy.signalArguments[0][0], "de")
      tryCompare(control, "popupOpen", false)
    }

    function test_dialog_keyboard_cancel_and_accept() {
      var dialog = createTemporaryObject(dialogComponent, scene)
      verify(dialog !== null)
      cancelSpy.target = dialog
      confirmSpy.target = dialog
      dialog.opened = true
      dialog.forceActiveFocus()
      keyClick(Qt.Key_Escape)
      compare(cancelSpy.count, 1)
      dialog.opened = true
      dialog.forceActiveFocus()
      keyClick(Qt.Key_Left)
      compare(dialog.selectedIndex, 0)
      keyClick(Qt.Key_Right)
      compare(dialog.selectedIndex, 1)
      keyClick(Qt.Key_Return)
      compare(confirmSpy.count, 1)
    }

    function test_dialog_pointer_cancel_and_accept() {
      var dialog = createTemporaryObject(dialogComponent, scene)
      verify(dialog !== null)
      cancelSpy.target = dialog
      confirmSpy.target = dialog
      dialog.opened = true
      var cancelLabel = findTextItem(dialog, "Cancel")
      var confirmLabel = findTextItem(dialog, "Confirm")
      verify(cancelLabel !== null)
      verify(confirmLabel !== null)
      mouseClick(cancelLabel.parent, cancelLabel.parent.width / 2, cancelLabel.parent.height / 2)
      compare(cancelSpy.count, 1)
      dialog.opened = true
      mouseClick(confirmLabel.parent, confirmLabel.parent.width / 2, confirmLabel.parent.height / 2)
      compare(confirmSpy.count, 1)
    }

    function test_world_map_pointer_selection_emits_location_payload() {
      var map = createTemporaryObject(mapComponent, scene, { x: 30, y: 30 })
      verify(map !== null)
      mapSpy.target = map
      waitForRendering(map)
      mouseClick(map, 250, 125)
      tryCompare(mapSpy, "count", 1)
      compare(mapSpy.signalArguments[0][0].value, "origin")
    }

    function test_panel_world_map_pointer_selection_reaches_inert_service() {
      fakeService.locations = [{
        countryCode: "se", cityCode: "got", country: "Sweden", city: "Gothenburg",
        latitude: 0, longitude: 0, servers: []
      }]
      var panel = createTemporaryObject(panelComponent, scene)
      verify(panel !== null)
      waitForRendering(panel)
      var map = findWorldMap(panel._probePageItem)
      verify(map !== null)
      var marker = map._probeMarkerHitTarget(0)
      verify(marker !== null)
      mouseClick(marker, marker.width / 2, marker.height / 2)
      tryCompare(fakeService, "selectCount", 1)
      compare(fakeService.selectedCountry, "se")
      compare(fakeService.selectedCity, "got")
      compare(panel.selectedLocation.cityCode, "got")
    }
  }
}
