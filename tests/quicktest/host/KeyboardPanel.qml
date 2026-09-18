import QtQuick
Item {
  id: root
  width: contentWidth
  height: contentHeight
  property var anchorItem: null
  property var owner: null
  property var bar: null
  property bool open: false
  property Item focusTarget: null
  property real contentWidth: 600
  property real contentHeight: 600
  property real availableCardHeight: 700
  property real screenH: 700
  property string barPos: "top"
  property real gap: 5
  property real margin: 5
  property real verticalContentInset: 0
  function fittedContentWidth(value, cap) { return Math.min(value, cap) }
  function fittedContentHeight(value, cap) { return Math.min(value, cap) }
  function cappedContentHeight(value) { return value }
}
