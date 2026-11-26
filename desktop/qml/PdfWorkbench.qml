import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

Dialog {
    id: pane
    required property var controller
    required property string outputDirectory
    property var pages: []
    property int activeIndex: -1
    property int dropIndex: -1
    property string notice: ""
    property bool loading: false
    property bool compressing: false
    property var compression: null
    readonly property bool working: loading || compressing
    readonly property var sources: [...new Set(pages.map(page => page.path))]
    readonly property bool ready: !working && pages.length > 0 && outputDirectory.trim() !== ""
    signal outputDirectorySelected(string directory)

    title: "PDF 页面工作台"
    anchors.centerIn: Overlay.overlay
    width: Math.min(parent.width - 32, 1040)
    height: Math.min(parent.height - 32, 680)
    modal: true
    closePolicy: working ? Popup.NoAutoClose : Popup.CloseOnEscape
    onPagesChanged: discardCompression()
    onClosed: discardCompression()

    function importPaths(paths) {
        if (controller.inspecting || !paths.length)
            return
        const additions = [...new Set(paths)].filter(path => !sources.includes(path))
        if (!additions.length)
            return
        if (sources.length + additions.length > 32 || pages.length >= 300) {
            notice = "一次最多编辑 32 个文件、300 页"
            return
        }
        notice = ""
        loading = true
        controller.previewPdf(additions, 300 - pages.length)
    }

    function movePage(from, to) {
        if (from < 0 || to < 0 || from >= pages.length || to >= pages.length || from === to)
            return
        const next = pages.slice()
        next.splice(to, 0, next.splice(from, 1)[0])
        pages = next
        activeIndex = to
        grid.positionViewAtIndex(to, GridView.Contain)
    }

    function rotatePage() {
        if (activeIndex < 0)
            return
        const next = pages.slice()
        const page = next[activeIndex]
        next[activeIndex] = Object.assign({}, page, {rotation: (page.rotation + 90) % 360})
        pages = next
    }

    function removePage() {
        if (activeIndex < 0)
            return
        const next = pages.slice()
        next.splice(activeIndex, 1)
        pages = next
        activeIndex = Math.min(activeIndex, next.length - 1)
        if (next.length === 0)
            controller.clearPdfPreview()
    }

    function pageOrder() {
        const order = pages.map(page => ({
            source: sources.indexOf(page.path), page: page.page, rotation: page.rotation
        }))
        return JSON.stringify(order)
    }

    function discardCompression() {
        compression = null
        if (controller)
            controller.clearPdfCompression()
    }

    function previewCompression(limit) {
        if (!ready || controller.inspecting)
            return
        notice = ""
        compressing = true
        controller.previewPdfCompression(sources, pageOrder(), limit, Math.max(activeIndex, 0))
    }

    function saveCompression() {
        if (!compression)
            return
        const error = controller.savePdfCompression(outputDirectory)
        if (error) {
            compressionDialog.error = error
            return
        }
        discardCompression()
        compressionDialog.close()
        close()
    }

    function exportPdf() {
        if (!ready)
            return
        if (limitExport.checked) {
            previewCompression(targetSize.value)
            return
        }
        controller.submit("pdf.compose", sources, {pages: pageOrder()}, outputDirectory)
        close()
    }

    Connections {
        target: pane.controller
        function onPdfPreviewReady(newPages, error) {
            pane.loading = false
            pane.notice = error
            if (!error && newPages.length) {
                const firstNew = pane.pages.length
                pane.pages = pane.pages.concat(newPages)
                pane.activeIndex = firstNew
                grid.positionViewAtIndex(firstNew, GridView.Contain)
            }
        }
        function onPdfCompressionReady(result, error) {
            pane.compressing = false
            pane.notice = error
            if (!error) {
                pane.compression = result
                compressionDialog.error = ""
                compressionDialog.open()
            }
        }
    }

    Dialog {
        id: compressionDialog
        title: "PDF 压缩前后对照"
        property string error: ""
        anchors.centerIn: Overlay.overlay
        width: Math.min(parent.width - 48, 780)
        height: Math.min(parent.height - 48, 600)
        modal: true
        onClosed: pane.discardCompression()

        contentItem: ColumnLayout {
            spacing: 9
            Label {
                Layout.fillWidth: true
                text: pane.compression ? "第 " + (Math.max(pane.activeIndex, 0) + 1) + " 页 · 目标 " +
                     (pane.compression.target / 1024) + " KiB · " +
                     (pane.compression.met ? "已达标" : "未达到目标大小") : ""
                font.bold: true
                wrapMode: Text.Wrap
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 12
                Repeater {
                    model: ["压缩前", "压缩后"]
                    delegate: ColumnLayout {
                        required property int index
                        required property string modelData
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Label {
                            text: modelData + (pane.compression ? " · " +
                                  ((index === 0 ? pane.compression.original : pane.compression.size) / 1024).toFixed(1) +
                                  " KiB" : "")
                        }
                        Image {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.preferredWidth: 350
                            fillMode: Image.PreserveAspectFit
                            cache: false
                            source: pane.compression ? index === 0 ? pane.compression.before : pane.compression.after : ""
                        }
                    }
                }
            }
            Label { Layout.fillWidth: true; visible: text !== ""; text: compressionDialog.error; wrapMode: Text.Wrap }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                Button { text: "返回"; onClicked: compressionDialog.close() }
                Button {
                    highlighted: true
                    text: pane.compression && !pane.compression.met ? "仍然保存 PDF" : "保存 PDF"
                    enabled: !!pane.compression
                    onClicked: pane.saveCompression()
                }
            }
        }
    }

    FileDialog {
        id: insertFiles
        title: "插入 PDF 或图片"
        fileMode: FileDialog.OpenFiles
        nameFilters: ["PDF 和图片 (*.pdf *.png *.jpg *.jpeg *.webp *.bmp *.tif *.tiff *.avif *.ico)"]
        onAccepted: pane.importPaths(selectedFiles.map(url => pane.controller.localPath(url)).filter(path => !!path))
    }

    FolderDialog {
        id: destinationFolder
        title: "选择 PDF 输出目录"
        onAccepted: pane.outputDirectorySelected(pane.controller.localPath(selectedFolder))
    }

    contentItem: ColumnLayout {
        spacing: 9

        RowLayout {
            Button {
                text: "插入 PDF 或图片"
                enabled: !pane.working
                onClicked: insertFiles.open()
            }
            Label { text: pane.pages.length + " 页" }
            Item { Layout.fillWidth: true }
            Button {
                text: "清空"
                enabled: !pane.working && pane.pages.length > 0
                onClicked: {
                    pane.pages = []
                    pane.activeIndex = -1
                    pane.notice = ""
                    pane.controller.clearPdfPreview()
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: 10
            color: pane.palette.base
            border.color: pane.palette.mid
            clip: true

            DropArea {
                anchors.fill: parent
                enabled: !pane.working
                onEntered: function(event) { event.accepted = event.hasUrls }
                onDropped: function(event) {
                    const paths = event.urls.map(url => pane.controller.localPath(url)).filter(path => !!path)
                    if (paths.length) {
                        pane.importPaths(paths)
                        event.acceptProposedAction()
                    }
                }
            }

            Label {
                anchors.centerIn: parent
                visible: pane.pages.length === 0 && !pane.loading
                text: "拖入 PDF 或图片，开始排版"
            }

            GridView {
                id: grid
                anchors.fill: parent
                anchors.margins: 8
                clip: true
                cellWidth: Math.max(120, width / Math.max(1, Math.floor(width / 155)))
                cellHeight: 176
                model: pane.pages
                ScrollBar.vertical: ScrollBar {}
                delegate: Item {
                    id: cell
                    required property var modelData
                    required property int index
                    width: grid.cellWidth
                    height: grid.cellHeight
                    readonly property bool turned: modelData.rotation % 180 !== 0

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 4
                        radius: 8
                        color: pane.palette.window
                        border.width: pane.activeIndex === cell.index || pane.dropIndex === cell.index ? 2 : 1
                        border.color: border.width === 2 ? pane.palette.highlight : pane.palette.mid
                    }

                    Item {
                        id: picture
                        anchors { top: parent.top; topMargin: 9; horizontalCenter: parent.horizontalCenter }
                        width: parent.width - 20
                        height: 124
                        Image {
                            anchors.centerIn: parent
                            width: cell.turned ? picture.height : picture.width
                            height: cell.turned ? picture.width : picture.height
                            source: cell.modelData.thumbnail
                            fillMode: Image.PreserveAspectFit
                            rotation: cell.modelData.rotation
                            asynchronous: true
                            cache: false
                        }
                    }

                    Label {
                        anchors { top: picture.bottom; left: parent.left; right: parent.right; margins: 8 }
                        text: "第 " + (cell.index + 1) + " 页 · " + cell.modelData.name
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideMiddle
                        ToolTip.visible: pointer.containsMouse && pane.dropIndex < 0
                        ToolTip.text: cell.modelData.name + " · 原第 " + (cell.modelData.page + 1) + " 页"
                    }

                    MouseArea {
                        id: pointer
                        anchors.fill: parent
                        enabled: !pane.working
                        hoverEnabled: true
                        preventStealing: true
                        property point start
                        function destination(mouse) {
                            const position = mapToItem(grid.contentItem, mouse.x, mouse.y)
                            return grid.indexAt(position.x, position.y)
                        }
                        onPressed: function(mouse) {
                            start = Qt.point(mouse.x, mouse.y)
                            pane.activeIndex = cell.index
                        }
                        onPositionChanged: function(mouse) {
                            if (pressed && Math.hypot(mouse.x - start.x, mouse.y - start.y) > 8)
                                pane.dropIndex = destination(mouse)
                        }
                        onReleased: function(mouse) {
                            if (Math.hypot(mouse.x - start.x, mouse.y - start.y) > 8)
                                pane.movePage(cell.index, destination(mouse))
                            pane.dropIndex = -1
                        }
                        onCanceled: pane.dropIndex = -1
                    }
                }
            }
        }

        Label {
            Layout.fillWidth: true
            text: pane.compressing ? "正在试压并渲染对照图…" :
                  pane.loading ? "正在生成页面缩略图…" : pane.notice || "拖动缩略图调整顺序"
            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true
            CheckBox { id: limitExport; text: "限制导出大小"; enabled: !pane.working }
            SpinBox {
                id: targetSize
                from: 1; to: 262144; value: 4882; stepSize: 100
                editable: true
                enabled: limitExport.checked && !pane.working
                Accessible.name: "PDF 目标大小（KiB）"
            }
            Label { text: "KiB"; enabled: limitExport.checked }
            Item { Layout.fillWidth: true }
        }

        RowLayout {
            Layout.fillWidth: true
            Label { text: "输出目录" }
            Label { Layout.fillWidth: true; text: pane.outputDirectory; elide: Text.ElideMiddle }
            Button { text: "更改"; onClicked: destinationFolder.open() }
        }

        RowLayout {
            Layout.fillWidth: true
            Button { text: "前移"; enabled: !pane.working && pane.activeIndex > 0; onClicked: pane.movePage(pane.activeIndex, pane.activeIndex - 1) }
            Button { text: "后移"; enabled: !pane.working && pane.activeIndex >= 0 && pane.activeIndex + 1 < pane.pages.length; onClicked: pane.movePage(pane.activeIndex, pane.activeIndex + 1) }
            Button { text: "旋转"; enabled: !pane.working && pane.activeIndex >= 0; onClicked: pane.rotatePage() }
            Button { text: "移除页面"; enabled: !pane.working && pane.activeIndex >= 0; onClicked: pane.removePage() }
            Item { Layout.fillWidth: true }
            Button { text: "关闭"; enabled: !pane.working; onClicked: pane.close() }
            Button { text: limitExport.checked ? "预览压缩" : "导出 PDF"; highlighted: true; enabled: pane.ready; onClicked: pane.exportPdf() }
        }
    }
}
