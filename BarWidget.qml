import QtQuick
import qs.Ui

BarWidget {
  id: root
  moduleName: "do1mj.qrz"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "QRZ lookup"
    iconComponent: qLensIcon
    onPressed: function(mouseButton) {
      if (!root.bar) return
      if (mouseButton === Qt.RightButton)
        root.bar.run("xdg-open https://www.qrz.com/")
      else
        root.bar.run("omarchy-shell shell toggle do1mj.qrz '{}'")
    }
  }

  // A "Q" whose tail is drawn long and thick enough to double as a
  // magnifying-glass handle, so the icon reads as both the plugin's
  // initial and a lookup/search glass at bar-icon size.
  Component {
    id: qLensIcon

    Item {
      id: iconRoot
      readonly property color glyphColor: button.active && button.useActiveColor ? button.activeColor : button.foreground

      Text {
        id: qGlyph
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: -parent.width * 0.06
        anchors.verticalCenterOffset: -parent.height * 0.06
        text: "Q"
        font.family: button.fontFamily
        font.bold: true
        font.pixelSize: parent.height * 0.82
        color: iconRoot.glyphColor
      }

      Rectangle {
        width: parent.width * 0.38
        height: Math.max(1.6, parent.height * 0.13)
        radius: height / 2
        color: iconRoot.glyphColor
        antialiasing: true
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: parent.width * 0.30
        anchors.verticalCenterOffset: parent.height * 0.30
        rotation: 45
      }
    }
  }
}
