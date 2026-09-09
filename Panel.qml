import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "ddewolfe.better-omapods"
  ipcTarget: "better-omapods"

  property int cursorIndex: 0
  property bool cursorActive: false
  property bool findConfirmOpen: false
  property string pendingFindSide: ""

  readonly property bool hideWhenDisconnected: setting("hideWhenDisconnected", true) === true
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool modesVisible: device.hasDevice && modes.length > 0
  readonly property bool findVisible: device.hasDevice
  readonly property bool ancVisible: device.hasDevice && device.supportsManualAnc
    && device.noiseMode === Model.NOISE_ANC
  readonly property bool adaptiveVisible: device.hasDevice && device.backend === "librepods"
    && device.supportsAdaptive && device.noiseMode === Model.NOISE_ADAPTIVE
  readonly property bool touchVisible: device.hasDevice && device.touchAvailable
  readonly property int lowBatteryPercent: 20
  readonly property bool showHeadsetIcon: Model.showHeadsetIcon(setting("icon", "Auto"), device.isHeadset)
  readonly property string iconVariant: Model.iconVariant(setting("icon", "Auto"), device.isHeadset)
  readonly property var modes: device.availableModes()
  readonly property var cursorRows: {
    var rows = []
    for (var i = 0; i < modes.length; i++) rows.push("mode:" + modes[i])
    if (ancVisible) rows.push("anc")
    if (adaptiveVisible) rows.push("adaptive")
    if (device.hasDevice) {
      if (device.isHeadset) rows.push("find:both")
      else {
        rows.push("find:left")
        rows.push("find:right")
      }
    }
    if (touchVisible) {
      for (var t = 0; t < device.touchControls.length; t++)
        rows.push("touch:" + device.touchControls[t].id)
      if (device.supportsTouchTone) rows.push("touch-tone")
      if (device.supportsTouchReset) rows.push("touch-reset")
    }
    return rows
  }
  readonly property string cursorRow: cursorRows.length === 0
    ? ""
    : cursorRows[Math.max(0, Math.min(cursorIndex, cursorRows.length - 1))]
  readonly property color barIconColor: device.hasDevice ? barForeground : Qt.darker(barForeground, 1.55)

  function rowHasCursor(name) {
    return cursorActive && cursorRow === name
  }

  function moveCursor(dy) {
    cursorActive = true
    if (cursorRows.length === 0) return
    cursorIndex = Math.max(0, Math.min(cursorRows.length - 1, cursorIndex + dy))
  }

  function nudgeCursor(dx) {
    if (cursorRow === "anc") device.setManualAnc(device.manualAnc + dx)
    else if (cursorRow === "adaptive") device.setAdaptiveNoiseLevel(device.adaptiveNoiseLevel + dx * 5)
    else if (cursorRow.indexOf("touch:") === 0) device.cycleTouch(cursorRow.substring(6), dx)
    else if (cursorRow === "touch-tone" && dx !== 0) device.setTouchTone(!device.touchTone)
  }

  function activateCursor() {
    if (cursorRow.indexOf("mode:") === 0)
      device.setNoiseMode(parseInt(cursorRow.substring(5), 10))
    else if (cursorRow.indexOf("find:") === 0)
      requestFind(cursorRow.substring(5))
    else if (cursorRow.indexOf("touch:") === 0)
      device.cycleTouch(cursorRow.substring(6), 1)
    else if (cursorRow === "touch-tone")
      device.setTouchTone(!device.touchTone)
    else if (cursorRow === "touch-reset")
      device.resetTouch()
  }

  function requestFind(side) {
    if (!device.hasDevice) return
    if (device.findingSide === side) {
      device.stopFind()
      return
    }
    pendingFindSide = side
    findConfirm.selectedIndex = 0
    findConfirmOpen = true
  }

  function cancelFindConfirm() {
    findConfirmOpen = false
    pendingFindSide = ""
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function confirmFind() {
    var side = pendingFindSide
    findConfirmOpen = false
    pendingFindSide = ""
    if (side) device.find(side)
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  visible: !hideWhenDisconnected || device.hasDevice || device.hasBattery
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      cursorIndex = 0
      findConfirmOpen = false
      pendingFindSide = ""
      if (panelFlick) panelFlick.contentY = 0
      device.refresh()
      Qt.callLater(function () { keyCatcher.forceActiveFocus() })
    } else {
      findConfirmOpen = false
      pendingFindSide = ""
      device.stopFind()
    }
  }

  Service {
    id: device
    settings: root.settings
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        BudIcon {
          anchors.centerIn: parent
          // A pair of buds is wider than it is tall, so it takes a size above the stock 12 to carry the row.
          iconSize: Style.space(13)
          color: root.barIconColor
          variant: root.iconVariant
        }
      }
    }
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) device.cycleNoiseMode()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (root.findConfirmOpen) {
          findConfirm.selectedIndex = findConfirm.selectedIndex === 0 ? 1 : 0
          return
        }
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.nudgeCursor(dx)
      }
      onActivateRequested: {
        if (root.findConfirmOpen) {
          if (findConfirm.selectedIndex === 0) root.cancelFindConfirm()
          else root.confirmFind()
          return
        }
        if (root.cursorActive) root.activateCursor()
      }
      onCloseRequested: {
        if (root.findConfirmOpen) {
          root.cancelFindConfirm()
          return
        }
        root.close()
      }
      onTabRequested: function (direction) {
        if (root.findConfirmOpen) return
        root.switchPanel(direction)
      }
      onTextKey: function (t) {
        if (root.findConfirmOpen) return
        var key = String(t).toLowerCase()
        if (key === "r") device.refresh()
        else if (!device.hasDevice) return
        else if (key === "o") device.setNoiseMode(Model.NOISE_OFF)
        else if (key === "t") device.setNoiseMode(Model.NOISE_TRANSPARENCY)
        else if (key === "n") device.setNoiseMode(Model.NOISE_ANC)
        else if (key === "a") device.setNoiseMode(Model.NOISE_ADAPTIVE)
        else if (key === "f") {
          if (device.finding) device.stopFind()
          else if (device.isHeadset) root.requestFind("both")
          else root.requestFind("left")
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: device.modelName !== "" ? device.modelName
              : (device.deviceName !== "" ? device.deviceName : "Soundcore")
            meta: device.hasDevice ? Model.noiseModeName(device.noiseMode)
              : device.daemonReachable ? "Not connected"
              : "Waiting for OpenSCQ30"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: device.hasDevice ? 1.0 : 0.5
            iconComponent: Component {
              BudIcon {
                // Same reason as the bar: display leaves the wide marks short against a two line title.
                iconSize: Style.font.displayLarge
                color: device.hasDevice ? root.foreground : root.dim
                variant: root.iconVariant
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: device.actionStatus !== "" || (device.lastError !== "" && device.daemonReachable)
            width: parent.width
            text: device.actionStatus !== "" ? device.actionStatus : device.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Column {
            visible: device.hasBattery
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "BATTERY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              width: parent.width
              spacing: Style.space(6)

              PodRow {
                visible: device.isHeadset
                width: parent.width
                label: "Headphones"
                pod: ({ level: device.headsetBattery.level, charging: device.headsetBattery.charging, inEar: false, inCase: false })
              }
              PodRow { visible: !device.isHeadset; width: parent.width; label: "Left"; pod: device.leftPod }
              PodRow { visible: !device.isHeadset; width: parent.width; label: "Right"; pod: device.rightPod }
              PodRow {
                visible: !device.isHeadset && device.caseBattery.level !== Model.LEVEL_UNKNOWN
                width: parent.width
                label: "Case"
                pod: ({ level: device.caseBattery.level, charging: device.caseBattery.charging, inEar: false, inCase: false })
              }
            }
          }

          PanelSeparator {
            visible: device.hasBattery && root.findVisible
            foreground: root.foreground
          }

          Column {
            visible: root.findVisible
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "FIND"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: device.finding
                ? "Playing a locating tone. Click the row again to stop."
                : "Pauses whatever is playing, then a loud tone. Playback resumes when the tone stops."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            FindRow {
              visible: !device.isHeadset
              width: parent.width
              label: "Left"
              side: "left"
            }
            FindRow {
              visible: !device.isHeadset
              width: parent.width
              label: "Right"
              side: "right"
            }
            FindRow {
              visible: device.isHeadset
              width: parent.width
              label: "Headphones"
              side: "both"
            }
          }

          PanelSeparator {
            visible: root.findVisible && root.modesVisible
            foreground: root.foreground
          }

          Column {
            visible: root.modesVisible
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "LISTENING MODE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.modes
              ModeRow {
                required property var modelData
                width: parent.width
                mode: modelData
              }
            }

            SliderRow {
              visible: root.ancVisible
              width: parent.width
            }

            AdaptiveSliderRow {
              visible: root.adaptiveVisible
              width: parent.width
            }
          }

          PanelSeparator {
            visible: root.modesVisible && root.touchVisible
            foreground: root.foreground
          }

          Column {
            visible: root.touchVisible
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "TOUCH"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Click a row or use h / l to cycle the action."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: device.touchControls
              TouchRow {
                required property var modelData
                width: parent.width
                control: modelData
              }
            }

            TouchToneRow {
              visible: device.supportsTouchTone
              width: parent.width
            }

            TouchActionRow {
              visible: device.supportsTouchReset
              width: parent.width
              rowName: "touch-reset"
              label: "Reset to defaults"
              onActivated: device.resetTouch()
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: !device.hasDevice && !device.hasBattery
            width: parent.width
            text: "Connect AirPods, Soundcore, or other Bluetooth headphones. Soundcore and AirPods get listening modes. Other pairs get battery when BlueZ reports it, plus Find."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }

      ConfirmDialog {
        id: findConfirm
        anchors.fill: parent
        opened: root.findConfirmOpen
        z: 10
        message: "This pauses whatever is playing, then a loud locating tone. Playback resumes when the tone stops. Take them off your ears first."
        cancelText: "Cancel"
        confirmText: "Play sound"
        background: Color.popups.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.cancelFindConfirm()
        onConfirmed: root.confirmFind()
      }
    }
  }

  component PodRow: Item {
    id: podRow
    property string label: ""
    property var pod: Model.defaultPod()
    property string meta: ""

    readonly property string metaText: meta !== "" ? meta : Model.podMeta(pod)
    readonly property bool low: pod && pod.level !== Model.LEVEL_UNKNOWN
      && pod.level <= root.lowBatteryPercent && !pod.charging

    implicitHeight: podLayout.implicitHeight

    RowLayout {
      id: podLayout
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: podRow.label
        color: root.foreground
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.preferredWidth: Math.max(Style.space(44), implicitWidth + Style.space(10))
      }

      Rectangle {
        id: meterTrack
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        implicitHeight: Style.space(6)
        radius: height / 2
        color: Qt.darker(root.foreground, 3.2)

        Rectangle {
          width: meterTrack.width * Model.levelFraction(podRow.pod ? podRow.pod.level : Model.LEVEL_UNKNOWN)
          height: parent.height
          radius: parent.radius
          color: podRow.low ? root.urgent : root.foreground
        }
      }

      Text {
        textFormat: Text.PlainText
        text: Model.levelText(podRow.pod ? podRow.pod.level : Model.LEVEL_UNKNOWN)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignRight
        Layout.preferredWidth: Style.space(38)
      }

      Text {
        textFormat: Text.PlainText
        text: podRow.metaText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        Layout.preferredWidth: Style.space(64)
      }
    }
  }

  component ModeRow: Item {
    property int mode: Model.NOISE_UNKNOWN
    implicitHeight: Style.space(36)
    readonly property bool selected: device.noiseMode === mode
    readonly property bool hovered: rowHasCursor("mode:" + mode)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: hovered ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
        : "transparent"
    }

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: Model.noiseModeName(mode)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      textFormat: Text.PlainText
      visible: selected
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: Model.GLYPH_CHECK
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: device.setNoiseMode(mode)
    }
  }

  component FindRow: Item {
    property string label: ""
    property string side: ""
    implicitHeight: Style.space(36)
    readonly property bool selected: device.findingSide === side
    readonly property bool hovered: rowHasCursor("find:" + side)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: hovered ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
        : "transparent"
    }

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      textFormat: Text.PlainText
      visible: selected
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: "Stop"
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: root.requestFind(side)
    }
  }

  component SliderRow: Item {
    id: sliderRow
    implicitHeight: sliderColumn.implicitHeight
    readonly property bool hovered: rowHasCursor("anc")

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: sliderRow.hovered ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
        : "transparent"
    }

    Column {
      id: sliderColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(4)

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          text: "ANC strength"
          color: root.foreground
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Item {
          width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2)
          height: 1
        }

        Text {
          textFormat: Text.PlainText
          text: device.manualAnc === Model.LEVEL_UNKNOWN
            ? "--"
            : device.manualAnc + " / " + device.manualAncMax
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      PanelSlider {
        width: parent.width
        bar: root.bar
        minimum: device.manualAncMin
        maximum: device.manualAncMax
        step: 1
        integer: true
        tickCount: Math.max(2, device.manualAncMax - device.manualAncMin + 1)
        value: device.manualAnc === Model.LEVEL_UNKNOWN ? device.manualAncMin : device.manualAnc
        onReleased: function (v) { device.setManualAnc(v) }
      }
    }
  }

  component AdaptiveSliderRow: Item {
    implicitHeight: adaptiveColumn.implicitHeight
    readonly property bool hovered: rowHasCursor("adaptive")

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: hovered ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
        : "transparent"
    }

    Column {
      id: adaptiveColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(4)

      Row {
        width: parent.width
        spacing: Style.space(8)
        Text {
          textFormat: Text.PlainText
          text: "Adaptive noise"
          color: root.foreground
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Item {
          width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2)
          height: 1
        }
        Text {
          textFormat: Text.PlainText
          text: device.adaptiveNoiseLevel + "%"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      PanelSlider {
        width: parent.width
        bar: root.bar
        minimum: 0
        maximum: 100
        step: 5
        integer: true
        tickCount: 5
        value: device.adaptiveNoiseLevel
        onReleased: function (v) { device.setAdaptiveNoiseLevel(v) }
      }
    }
  }

  component TouchRow: Item {
    property var control: ({ id: "", label: "", value: "", options: [] })
    implicitHeight: Style.space(36)
    readonly property bool hovered: rowHasCursor("touch:" + (control ? control.id : ""))

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: hovered ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
        : "transparent"
    }

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: control && control.label ? control.label : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: Model.touchValueLabel(control)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: if (control && control.id) device.cycleTouch(control.id, 1)
    }
  }

  component TouchToneRow: Item {
    implicitHeight: Style.space(36)
    readonly property bool hovered: rowHasCursor("touch-tone")

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: hovered ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
        : "transparent"
    }

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: "Touch tone"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: device.touchTone ? "On" : "Off"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: device.setTouchTone(!device.touchTone)
    }
  }

  component TouchActionRow: Item {
    property string rowName: ""
    property string label: ""
    signal activated()
    implicitHeight: Style.space(36)
    readonly property bool hovered: rowHasCursor(rowName)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: hovered ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
        : "transparent"
    }

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: activated()
    }
  }
}
