import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Dialog {
    id: pane
    required property var controller
    required property var defaults
    property var order: []
    property string note: ""
    title: "编辑常用工具"
    anchors.centerIn: Overlay.overlay
    width: Math.min(680, parent.width - 32)
    height: Math.min(600, parent.height - 32)
    modal: true

    function label(id) {
        const tool = controller.tools.find(item => item.id === id)
        return tool ? tool.label : id
    }

    function moveRow(index, offset) {
        const list = order.slice()
        const item = list.splice(index, 1)[0]
        list.splice(index + offset, 0, item)
        order = list
    }

    onOpened: {
        order = Array.from(controller.favorites.length ? controller.favorites : defaults)
        note = ""
    }

    contentItem: ColumnLayout {
        spacing: 9
        Label { text: pane.order.length + " / 12"; Layout.fillWidth: true }
        RowLayout {
            Layout.fillWidth: true
            ComboBox {
                id: candidate
                Layout.fillWidth: true
                model: pane.controller.tools.filter(tool => !pane.order.includes(tool.id))
                textRole: "label"
                valueRole: "id"
            }
            GlowButton {
                text: "添加"
                enabled: candidate.currentIndex >= 0 && pane.order.length < 12
                onClicked: pane.order = pane.order.concat([candidate.currentValue])
            }
        }
        ListView {
            id: entries
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 4
            model: pane.order
            delegate: RowLayout {
                required property string modelData
                required property int index
                width: entries.width - 10
                Label { text: pane.label(modelData); Layout.fillWidth: true; elide: Text.ElideRight }
                GlowButton { text: "上移"; compact: true; enabled: index > 0; onClicked: pane.moveRow(index, -1) }
                GlowButton { text: "下移"; compact: true; enabled: index + 1 < pane.order.length; onClicked: pane.moveRow(index, 1) }
                GlowButton { text: "移除"; compact: true; onClicked: pane.order = pane.order.filter((_, i) => i !== index) }
            }
            ScrollBar.vertical: ScrollBar {}
        }
        Label { text: pane.note; visible: text !== ""; Layout.fillWidth: true; wrapMode: Text.Wrap }
    }
    footer: RowLayout {
        GlowButton { text: "恢复默认"; Layout.margins: 8; onClicked: pane.order = pane.defaults.slice() }
        Item { Layout.fillWidth: true }
        GlowButton { text: "取消"; Layout.margins: 8; onClicked: pane.close() }
        GlowButton {
            text: "保存"
            primary: true
            enabled: pane.order.length > 0
            Layout.margins: 8
            onClicked: {
                if (pane.controller.setFavorites(pane.order)) pane.close()
                else pane.note = "无法保存常用工具，请检查选项"
            }
        }
    }
}
