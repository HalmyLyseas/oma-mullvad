import QtQuick
QtObject {
  property var command: []
  property bool running: false
  property var stdout: null
  property var stderr: null
  property var stdin: null
  signal exited(int exitCode, int exitStatus)
  function signal(signalNumber) {}
}
