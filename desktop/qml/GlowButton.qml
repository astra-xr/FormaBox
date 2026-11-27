import QtQuick
import QtQuick.Controls
import QtQuick.Shapes

Button {
    id: control
    property bool selected: false
    property bool primary: false
    property bool destructive: false
    property bool centered: true
    property bool compact: false
    property string caption: ""

    readonly property bool dark: palette.window.r + palette.window.g + palette.window.b < 1.5
    readonly property bool filled: primary || highlighted
    readonly property bool lit: enabled && (pointer.hovered || visualFocus)

    implicitWidth: Math.max(compact ? 30 : 58, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(compact ? 28 : 36, implicitContentHeight + topPadding + bottomPadding)
    horizontalPadding: compact ? 8 : 12
    verticalPadding: compact ? 3 : 6
    hoverEnabled: true
    font.weight: filled || selected || caption !== "" ? Font.DemiBold : Font.Normal
    Accessible.description: caption

    HoverHandler {
        id: pointer
        enabled: control.enabled
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    }

    contentItem: Item {
        implicitWidth: Math.max(title.implicitWidth, subtitle.visible ? subtitle.implicitWidth : 0)
        implicitHeight: words.implicitHeight
        opacity: control.enabled ? 1 : 0.58
        Column {
            id: words
            width: parent.width
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3
            Label {
                id: title
                width: parent.width
                text: control.text
                textFormat: Text.PlainText
                color: control.filled || (control.destructive && (control.hovered || control.down))
                       ? "#ffffff" : control.palette.buttonText
                font: control.font
                horizontalAlignment: control.centered ? Text.AlignHCenter : Text.AlignLeft
                wrapMode: control.caption ? Text.Wrap : Text.NoWrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
            Label {
                id: subtitle
                width: parent.width
                visible: control.caption !== ""
                text: control.caption
                textFormat: Text.PlainText
                color: control.dark ? "#b7c8dc" : "#53677c"
                font.pixelSize: 11
                horizontalAlignment: control.centered ? Text.AlignHCenter : Text.AlignLeft
                elide: Text.ElideRight
            }
        }
    }

    background: Rectangle {
        id: body
        radius: 9
        readonly property bool danger: control.destructive && (control.hovered || control.down)
        border.width: control.visualFocus ? 2 : 1
        border.color: control.visualFocus ? control.palette.highlight
                      : danger ? "#a64148"
                      : control.filled ? "#548a81"
                      : control.selected ? (control.dark ? "#6da99f" : "#6aa197")
                      : control.lit ? (control.dark ? "#657f95" : "#98abbe")
                      : control.dark ? "#42566a" : "#c8d3df"
        gradient: Gradient {
            GradientStop {
                position: 0
                color: body.danger ? (control.down ? "#892d36" : "#ac4650")
                       : control.filled ? (control.down ? "#255850" : "#316e63")
                       : control.selected ? (control.dark ? "#2d5755" : "#e6f4f0")
                       : control.dark ? "#344658" : "#ffffff"
            }
            GradientStop {
                position: 1
                color: body.danger ? "#842c35"
                       : control.filled ? (control.down ? "#1b4741" : "#255850")
                       : control.selected ? (control.dark ? "#264a49" : "#dceee9")
                       : control.down ? (control.dark ? "#22303d" : "#e4ebf3")
                       : control.dark ? "#2a3a4a" : "#f0f4f9"
            }
        }

        Shape {
            id: reflection
            objectName: "buttonReflection"
            anchors.fill: parent
            anchors.margins: body.border.width
            readonly property real corner: Math.max(0, Math.min(body.radius - body.border.width, width / 2, height / 2))
            readonly property point position: pointer.hovered ? pointer.point.position : Qt.point(width / 2, 1)
            opacity: control.lit ? (control.down ? 0.32 : 0.8) : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 125; easing.type: Easing.OutQuad } }
            ShapePath {
                strokeWidth: -1
                startX: reflection.corner
                startY: 0
                fillGradient: RadialGradient {
                    centerX: reflection.position.x - body.border.width
                    centerY: reflection.position.y * 0.65 - body.border.width
                    focalX: centerX
                    focalY: centerY
                    centerRadius: Math.max(32, Math.min(100, reflection.width * 0.74))
                    GradientStop { position: 0; color: body.danger ? "#36ffc4c7" : control.dark || control.filled ? "#8fb6fff0" : "#6746b7a9" }
                    GradientStop { position: 0.38; color: body.danger ? "#16ffc4c7" : control.dark || control.filled ? "#46a9daca" : "#3246b7a9" }
                    GradientStop { position: 1; color: "transparent" }
                }
                PathLine { x: reflection.width - reflection.corner; y: 0 }
                PathQuad { x: reflection.width; y: reflection.corner; controlX: reflection.width; controlY: 0 }
                PathLine { x: reflection.width; y: reflection.height - reflection.corner }
                PathQuad { x: reflection.width - reflection.corner; y: reflection.height; controlX: reflection.width; controlY: reflection.height }
                PathLine { x: reflection.corner; y: reflection.height }
                PathQuad { x: 0; y: reflection.height - reflection.corner; controlX: 0; controlY: reflection.height }
                PathLine { x: 0; y: reflection.corner }
                PathQuad { x: reflection.corner; y: 0; controlX: 0; controlY: 0 }
            }
        }
    }
}
