import QtQuick
QtObject {
  property bool waitForEnd: false
  property string data: ""
  signal streamFinished()
  function text() { return data }
}
