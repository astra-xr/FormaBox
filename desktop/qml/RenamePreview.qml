import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Dialog {
    id: dialog
    required property var controller
    property var rows: []
    property var inputs: []
    property var options: ({})
    property string destination: ""
    property string planId: ""
    property string notice: ""
    property bool loading: false
    readonly property bool applicable: !loading && notice === "" && planId !== "" && rows.length > 0 &&
                                       !rows.some(row => row.error)

    title: "批量重命名预览"
    anchors.centerIn: Overlay.overlay
    width: Math.min(parent.width - 32, 880)
    height: Math.min(parent.height - 32, 570)
    modal: true

    function showPreview(paths, params, output) {
        if (controller.inspecting)
            return
        inputs = paths.slice()
        options = Object.assign({}, params)
        destination = output
        rows = []
        planId = ""
        notice = ""
        loading = true
        open()
        controller.previewRename(inputs, options)
    }

    function submitPreview() {
        if (!applicable)
            return
        controller.submit("file.rename", inputs, Object.assign({}, options, {expected_plan: planId}), destination)
        close()
    }

    Connections {
        target: dialog.controller
        function onRenamePreviewReady(rows, plan, error) {
            dialog.rows = Array.from(rows)
            dialog.planId = plan
            dialog.notice = error
            dialog.loading = false
        }
    }

    contentItem: ColumnLayout {
        spacing: 8
        Label {
            Layout.fillWidth: true
            text: dialog.loading ? "正在生成预览…" : dialog.notice ||
                  (dialog.rows.length + " 项 · " + dialog.rows.filter(item => item.error).length + " 项需要处理")
            font.bold: true
            wrapMode: Text.Wrap
        }
        RowLayout {
            Layout.fillWidth: true
            Label { Layout.fillWidth: true; Layout.preferredWidth: 1; text: "原文件名"; font.bold: true }
            Label { Layout.fillWidth: true; Layout.preferredWidth: 1; text: "输出文件名"; font.bold: true }
        }
        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 6
            model: dialog.rows
            delegate: RowLayout {
                required property var modelData
                width: ListView.view.width - 10
                Label {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    text: modelData.old
                    textFormat: Text.PlainText
                    elide: Text.ElideMiddle
                    ToolTip.visible: sourceHover.hovered
                    ToolTip.text: modelData.source
                    HoverHandler { id: sourceHover }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Label {
                        Layout.fillWidth: true
                        text: modelData.name || "—"
                        textFormat: Text.PlainText
                        elide: Text.ElideMiddle
                    }
                    Label {
                        visible: !!modelData.error
                        Layout.fillWidth: true
                        text: modelData.error
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                    }
                }
            }
            ScrollBar.vertical: ScrollBar {}
        }
        Label { text: "输出为副本，原文件保留。"; Layout.fillWidth: true }
        RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            GlowButton { text: "返回修改"; onClicked: dialog.close() }
            GlowButton { text: "复制并重命名"; highlighted: true; enabled: dialog.applicable; onClicked: dialog.submitPreview() }
        }
    }
}
