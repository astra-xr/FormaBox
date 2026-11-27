import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

ApplicationWindow {
    id: root
    width: 1200; height: 800; minimumWidth: 860; minimumHeight: 600
    title: "万象"
    property bool immersiveFrame: windowsFrameSupported
    property string themeMode: "system"
    readonly property bool dark: themeMode === "system" ? backend.systemDark : themeMode === "dark"
    readonly property color panel: dark ? "#23303d" : "#fcfdff"
    readonly property color canvas: dark ? "#17212b" : "#e9eef4"
    readonly property color ink: dark ? "#edf4fc" : "#1b2b3d"
    readonly property color muted: dark ? "#b2c2d4" : "#4d6075"
    readonly property color accent: dark ? "#90d2c1" : "#2c7266"
    readonly property color rim: dark ? "#3a4d60" : "#c8d4e0"
    property string category: "常用"
    property bool workflowExpanded: false
    property bool taskCenterExpanded: false
    readonly property string searchQuery: search.text.trim().toLowerCase()
    readonly property var visibleTools: filterTools(category, searchQuery)
    readonly property var toolSections: [
        {title: "常用"},
        {title: "图片", categories: ["图片"]},
        {title: "PDF", categories: ["PDF"]},
        {title: "视频", categories: ["视频"]},
        {title: "音频", categories: ["音频"]},
        {title: "文档与数据", categories: ["文档"]},
        {title: "文件与隐私", categories: ["文件", "隐私"]},
        {title: "全部工具"}
    ]
    readonly property var featuredTools: [
        "doc.pdf", "pdf.merge", "pdf.split", "pdf.compress_target", "pdf.ocr", "image.compress",
        "image.convert", "image.ocr", "video.convert", "video.frames", "audio.convert", "file.rename"
    ]
    property var selected: null
    property var inputs: Array.from(launchFiles)
    property var params: ({})
    property var steps: []
    property string workflowNotice: ""
    readonly property var workbenchImages: ["png", "jpg", "jpeg", "webp", "bmp", "tif", "tiff", "avif", "ico"]
    readonly property var suggestions: recommendationsFor(inputs)
    readonly property var builtInPresets: [
        {name: "报名照压到 100 KB", tool: "image.compress", suffixes: workbenchImages,
         params: {format: "jpg", target_kib: "97"}, builtIn: true},
        {name: "Word 转 PDF", tool: "doc.pdf", suffixes: ["doc", "docx"], params: {}, builtIn: true},
        {name: "扫描件转可搜索 PDF", tool: "pdf.ocr", suffixes: ["pdf"], params: {language: "chi_sim+eng"}, builtIn: true},
        {name: "图片缩放、压缩并合成 PDF", suffixes: workbenchImages, builtIn: true, steps: [
            {tool: "image.resize", params: {width: "1600", height: "1600"}},
            {tool: "image.compress", params: {format: "jpg", quality: "85"}},
            {tool: "pdf.from_images", params: {}}
        ]}
    ]
    readonly property var presetCatalog: builtInPresets.concat(Array.from(backend.presets))
    readonly property var matchingPresets: presetsFor(inputs)
    readonly property bool canSavePreset: selected !== null && !selected.params.some(p => p.kind === "password")
    readonly property var editableParameters: selected ? selected.params.filter(parameter => {
        if (parameter.kind === "internal")
            return false
        if (selected.id !== "file.rename")
            return true
        if (parameter.key === "mode")
            return true
        const mode = params.mode || "number"
        const isReplacement = ["find", "replacement"].includes(parameter.key)
        return isReplacement ? mode === "replace" : mode === "number"
    }) : []
    readonly property bool selectedReady: selected !== null && !(selected.missing_engines || []).length
    readonly property bool inputCountValid: countFits(selected)
    readonly property bool canAddStep: selected !== null && steps.length < 32
                                       && !selected.params.some(p => p.kind === "password")
    readonly property var workflowTools: steps.map(step => backend.tools.find(tool => tool.id === step.tool))
    readonly property var workflowMissing: workflowTools.reduce((missing, tool) => {
        for (let engine of (tool ? tool.missing_engines || [] : [])) {
            if (!missing.includes(engine))
                missing.push(engine)
        }
        return missing
    }, [])
    readonly property bool workflowReady: workflowTools.length > 0 && workflowTools.every(tool => !!tool)
                                          && workflowMissing.length === 0 && countFits(workflowTools[0])
    color: canvas
    font.pixelSize: 14
    palette.window: canvas
    palette.base: panel
    palette.text: ink
    palette.windowText: ink
    palette.buttonText: ink
    palette.button: panel
    palette.highlight: accent
    palette.placeholderText: muted
    palette.highlightedText: dark ? "#17212b" : "#ffffff"
    background: Rectangle {
        gradient: Gradient {
            GradientStop { position: 0; color: root.dark ? "#202e3b" : "#f3f7fb" }
            GradientStop { position: 1; color: root.canvas }
        }
        Rectangle {
            anchors.fill: parent
            visible: root.immersiveFrame && root.visibility === Window.Windowed
            color: "transparent"
            border.color: root.rim
        }
    }

    component Panel: Rectangle {
        property bool accentBorder: false
        radius: 13
        color: root.panel
        border.color: accentBorder ? root.accent : root.rim
    }

    function filterTools(sectionName, query) {
        const tools = Array.from(backend.tools)
        if (query)
            return tools.filter(tool => (tool.label + " " + tool.id + " " + tool.category).toLowerCase().includes(query))
        if (sectionName === "常用")
            return featuredTools.map(id => tools.find(tool => tool.id === id)).filter(tool => !!tool)
        if (sectionName === "全部工具")
            return tools
        const section = toolSections.find(item => item.title === sectionName)
        return section ? tools.filter(tool => section.categories.includes(tool.category)) : []
    }

    function showCategory(name) {
        category = name
        search.clear()
    }

    function countFits(tool) {
        return !!tool && inputs.length >= tool.minimum && (!tool.maximum || inputs.length <= tool.maximum)
    }

    function addUrls(urls) {
        const paths = inputs.slice()
        let accepted = false
        for (let url of urls) {
            const path = backend.localPath(url)
            if (!path)
                continue
            accepted = true
            if (!paths.includes(path))
                paths.push(path)
        }
        if (paths.length !== inputs.length)
            inputs = paths
        return accepted
    }

    function moveInput(from, to) {
        if (from < 0 || from >= inputs.length || to < 0 || to >= inputs.length)
            return
        const reordered = inputs.slice()
        reordered.splice(to, 0, reordered.splice(from, 1)[0])
        inputs = reordered
    }

    function openRenamePreview() {
        if (backend.inspecting) {
            workflowNotice = "请等待当前预览或检查结束"
            return
        }
        renamePreview.showPreview(inputs, params, output.text)
    }

    function recommendationsFor(paths) {
        if (!paths.length)
            return []
        const suffixes = Array.from(backend.inputSuffixes(paths))
        const office = ["docx", "doc", "xlsx", "xls", "pptx", "ppt", "odt", "ods", "odp", "rtf"]
        const video = ["mp4", "mkv", "webm", "mov", "avi", "m4v"]
        const audio = ["mp3", "wav", "flac", "aac", "ogg", "opus", "m4a"]
        let ids = []
        if (suffixes.every(suffix => office.includes(suffix)))
            ids = ["doc.pdf"]
        else if (suffixes.every(suffix => workbenchImages.includes(suffix)))
            ids = ["image.compress", "pdf.from_images", "image.ocr"]
        else if (suffixes.every(suffix => suffix === "pdf"))
            ids = ["pdf.compose", "pdf.compress_target", "pdf.text", "pdf.number", "pdf.watermark", "pdf.crop"]
        else if (suffixes.every(suffix => suffix === "pdf" || workbenchImages.includes(suffix)))
            ids = ["pdf.compose"]
        else if (suffixes.every(suffix => video.includes(suffix)))
            ids = ["video.convert", "video.compress", "video.frames", "audio.convert"]
        else if (suffixes.every(suffix => suffix === "srt" || suffix === "vtt"))
            ids = ["subtitle.convert", "subtitle.shift", "subtitle.transcript"]
        else if (suffixes.every(suffix => audio.includes(suffix)))
            ids = ["audio.convert", "audio.concat"]
        else if (suffixes.every(suffix => suffix === "zip"))
            ids = ["file.unzip"]
        else if (suffixes.every(suffix => suffix === "txt"))
            ids = ["text.clean", "text.encoding"]

        return ids.map(id => backend.tools.find(tool => tool.id === id)).filter(tool =>
            tool && paths.length >= tool.minimum && (!tool.maximum || paths.length <= tool.maximum))
    }

    function openWorkbench() {
        pdfWorkbench.open()
        const suffixes = backend.inputSuffixes(inputs)
        pdfWorkbench.importPaths(inputs.filter((path, i) => suffixes[i] === "pdf" || workbenchImages.includes(suffixes[i])))
    }

    function showMissingEngines() {
        if (engineSettings.item)
            engineSettings.item.open()
        else
            workflowNotice = "内置引擎不可用，请重新安装万象"
    }

    function useSuggestion(tool) {
        if ((tool.missing_engines || []).length) {
            showMissingEngines()
            return
        }
        if (tool.id !== "pdf.compose") {
            const section = toolSections.find(item => item.categories && item.categories.includes(tool.category))
            showCategory(section ? section.title : "全部工具")
        }
        chooseTool(tool)
    }

    function presetTools(preset) {
        const ids = preset.steps ? Array.from(preset.steps).map(step => step.tool) : [preset.tool]
        return ids.map(id => backend.tools.find(tool => tool.id === id))
    }

    function presetMissing(tools) {
        const missing = []
        for (const tool of tools)
            for (const engine of (tool ? tool.missing_engines || [] : []))
                if (!missing.includes(engine))
                    missing.push(engine)
        return missing
    }

    function presetFits(preset, tools, paths, suffixes) {
        const expected = Array.from(preset.suffixes || [])
        const first = tools[0]
        return !!first && tools.every(tool => !!tool) && paths.length >= first.minimum &&
               (!first.maximum || paths.length <= first.maximum) &&
               (!expected.length || suffixes.every(suffix => expected.includes(suffix)))
    }

    function presetsFor(paths) {
        const suffixes = Array.from(backend.inputSuffixes(paths))
        return presetCatalog.filter(preset => preset.suffixes.length > 0 &&
            presetFits(preset, presetTools(preset), paths, suffixes))
    }

    function runPreset(preset) {
        const tools = presetTools(preset)
        if (!presetFits(preset, tools, inputs, Array.from(backend.inputSuffixes(inputs)))) {
            workflowNotice = "当前输入与预设不匹配"
            return
        }
        if (!output.text.trim()) {
            workflowNotice = "请选择输出目录"
            return
        }
        if (presetMissing(tools).length) {
            presetManager.close()
            showMissingEngines()
            return
        }
        if (preset.steps) {
            backend.submitWorkflow(preset.steps, inputs, output.text)
            presetManager.close()
            return
        }
        const tool = tools[0]
        useSuggestion(tool)
        const values = {}
        for (const parameter of tool.params)
            values[parameter.key] = preset.params[parameter.key] ?? parameter.default
        params = values
        presetManager.close()
        if (tool.id === "file.rename")
            openRenamePreview()
        else
            backend.submit(tool.id, inputs, values, output.text)
    }

    function chooseTool(tool) {
        if (tool.id === "pdf.compose") {
            if ((tool.missing_engines || []).length)
                workflowNotice = "页面工作台需要 " + tool.missing_engines.join("、")
            else
                openWorkbench()
            return
        }
        if (selected && selected.id === tool.id)
            return
        selected = tool
        const defaults = {}
        for (let parameter of tool.params)
            defaults[parameter.key] = parameter.default
        params = defaults
    }

    function setParam(k,v){let p=Object.assign({},params);p[k]=v;params=p}
    function addStep() {
        if (!canAddStep) return
        steps = steps.concat([{tool: selected.id, params: Object.assign({}, params)}])
        workflowExpanded = true
        workflowNotice = "已添加工作流步骤"
    }
    function loadWorkflow(text) {
        try {
            let value = JSON.parse(text)
            if (!Array.isArray(value) || value.length < 1 || value.length > 32)
                throw Error("工作流需要 1–32 个步骤")
            for (let step of value) {
                let tool = step && backend.tools.find(t => t.id === step.tool)
                if (!tool || tool.params.some(p => p.kind === "password"))
                    throw Error("工作流包含未知工具或密码工具")
                if (step.params !== undefined && (step.params === null || typeof step.params !== "object"
                        || Array.isArray(step.params) || Object.keys(step.params).some(k => !tool.params.some(p => p.key === k))))
                    throw Error("工作流包含无效参数")
            }
            steps = value.map(step => ({tool: step.tool, params: step.params || {}}))
            workflowExpanded = true
            workflowNotice = "已载入工作流"
        } catch (error) {
            workflowNotice = String(error)
        }
    }
    Connections {
        target: backend
        function onStatusChanged() { root.workflowNotice = "" }
        function onBusyChanged() { if (backend.busy) root.taskCenterExpanded = true }
        function onToolsChanged() {
            if (root.selected) root.selected = backend.tools.find(t => t.id === root.selected.id) || null
        }
    }
    FileDialog { id: files; fileMode: FileDialog.OpenFiles; onAccepted: root.addUrls(selectedFiles) }
    FolderDialog { id: folder; onAccepted: root.addUrls([selectedFolder]) }
    FolderDialog { id: outputFolder; onAccepted: output.text=backend.localPath(selectedFolder) }
    FileDialog {
        id: openWorkflowFile
        title: "打开工作流"
        nameFilters: ["工作流 JSON (*.json)"]
        onAccepted: {
            let text = backend.readWorkflow(selectedFile)
            if (text.length) {
                workflowText.text = text
                root.loadWorkflow(text)
            }
        }
    }
    FileDialog {
        id: saveWorkflowFile
        title: "保存工作流"
        fileMode: FileDialog.SaveFile
        defaultSuffix: "json"
        nameFilters: ["工作流 JSON (*.json)"]
        onAccepted: {
            if (backend.writeWorkflow(selectedFile, JSON.stringify(root.steps, null, 2)))
                root.workflowNotice = "已保存工作流"
        }
    }
    PdfWorkbench {
        id: pdfWorkbench
        objectName: "pdfWorkbench"
        controller: backend
        outputDirectory: output.text
        onOutputDirectorySelected: function(directory) { output.text = directory }
    }
    Loader {
        id: engineSettings
        active: !backend.hasBundledEngines
        sourceComponent: EngineSettings {
            objectName: "engineSettings"
            parent: root.contentItem
            controller: backend
        }
    }
    RenamePreview { id: renamePreview; objectName: "renamePreview"; controller: backend }
    TaskResults {
        id: taskResults
        objectName: "taskResults"
        controller: backend
        onResultFilesChosen: function(paths) { root.inputs = paths }
    }
    Dialog {
        id: presetManager
        title: "常用预设"
        anchors.centerIn: Overlay.overlay
        width: Math.min(parent.width - 36, 650)
        height: Math.min(parent.height - 36, 465)
        modal: true
        footer: RowLayout {
            Item { Layout.fillWidth: true }
            GlowButton { text: "关闭"; Layout.margins: 8; onClicked: presetManager.close() }
        }
        property string notice: ""
        onOpened: {
            notice = ""
            presetName.clear()
        }

        contentItem: ColumnLayout {
            spacing: 8
            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: root.presetCatalog
                delegate: RowLayout {
                    required property var modelData
                    readonly property var tools: root.presetTools(modelData)
                    width: ListView.view.width
                    Label { text: modelData.name + (modelData.steps ? " · " + modelData.steps.length + " 步" : ""); textFormat: Text.PlainText; Layout.fillWidth: true; elide: Text.ElideRight }
                    GlowButton {
                        text: !root.presetMissing(tools).length ? "运行" :
                              backend.hasBundledEngines ? "引擎不可用" : "配置引擎"
                        enabled: root.presetFits(modelData, tools, root.inputs,
                                                Array.from(backend.inputSuffixes(root.inputs))) && output.text.trim() !== ""
                        onClicked: root.runPreset(modelData)
                    }
                    GlowButton {
                        text: "移除"
                        visible: !modelData.builtIn
                        onClicked: presetManager.notice = backend.removePreset(modelData.name)
                    }
                }
                ScrollBar.vertical: ScrollBar {}
            }
            RowLayout {
                Layout.fillWidth: true
                TextField {
                    id: presetName
                    Layout.fillWidth: true
                    enabled: root.canSavePreset || root.steps.length > 0
                    placeholderText: "预设名称"
                    maximumLength: 40
                }
                GlowButton {
                    text: "保存当前参数"
                    enabled: root.canSavePreset && presetName.text.trim() !== ""
                    onClicked: {
                        const error = backend.savePreset(presetName.text, root.selected.id, root.params, root.inputs)
                        presetManager.notice = error || "已保存预设"
                        if (!error)
                            presetName.clear()
                    }
                }
                GlowButton {
                    text: "保存当前工作流"
                    enabled: root.steps.length > 0 && presetName.text.trim() !== ""
                    onClicked: {
                        const error = backend.saveWorkflowPreset(presetName.text, root.steps, root.inputs)
                        presetManager.notice = error || "已保存工作流预设"
                        if (!error)
                            presetName.clear()
                    }
                }
            }
            Label { Layout.fillWidth: true; text: presetManager.notice; visible: text !== ""; wrapMode: Text.Wrap }
        }
    }

    onClosing: function(close){if(backend.busy || backend.inspecting){close.accepted=false;root.workflowNotice="请先取消或等待当前任务结束再关闭"}}
    header: Item {
        height: root.immersiveFrame ? 58 : 70
        Rectangle {
            anchors.fill: parent
            anchors.margins: root.visibility === Window.Windowed ? 1 : 0
            anchors.bottomMargin: 0
            visible: root.immersiveFrame
            color: root.panel
            Rectangle {
                anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                height: 1
                color: root.rim
            }
        }
        Panel {
            anchors.fill: parent; anchors.margins: 14; anchors.bottomMargin: 0
            visible: !root.immersiveFrame
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: root.immersiveFrame ? 16 : 28
            anchors.rightMargin: root.immersiveFrame ? 12 : 28
            anchors.topMargin: root.immersiveFrame ? 0 : 14
            spacing: 9
            Item {
                objectName: "windowDragArea"
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumWidth: brand.implicitWidth
                enabled: !pdfWorkbench.visible && !presetManager.visible && !renamePreview.visible &&
                         !taskResults.visible && !(engineSettings.item && engineSettings.item.visible)
                RowLayout {
                    id: brand
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8
                    Image {
                        Layout.preferredWidth: root.immersiveFrame ? 32 : 38
                        Layout.preferredHeight: width
                        source: "qrc:/branding/formabox.png"
                        fillMode: Image.PreserveAspectFit
                        mipmap: true
                    }
                    Label { text: root.title; font.pixelSize: 20; font.bold: true; color: root.ink }
                    Label { text: Qt.application.version; color: root.muted; font.pixelSize: 12 }
                }
            }
            ComboBox {
                model: ["跟随系统", "浅色", "深色"]
                currentIndex: ["system", "light", "dark"].indexOf(root.themeMode)
                onActivated: root.themeMode = ["system", "light", "dark"][currentIndex]
                Accessible.name: "界面主题"
            }
            GlowButton { text: "页面工作台"; onClicked: root.openWorkbench() }
            GlowButton {
                objectName: "engineSettingsButton"
                visible: !backend.hasBundledEngines
                text: "引擎设置"
                onClicked: root.showMissingEngines()
            }
            GlowButton { text: "常用预设"; onClicked: presetManager.open() }
            RowLayout {
                visible: root.immersiveFrame
                spacing: 4
                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 23
                    Layout.leftMargin: 2
                    Layout.rightMargin: 3
                    color: root.rim
                }
                GlowButton {
                    objectName: "minimizeWindowButton"
                    text: "−"
                    compact: true
                    Layout.preferredWidth: 36
                    Accessible.name: "最小化窗口"
                    ToolTip.text: Accessible.name
                    ToolTip.visible: hovered
                    onClicked: root.showMinimized()
                }
                GlowButton {
                    objectName: "maximizeWindowButton"
                    text: root.visibility === Window.Maximized ? "❐" : "□"
                    compact: true
                    Layout.preferredWidth: 36
                    Accessible.name: root.visibility === Window.Maximized ? "还原窗口" : "最大化窗口"
                    ToolTip.text: Accessible.name
                    ToolTip.visible: hovered
                    onClicked: {
                        if (root.visibility === Window.Maximized)
                            root.showNormal()
                        else
                            root.showMaximized()
                    }
                }
                GlowButton {
                    objectName: "closeWindowButton"
                    text: "×"
                    compact: true
                    destructive: true
                    Layout.preferredWidth: 36
                    Accessible.name: "关闭窗口"
                    ToolTip.text: Accessible.name
                    ToolTip.visible: hovered
                    onClicked: root.close()
                }
            }
        }
    }
    RowLayout {
        anchors.fill: parent; anchors.margins: 14; spacing: 14
        Panel { Layout.preferredWidth: 138; Layout.fillHeight: true
            ColumnLayout { anchors.fill: parent; anchors.margins: 11; spacing: 5
                Repeater {
                    model: root.toolSections
                    delegate: GlowButton {
                        required property var modelData
                        centered: false
                        text: modelData.title
                        selected: !root.searchQuery && root.category === modelData.title
                        Layout.fillWidth: true
                        onClicked: root.showCategory(modelData.title)
                    }
                }
                Item { Layout.fillHeight: true }
            }
        }
        ColumnLayout { Layout.fillWidth: true; Layout.fillHeight: true; spacing: 10
            Panel { Layout.fillWidth: true; Layout.preferredHeight: 74; accentBorder: drop.containsDrag
                DropArea {
                    id: drop
                    anchors.fill: parent
                    onEntered: function(event) {
                        event.accepted = event.hasUrls && event.urls.some(url => !!backend.localPath(url))
                    }
                    onDropped: function(event) {
                        if (event.hasUrls && root.addUrls(event.urls))
                            event.acceptProposedAction()
                    }
                }
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 8
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 3
                        Label { text: "拖入文件"; font.pixelSize: 18; font.weight: Font.DemiBold; color: root.ink }
                        Label {
                            text: root.inputs.length ? root.inputs.length + " 个输入" : "文件或文件夹"
                            color: root.muted
                            font.pixelSize: 12
                        }
                    }
                    GlowButton { text: "选择文件"; onClicked: files.open() }
                    GlowButton { text: "选择文件夹"; onClicked: folder.open() }
                }
            }
            Flow {
                Layout.fillWidth: true
                visible: root.suggestions.length > 0
                spacing: 6
                Label { text: "推荐操作"; color: root.muted; height: 34; verticalAlignment: Text.AlignVCenter }
                Repeater {
                    model: root.suggestions
                    delegate: GlowButton {
                        required property var modelData
                        compact: true
                        text: !backend.hasBundledEngines && (modelData.missing_engines || []).length ?
                              "配置 · " + modelData.label : modelData.label
                        onClicked: root.useSuggestion(modelData)
                    }
                }
            }
            Flow {
                Layout.fillWidth: true
                visible: root.matchingPresets.length > 0
                spacing: 6
                Label { text: "快捷预设"; color: root.muted; height: 34; verticalAlignment: Text.AlignVCenter }
                Repeater {
                    model: root.matchingPresets.slice(0, 3)
                    delegate: GlowButton {
                        required property var modelData
                        compact: true
                        text: modelData.name
                        onClicked: root.runPreset(modelData)
                    }
                }
                GlowButton {
                    visible: root.matchingPresets.length > 3
                    compact: true
                    text: "更多"
                    onClicked: presetManager.open()
                }
            }
            RowLayout {
                Layout.fillWidth: true
                TextField {
                    id: search
                    objectName: "toolSearch"
                    Layout.fillWidth: true
                    placeholderText: "搜索全部工具（名称或 ID）"
                    Accessible.name: "搜索全部工具"
                    Keys.onEscapePressed: clear()
                }
                GlowButton {
                    visible: search.text.length > 0
                    compact: true
                    text: "×"
                    Accessible.name: "清除搜索"
                    onClicked: { search.clear(); search.forceActiveFocus() }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Label {
                    text: root.searchQuery ? "搜索结果" : root.category
                    color: root.ink
                    font.pixelSize: 17
                    font.weight: Font.DemiBold
                }
                Item { Layout.fillWidth: true }
                Label { text: toolsView.count + " 个工具"; color: root.muted; font.pixelSize: 12 }
            }
            Panel { Layout.fillWidth: true; Layout.fillHeight: true
                GridView {
                    id: toolsView
                    anchors.fill: parent; anchors.margins: 8; clip: true
                    cellWidth: width / Math.max(1, Math.floor(width / 151))
                    cellHeight: 65
                    model: root.visibleTools
                    onModelChanged: positionViewAtBeginning()
                    delegate: Item {
                        required property var modelData
                        width: toolsView.cellWidth; height: toolsView.cellHeight
                        GlowButton {
                            anchors.fill: parent; anchors.margins: 4
                            objectName: "toolCard-" + modelData.id
                            text: modelData.label
                            caption: (modelData.missing_engines || []).length
                                     ? "需要 " + modelData.missing_engines.join("、")
                                     : modelData.category
                            centered: false
                            selected: root.selected !== null && root.selected.id === modelData.id
                            onClicked: root.chooseTool(modelData)
                            ToolTip.visible: hovered && ToolTip.text.length > 0
                            ToolTip.text: modelData.description
                        }
                    }
                    ScrollBar.vertical: ScrollBar {}
                }
                Label {
                    anchors.centerIn: parent
                    visible: backend.tools.length > 0 && toolsView.count === 0
                    text: "没有匹配的工具"
                    color: root.muted
                }
            }
            Panel { Layout.fillWidth: true; Layout.preferredHeight: root.taskCenterExpanded ? 148 : 47
                ColumnLayout { anchors.fill: parent; anchors.margins: 8
                    RowLayout {
                        Label {
                            text: backend.jobs.length ? "任务中心 · " + backend.jobs.length : "任务中心"
                            font.weight: Font.DemiBold
                            color: root.ink
                        }
                        Item { Layout.fillWidth: true }
                        GlowButton {
                            visible: root.taskCenterExpanded && backend.jobs.length > 0
                            compact: true
                            text: "清除历史"
                            enabled: !backend.busy
                            onClicked: backend.clearHistory()
                        }
                        GlowButton {
                            compact: true
                            text: root.taskCenterExpanded ? "收起" : "展开"
                            Accessible.name: (root.taskCenterExpanded ? "收起" : "展开") + "任务中心"
                            onClicked: root.taskCenterExpanded = !root.taskCenterExpanded
                        }
                    }
                    Label {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        visible: root.taskCenterExpanded && !backend.jobs.length
                        text: "暂无任务"
                        color: root.muted
                    }
                    ListView { visible: root.taskCenterExpanded && backend.jobs.length > 0
                        Layout.fillWidth: true; Layout.fillHeight: true; clip: true; model: backend.jobs; spacing: 4
                        delegate: RowLayout { required property var modelData; required property int index; width: ListView.view.width
                            ColumnLayout { Layout.fillWidth: true; Label { text: modelData.title+" · "+modelData.state; color: root.ink; Layout.fillWidth: true; elide: Text.ElideRight } Label { text: modelData.message; color: root.muted; Layout.fillWidth: true; elide: Text.ElideRight; font.pixelSize: 11 } }
                            ProgressBar {
                                value: Math.max(0, modelData.progress)
                                indeterminate: modelData.state === "运行中" && modelData.progress < 0
                                visible: modelData.state === "运行中" || modelData.state === "完成"
                                Layout.preferredWidth: 75
                            }
                            GlowButton { text: "重试"; visible: modelData.canRetry === true; onClicked: backend.retry(index) }
                            GlowButton { text: modelData.directory?"查看结果":"取消"; visible: !!modelData.directory||modelData.state==="运行中"||modelData.state==="等待"; onClicked: modelData.directory?taskResults.showJob(index, modelData.directory):backend.cancel(index) }
                        }
                        ScrollBar.vertical: ScrollBar {}
                    }
                }
            }
            Label { text: root.workflowNotice || backend.status; color: root.muted; Layout.fillWidth: true; elide: Text.ElideRight }
        }
        Panel { Layout.preferredWidth: 310; Layout.fillHeight: true
            ScrollView { id: details; anchors.fill: parent; anchors.margins: 12; contentWidth: availableWidth; clip: true
                ColumnLayout { width: details.availableWidth; spacing: 9
                    Label { text: root.selected?root.selected.label:"选择一个工具"; color: root.ink; font.pixelSize: 19; font.bold: true; wrapMode: Text.Wrap; Layout.fillWidth: true }
                    Label { text: root.selected ? root.selected.description : ""; color: root.muted; wrapMode: Text.Wrap; Layout.fillWidth: true; visible: text.length > 0 }
                    Label {
                        visible: root.selected !== null && !root.selectedReady
                        text: !visible ? "" : backend.hasBundledEngines ?
                              "内置引擎不可用，请重新安装万象" :
                              "需要安装 " + (root.selected.missing_engines || []).join("、")
                        color: root.muted; wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                    RowLayout { Label { text: "输入文件 ("+root.inputs.length+")"; color: root.ink; font.bold: true } Item { Layout.fillWidth: true } GlowButton { text: "清空"; onClicked: root.inputs=[] } }
                    ListView { Layout.fillWidth: true; Layout.preferredHeight: Math.min(100,root.inputs.length*30); clip: true; model: root.inputs
                        delegate: RowLayout {
                            required property string modelData
                            required property int index
                            width: ListView.view.width
                            readonly property bool manualOrder: root.selected !== null && root.selected.id === "file.rename"
                            Label { text: modelData; textFormat: Text.PlainText; Layout.fillWidth: true; color: root.muted; elide: Text.ElideMiddle; ToolTip.visible: h.hovered; ToolTip.text: modelData; HoverHandler{id:h} }
                            GlowButton { compact: true; text: "↑"; Accessible.name: "上移文件"; visible: manualOrder; enabled: index > 0; onClicked: root.moveInput(index, index - 1) }
                            GlowButton { compact: true; text: "↓"; Accessible.name: "下移文件"; visible: manualOrder; enabled: index + 1 < root.inputs.length; onClicked: root.moveInput(index, index + 1) }
                            GlowButton { compact: true; text:"×"; Accessible.name: "移除输入文件"; onClicked:{let a=root.inputs.slice();a.splice(index,1);root.inputs=a} }
                        }
                    }
                    Repeater { model: root.editableParameters; delegate: ColumnLayout { required property var modelData; Layout.fillWidth: true
                        Label { text: modelData.label; color: root.ink; Layout.fillWidth: true; wrapMode: Text.Wrap }
                        Loader { Layout.fillWidth: true; sourceComponent: modelData.kind==="choice"?combo:modelData.kind==="bool"?check:field
                            Component { id: combo; ComboBox {
                                readonly property var values: modelData.choices
                                model: modelData.key === "mode" && root.selected.id === "file.rename" ?
                                       ["编号", "替换文字", "按拍摄日期"] : values
                                currentIndex: Math.max(0, values.indexOf(root.params[modelData.key]))
                                onActivated: root.setParam(modelData.key, values[currentIndex])
                            } }
                            Component { id: check; CheckBox { checked: String(root.params[modelData.key])==="true"; onToggled: root.setParam(modelData.key,checked?"true":"false") } }
                            Component { id: field; TextField { text: String(root.params[modelData.key]??""); echoMode: modelData.kind==="password"?TextInput.Password:TextInput.Normal; onTextEdited: root.setParam(modelData.key,text) } }
                        }
                    }}
                    Label { text: "输出目录"; color: root.ink; font.bold: true }
                    RowLayout { Layout.fillWidth: true; TextField { id: output; objectName: "outputDirectory"; text: backend.outputDefault; Layout.fillWidth: true } GlowButton { compact: true; text:"…"; Accessible.name: "选择输出目录"; onClicked: outputFolder.open() } }
                    GlowButton {
                        text: root.selected && root.selected.id === "file.rename" ? "预览重命名" : "加入任务队列"
                        primary: true; centered: true; Layout.fillWidth: true
                        enabled: root.selectedReady && root.inputCountValid && output.text.trim().length > 0
                        onClicked: {
                            root.workflowNotice = ""
                            if (root.selected.id === "file.rename") {
                                root.openRenamePreview()
                                return
                            }
                            backend.submit(root.selected.id, root.inputs, root.params, output.text)
                            for (const parameter of root.selected.params)
                                if (parameter.kind === "password")
                                    root.setParam(parameter.key, "")
                        }
                    }
                    GlowButton { text: "添加到工作流"; Layout.fillWidth: true; enabled: root.canAddStep; onClicked: root.addStep()
                        ToolTip.visible: hovered && root.selected !== null && !root.canAddStep && root.steps.length < 32
                        ToolTip.text: "密码工具无法保存到工作流"
                    }
                    GlowButton {
                        objectName: "workflowToggle"
                        Layout.fillWidth: true
                        centered: false
                        compact: true
                        text: "工作流" + (root.steps.length ? " · " + root.steps.length + " 步" : "")
                              + (root.workflowExpanded ? "  ▾" : "  ▸")
                        onClicked: root.workflowExpanded = !root.workflowExpanded
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: root.workflowExpanded
                        spacing: 6
                        Repeater { model: root.steps; delegate: RowLayout { required property var modelData; required property int index; Layout.fillWidth: true; Label { text: (index+1)+". "+modelData.tool; color: root.muted; Layout.fillWidth: true; elide: Text.ElideRight } GlowButton { compact: true; text:"×"; Accessible.name: "移除工作流步骤"; onClicked:{let a=root.steps.slice();a.splice(index,1);root.steps=a} } } }
                        Label {
                            visible: root.workflowMissing.length > 0
                            text: "工作流需要 " + root.workflowMissing.join("、")
                            color: root.muted; wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                        Label {
                            visible: root.steps.length > 0 && root.inputs.length > 0
                                     && !!root.workflowTools[0] && !root.countFits(root.workflowTools[0])
                            text: "当前输入数量不符合工作流第一步的要求"
                            color: root.muted; wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                        GlowButton { text:"执行工作流"; Layout.fillWidth: true; enabled: root.workflowReady && output.text.trim().length > 0; onClicked: backend.submitWorkflow(root.steps,root.inputs,output.text) }
                        TextArea { id:workflowText; Layout.fillWidth:true; Layout.preferredHeight:75; placeholderText:"工作流 JSON（可复制保存）"; wrapMode:TextEdit.Wrap }
                        RowLayout { GlowButton { text:"查看 JSON"; enabled: root.steps.length > 0; onClicked:workflowText.text=JSON.stringify(root.steps,null,2) } GlowButton { text:"载入文本"; enabled: workflowText.text.trim().length > 0; onClicked:root.loadWorkflow(workflowText.text) } }
                        RowLayout { GlowButton { text:"保存文件"; enabled: root.steps.length > 0; onClicked:saveWorkflowFile.open() } GlowButton { text:"打开文件"; onClicked:openWorkflowFile.open() } }
                    }
                    Label { text:"任务输出在独立目录；原始文件不会被覆盖。"; wrapMode:Text.Wrap; color:root.muted; Layout.fillWidth:true }
                }
            }
        }
    }
}
