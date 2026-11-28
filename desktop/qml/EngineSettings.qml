import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

Dialog {
    id: pane
    required property var controller
    property var paths: ({})
    property var results: ({})
    property string message: ""
    property string browseEngine: ""
    readonly property var engines: controller.engineOptions

    title: "引擎设置"
    anchors.centerIn: Overlay.overlay
    width: Math.min(parent.width - 32, 730)
    modal: true
    closePolicy: controller.inspecting ? Popup.NoAutoClose : Popup.CloseOnEscape

    onOpened: {
        paths = controller.enginePaths()
        results = {}
        message = ""
    }

    function setPath(engine, path) {
        const next = Object.assign({}, paths)
        next[engine] = path
        paths = next
        results = {}
        message = ""
    }

    Connections {
        target: pane.controller
        function onEnginesChecked(results, message) {
            pane.results = results
            pane.message = message
        }
    }

    FileDialog {
        id: executable
        property string executableFilter
        title: "选择 " + pane.browseEngine + " 程序"
        fileMode: FileDialog.OpenFile
        nameFilters: [executableFilter, "所有文件 (*)"]
        onAccepted: pane.setPath(pane.browseEngine, pane.controller.localPath(selectedFile))
    }

    contentItem: ColumnLayout {
        spacing: 12

        Label {
            Layout.fillWidth: true
            text: "留空时自动查找，优先使用随万象安装的引擎。也可选择其他版本并测试。"
            wrapMode: Text.Wrap
        }
        Repeater {
            model: pane.engines
            delegate: ColumnLayout {
                required property var modelData
                readonly property var check: pane.results[modelData.id]
                Layout.fillWidth: true
                spacing: 5

                Label { text: modelData.name; font.bold: true }
                RowLayout {
                    Layout.fillWidth: true
                    TextField {
                        Layout.fillWidth: true
                        text: pane.paths[modelData.id] || ""
                        placeholderText: "自动查找"
                        Accessible.name: modelData.name + " 路径"
                        enabled: !pane.controller.inspecting
                        onTextEdited: pane.setPath(modelData.id, text)
                    }
                    GlowButton {
                        text: "浏览"
                        enabled: !pane.controller.inspecting
                        onClicked: {
                            pane.browseEngine = modelData.id
                            executable.executableFilter = modelData.filter
                            executable.open()
                        }
                    }
                    GlowButton {
                        text: "自动"
                        enabled: !pane.controller.inspecting && !!pane.paths[modelData.id]
                        onClicked: pane.setPath(modelData.id, "")
                    }
                }
                Label {
                    Layout.fillWidth: true
                    visible: !!check
                    wrapMode: Text.WrapAnywhere
                    text: check ? check.message + (check.path ? "\n" + check.path : "") : ""
                }
            }
        }

        BusyIndicator { Layout.alignment: Qt.AlignHCenter; running: pane.controller.inspecting; visible: running }
        Label { Layout.fillWidth: true; text: pane.message; visible: text.length > 0; wrapMode: Text.Wrap }

        RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            GlowButton { text: "关闭"; enabled: !pane.controller.inspecting; onClicked: pane.close() }
            GlowButton { text: "测试引擎"; enabled: !pane.controller.inspecting; onClicked: pane.controller.checkEngines(pane.paths, false) }
            GlowButton { text: "测试并保存"; highlighted: true; enabled: !pane.controller.inspecting; onClicked: pane.controller.checkEngines(pane.paths, true) }
        }
    }
}
