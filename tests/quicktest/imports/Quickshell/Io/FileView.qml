import QtQuick
QtObject {
  property string path: ""
  property bool watchChanges: false
  property bool printErrors: false
  signal loaded()
  signal loadFailed()
  signal fileChanged()
  function text() { return "" }
  function reload() {}
}
