import QtQuick
Item {
  id: root
  width: 600
  height: 600
  property var bar: null
  property var settings: ({})
  property string moduleName: ""
  property string ipcTarget: ""
  property bool manageIpc: true
  property bool opened: true
  function open() { opened = true }
  function close() { opened = false }
  function toggle() { opened = !opened }
  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }
}
