import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Dialog {
    id: pane
    required property var controller
    property string toolId: ""
    property var paths: []
    property var options: ({})
    property string outputDirectory: ""
    property var rows: []
    property var chosen: []
    property var areas: []
    property var pictures: []
    property var cells: []
    property string textResult: ""
    property string imageUrl: ""
    property string note: ""
    property string fingerprint: ""
    property var selection: [0, 0, 1, 1]
    property int page: 1
    property int pageCount: 1
    property bool ready: false
    readonly property bool isPdf: ["pdf.redact", "pdf.table_xlsx"].includes(toolId)
    readonly property bool isRegion: isPdf || ["image.id_photo", "image.region_ocr"].includes(toolId)
    readonly property bool isTimeline: toolId === "video.timeline"
    readonly property bool isArchive: toolId === "file.archive"
    readonly property bool isSilence: toolId === "audio.silence"
    readonly property bool isScan: toolId === "pdf.clean_scan"

    objectName: "studioPreview"
    anchors.centerIn: Overlay.overlay
    width: Math.min(parent.width - 32, 1060)
    height: Math.min(parent.height - 32, 680)
    modal: true
    closePolicy: controller.inspecting ? Popup.NoAutoClose : Popup.CloseOnEscape
    onClosed: controller.clearStudioPreview()

    function show(spec, inputs, parameters, output) {
        toolId = spec.id
        title = spec.label
        paths = inputs.slice()
        options = Object.assign({}, parameters)
        outputDirectory = output
        rows = []
        chosen = []
        areas = []
        pictures = []
        cells = []
        textResult = ""
        imageUrl = ""
        note = ""
        fingerprint = ""
        selection = [0, 0, 1, 1]
        page = toolId === "pdf.table_xlsx" ? Number(options.page) : 1
        pageCount = Math.max(1, page)
        ready = false
        open()
        request("initial")
    }

    function request(purpose, extra) {
        const params = Object.assign({}, options)
        if (isRegion && toolId !== "pdf.redact")
            params.region = selection.join(",")
        if (toolId === "pdf.table_xlsx")
            params.page = page
        note = ""
        controller.previewStudio(toolId, paths, params,
                                 Object.assign({purpose: purpose, page: page}, extra || {}))
    }

    function setSelected(index, checked) {
        const copy = chosen.slice()
        copy[index] = checked
        chosen = copy
    }

    function updateCut(index, start, end) {
        rows[index].start = start
        rows[index].end = end
        pictures = []
    }

    function moveCut(index, direction) {
        const copy = rows.slice()
        const other = index + direction
        const item = copy.splice(index, 1)[0]
        copy.splice(other, 0, item)
        rows = copy
    }

    function saveResult() {
        const params = Object.assign({}, options)
        if (toolId === "image.id_photo" || toolId === "image.region_ocr" || toolId === "pdf.table_xlsx")
            params.region = selection.join(",")
        if (toolId === "pdf.table_xlsx")
            params.page = page
        if (toolId === "pdf.redact")
            params.regions = JSON.stringify(areas)
        if (isScan)
            params.remove = rows.filter((row, i) => !chosen[i]).map(row => row.page).join(",")
        if (isTimeline)
            params.clips = JSON.stringify(rows.map(row => ({source: row.source, start: row.start, end: row.end})))
        if (isSilence)
            params.selected = JSON.stringify(chosen.map((selected, i) => selected ? i : -1).filter(i => i >= 0))
        if (isArchive && options.operation === "提取")
            params.selected = JSON.stringify(rows.filter((row, i) => chosen[i] && !row.directory).map(row => row.name))
        if (toolId === "folder.batch")
            params.fingerprint = fingerprint
        controller.submit(toolId, paths, params, outputDirectory)
        close()
    }

    Connections {
        target: pane.controller
        function onStudioPreviewReady(result, error) {
            if (!pane.visible) return
            pane.note = error || ""
            if (error) return
            if (result.image) {
                pane.imageUrl = result.image
                pane.selection = [0, 0, 1, 1]
            }
            if (result.pages) {
                pane.pageCount = result.pages
                pane.page = result.page
            }
            if (result.rows !== undefined) {
                pane.rows = Array.from(result.rows, row => Object.assign({}, row))
                pane.chosen = pane.rows.map(row => pane.isScan ? !row.blank : !row.directory)
                if (pane.isScan && !pane.chosen.some(Boolean))
                    pane.chosen = pane.rows.map(() => true)
                if (pane.isSilence && result.total > pane.rows.length)
                    pane.note = "检测到 " + result.total + " 段，界面可选前 " + pane.rows.length + " 段"
            }
            if (result.pictures) pane.pictures = Array.from(result.pictures)
            if (result.cells) pane.cells = Array.from(result.cells)
            if (result.text !== undefined) pane.textResult = result.text
            if (result.fingerprint) pane.fingerprint = result.fingerprint
            if (result.sample) pane.controller.playStudioSample(result.sample)
            if (result.photoSize) pane.note = result.photoSize.join(" × ") + " 像素 · " +
                                             (result.jpegBytes / 1024).toFixed(1) + " KiB"
            pane.ready = true
        }
    }

    contentItem: ColumnLayout {
        spacing: 8
        RowLayout {
            visible: pane.isRegion
            Layout.fillWidth: true
            Label {
                Layout.fillWidth: true
                text: pane.toolId === "pdf.redact" ?
                    "在页面框选后点「添加遮盖」。导出 PDF 会移除原文字层和附件。" :
                    "用鼠标在预览图上拖动选择范围"
                wrapMode: Text.Wrap
            }
            SpinBox {
                visible: pane.isPdf
                from: 1
                to: pane.pageCount
                value: pane.page
                editable: true
                enabled: !pane.controller.inspecting
                onValueModified: {
                    pane.page = value
                    pane.cells = []
                    pane.request("initial")
                }
            }
            GlowButton {
                visible: pane.toolId === "pdf.redact"
                text: "添加遮盖"
                enabled: pane.ready && !pane.controller.inspecting && pane.areas.length < 128 &&
                         pane.selection[2] < 0.999 && pane.selection[3] < 0.999
                onClicked: pane.areas = pane.areas.concat([{page: pane.page, region: pane.selection.slice()}])
            }
            GlowButton {
                visible: pane.toolId === "pdf.redact" && pane.areas.length > 0
                text: "撤回上一处"
                onClicked: pane.areas = pane.areas.slice(0, -1)
            }
            GlowButton {
                visible: pane.toolId !== "pdf.redact"
                text: pane.toolId === "image.region_ocr" ? "识别选区" : "生成预览"
                enabled: pane.ready && !pane.controller.inspecting
                onClicked: pane.request("evaluate")
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: pane.isRegion
            visible: pane.isRegion
            Image {
                id: preview
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 530
                source: pane.imageUrl
                fillMode: Image.PreserveAspectFit
                smooth: true
                Item {
                    id: paper
                    width: preview.paintedWidth
                    height: preview.paintedHeight
                    anchors.centerIn: parent
                    visible: preview.status === Image.Ready
                    Repeater {
                        model: pane.areas.filter(area => area.page === pane.page)
                        delegate: Rectangle {
                            required property var modelData
                            x: paper.width * modelData.region[0]
                            y: paper.height * modelData.region[1]
                            width: paper.width * modelData.region[2]
                            height: paper.height * modelData.region[3]
                            color: "black"
                        }
                    }
                    Rectangle {
                        x: paper.width * pane.selection[0]
                        y: paper.height * pane.selection[1]
                        width: paper.width * pane.selection[2]
                        height: paper.height * pane.selection[3]
                        visible: pane.selection[2] !== 1 || pane.selection[3] !== 1
                        color: "#3339b49d"
                        border.color: "#43bfae"
                        border.width: 2
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.CrossCursor
                        enabled: !pane.controller.inspecting
                        property point origin
                        onPressed: mouse => origin = Qt.point(mouse.x / width, mouse.y / height)
                        onPositionChanged: mouse => {
                            if (!pressed) return
                            const x = Math.max(0, Math.min(1, mouse.x / width))
                            const y = Math.max(0, Math.min(1, mouse.y / height))
                            pane.selection = [Math.min(x, origin.x), Math.min(y, origin.y),
                                              Math.abs(x-origin.x), Math.abs(y-origin.y)]
                            pane.cells = []
                            pane.pictures = []
                            pane.textResult = ""
                        }
                        onReleased: {
                            if (pane.selection[2] < 0.005 || pane.selection[3] < 0.005)
                                pane.selection = [0, 0, 1, 1]
                        }
                    }
                }
            }
            ScrollView {
                visible: pane.pictures.length > 0 || pane.cells.length > 0 || pane.textResult !== ""
                Layout.fillHeight: true
                Layout.preferredWidth: 360
                contentWidth: availableWidth
                ColumnLayout {
                    width: parent.width
                    Repeater {
                        model: pane.pictures
                        delegate: Image {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredHeight: 165
                            fillMode: Image.PreserveAspectFit
                            source: modelData
                        }
                    }
                    TextArea {
                        visible: pane.textResult !== ""
                        Layout.fillWidth: true
                        readOnly: true
                        selectByMouse: true
                        wrapMode: TextEdit.Wrap
                        text: pane.textResult
                    }
                    GlowButton {
                        visible: pane.textResult !== ""
                        text: "复制识别结果"
                        onClicked: { pane.controller.copyText(pane.textResult); pane.note = "文字已复制" }
                    }
                    Label {
                        visible: pane.cells.length > 0
                        text: pane.cells.length + " 行 · " + (pane.cells[0] || []).length + " 列"
                    }
                    Repeater {
                        model: pane.cells.slice(0, 250)
                        delegate: Label {
                            required property var modelData
                            text: Array.from(modelData).join("  │  ")
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap
                            Layout.fillWidth: true
                        }
                    }
                    Label { visible: pane.cells.length > 250; text: "此处预览前 250 行，导出包含全部行" }
                }
            }
        }

        ListView {
            id: results
            visible: !pane.isRegion
            Layout.fillWidth: true
            Layout.fillHeight: !pane.isRegion
            clip: true
            spacing: 5
            model: pane.rows
            delegate: RowLayout {
                required property var modelData
                required property int index
                width: results.width - 12
                spacing: 10
                CheckBox {
                    visible: (pane.isArchive && pane.options.operation === "提取" && !modelData.directory) ||
                             pane.isScan || (pane.isSilence && pane.options.mode !== "检测报告")
                    checked: !!pane.chosen[index]
                    onToggled: pane.setSelected(index, checked)
                }
                Image {
                    visible: pane.isScan
                    Layout.preferredWidth: 60
                    Layout.preferredHeight: 72
                    fillMode: Image.PreserveAspectFit
                    source: modelData.thumbnail || ""
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    Label {
                        Layout.fillWidth: true
                        text: pane.isSilence ? Number(modelData.start).toFixed(2) + "–" + Number(modelData.end).toFixed(2) + " 秒" :
                              (modelData.name || "") + (modelData.blank ? " · 疑似空白页" : "") +
                              (modelData.angle ? " · 纠偏 " + modelData.angle + "°" : "")
                        textFormat: Text.PlainText
                        elide: Text.ElideMiddle
                    }
                    RangeSlider {
                        id: timelineRange
                        visible: pane.isTimeline
                        Layout.fillWidth: true
                        from: 0
                        to: modelData.duration || 1
                        first.value: modelData.start || 0
                        second.value: modelData.end || 1
                        stepSize: .01
                        first.onMoved: pane.updateCut(index, first.value, second.value)
                        second.onMoved: pane.updateCut(index, first.value, second.value)
                    }
                    Label {
                        visible: pane.isTimeline
                        text: timelineRange.first.value.toFixed(2) + "–" + timelineRange.second.value.toFixed(2) + " 秒"
                    }
                }
                GlowButton {
                    visible: pane.isTimeline
                    compact: true
                    enabled: index > 0
                    text: "上移"
                    onClicked: pane.moveCut(index, -1)
                }
                GlowButton {
                    visible: pane.isTimeline
                    compact: true
                    enabled: index + 1 < pane.rows.length
                    text: "下移"
                    onClicked: pane.moveCut(index, 1)
                }
                GlowButton {
                    visible: pane.isTimeline || pane.isSilence
                    enabled: !pane.controller.inspecting
                    text: pane.isSilence ? "试听" : "预览切点"
                    onClicked: pane.isSilence ? pane.request("listen", {index: index}) :
                               pane.request("shot", {index: modelData.source, start: modelData.start, end: modelData.end})
                }
                Label {
                    visible: modelData.bytes !== undefined
                    text: modelData.directory ? "文件夹" : (Number(modelData.bytes) / 1024).toFixed(1) + " KiB"
                }
            }
            ScrollBar.vertical: ScrollBar {}
        }
        RowLayout {
            visible: pane.isTimeline && pane.pictures.length > 0
            Repeater {
                model: pane.isTimeline ? pane.pictures : []
                delegate: ColumnLayout {
                    required property var modelData
                    required property int index
                    Label { text: index === 0 ? "起点附近" : "结束点附近" }
                    Image { Layout.preferredWidth: 260; Layout.preferredHeight: 145; fillMode: Image.PreserveAspectFit; source: modelData }
                }
            }
        }
        Label {
            Layout.fillWidth: true
            text: pane.controller.inspecting ? "正在生成预览…" :
                  pane.note || (pane.toolId === "pdf.redact" ? "已添加 " + pane.areas.length + " 处遮盖" : "")
            wrapMode: Text.Wrap
            visible: text !== ""
        }
    }

    footer: RowLayout {
        Item { Layout.fillWidth: true }
        GlowButton {
            text: "关闭"
            enabled: !pane.controller.inspecting
            Layout.margins: 8
            onClicked: pane.close()
        }
        GlowButton {
            text: pane.toolId === "folder.batch" ? "开始批处理" : "保存结果"
            primary: true
            enabled: pane.ready && !pane.controller.inspecting &&
                     (pane.toolId !== "pdf.redact" || pane.areas.length > 0) &&
                     (pane.toolId !== "pdf.table_xlsx" || pane.cells.length > 0) &&
                     (!pane.isScan || pane.chosen.some(Boolean)) &&
                     (!pane.isArchive || pane.options.operation !== "提取" || pane.chosen.some(Boolean))
            Layout.margins: 8
            onClicked: pane.saveResult()
        }
    }
}
