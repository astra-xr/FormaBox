import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Dialog {
    id: dialog
    required property var controller
    property int jobIndex: -1
    property string directory: ""
    property var items: []
    property var selected: []
    property string notice: ""
    signal resultFilesChosen(var paths)

    title: "任务结果"
    anchors.centerIn: Overlay.overlay
    width: Math.min(parent.width - 32, 850)
    height: Math.min(parent.height - 32, 580)
    modal: true

    function showJob(index, folder) {
        jobIndex = index
        directory = folder
        items = Array.from(controller.resultItems(index))
        selected = []
        notice = ""
        open()
    }

    function choose(path, checked) {
        selected = checked ? selected.concat([path]) : selected.filter(item => item !== path)
    }

    function useSelected() {
        const paths = Array.from(controller.useResults(jobIndex, selected))
        if (!paths.length) {
            notice = "选中的输出已移走或删除"
            items = Array.from(controller.resultItems(jobIndex))
            selected = []
            return
        }
        resultFilesChosen(paths)
        close()
    }

    function openItem(path) {
        notice = controller.openResult(jobIndex, path) ? "" : "无法打开此文件，请查看输出目录"
    }

    function sizeLabel(bytes) {
        if (bytes < 1024)
            return bytes + " B"
        if (bytes < 1048576)
            return (bytes / 1024).toFixed(1) + " KiB"
        return (bytes / 1048576).toFixed(2) + " MiB"
    }

    contentItem: ColumnLayout {
        spacing: 8
        Label {
            Layout.fillWidth: true
            text: dialog.items.length ? "输出 " + dialog.items.length + " 项" : "这条记录仅保留了输出目录"
            font.bold: true
        }
        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 4
            model: dialog.items
            delegate: RowLayout {
                id: entry
                required property var modelData
                width: ListView.view.width - 8
                CheckBox {
                    enabled: entry.modelData.available
                    checked: dialog.selected.includes(entry.modelData.path)
                    onToggled: dialog.choose(entry.modelData.path, checked)
                    Accessible.name: "选择 " + entry.modelData.name
                }
                ItemDelegate {
                    Layout.fillWidth: true
                    Layout.preferredHeight: caption.implicitHeight + 16
                    enabled: entry.modelData.canOpen
                    onDoubleClicked: dialog.openItem(entry.modelData.path)
                    contentItem: Column {
                        id: caption
                        spacing: 3
                        Label {
                            width: parent.width
                            text: entry.modelData.name
                            textFormat: Text.PlainText
                            elide: Text.ElideMiddle
                        }
                        Label {
                            width: parent.width
                            elide: Text.ElideRight
                            font.pixelSize: 12
                            text: {
                                const item = entry.modelData
                                if (!item.available)
                                    return "文件已移走或删除"
                                if (item.folder)
                                    return "文件夹"
                                let info = dialog.sizeLabel(item.bytes)
                                if (item.original_bytes !== undefined)
                                    info = dialog.sizeLabel(item.original_bytes) + " → " + info
                                if (item.target_bytes > 0)
                                    info += " · 目标 " + dialog.sizeLabel(item.target_bytes) +
                                             (item.bytes <= item.target_bytes ? " · 已达标" : " · 超出目标")
                                return info
                            }
                        }
                    }
                }
                GlowButton {
                    text: "打开"
                    enabled: entry.modelData.canOpen
                    onClicked: dialog.openItem(entry.modelData.path)
                }
            }
            ScrollBar.vertical: ScrollBar {}
        }
        Label { Layout.fillWidth: true; text: dialog.notice; visible: text.length > 0; wrapMode: Text.Wrap }
        RowLayout {
            Layout.fillWidth: true
            GlowButton { text: "打开输出目录"; onClicked: dialog.controller.openFolder(dialog.directory) }
            Item { Layout.fillWidth: true }
            GlowButton { text: "关闭"; onClicked: dialog.close() }
            GlowButton {
                text: "用作当前输入" + (dialog.selected.length ? " (" + dialog.selected.length + ")" : "")
                highlighted: true
                enabled: dialog.selected.length > 0
                onClicked: dialog.useSelected()
            }
        }
    }
}
