import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Dialog {
    id: dialog
    required property var controller
    property string taskId: ""
    property var records: []
    title: "执行记录"
    anchors.centerIn: Overlay.overlay
    width: Math.min(parent.width - 32, 680)
    height: Math.min(parent.height - 32, 470)
    modal: true

    function showTask(id, taskTitle) {
        taskId = id
        title = taskTitle + " · 执行记录"
        records = controller.taskEvents(id)
        open()
    }

    Connections {
        target: dialog.controller
        function onTaskEventsChanged(id) {
            if (dialog.visible && id === dialog.taskId)
                dialog.records = dialog.controller.taskEvents(id)
        }
    }

    contentItem: ColumnLayout {
        Label {
            Layout.fillWidth: true
            text: dialog.records.length ? (dialog.records[0].attempt > 0
                    ? "已记录重试 " + (dialog.records[0].attempt - 1) + " 次" : "旧版导入记录") : "暂无执行记录"
        }
        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 12
            model: dialog.records
            delegate: Column {
                required property var modelData
                width: ListView.view.width - 12
                spacing: 3
                Label {
                    width: parent.width
                    font.bold: true
                    text: (modelData.attempt > 0 ? "第 " + modelData.attempt + " 次 · " : "") + modelData.state
                }
                Label {
                    width: parent.width
                    text: modelData.timestamp > 0 ? Qt.formatDateTime(new Date(modelData.timestamp), "yyyy-MM-dd hh:mm:ss")
                                                  : "旧版记录 · 时间未知"
                }
                Label {
                    width: parent.width
                    visible: text.length > 0
                    text: [modelData.message, modelData.errorCode].filter(Boolean).join(" · ")
                    textFormat: Text.PlainText
                    wrapMode: Text.WrapAnywhere
                }
            }
            ScrollBar.vertical: ScrollBar {}
        }
    }

    footer: RowLayout {
        Item { Layout.fillWidth: true }
        GlowButton { text: "关闭"; Layout.margins: 8; onClicked: dialog.close() }
    }
}
