pragma Singleton
import QtQuick
QtObject {
  property QtObject applications: QtObject { property var values: [] }
  function byId(id) { return null }
}
