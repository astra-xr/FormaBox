import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Shapes

ApplicationWindow {
    id: root
    width: 1200; height: 800; minimumWidth: 860; minimumHeight: 600
    visible: true; title: "万象"
    property string themeMode: "system"
    readonly property bool dark: themeMode === "system" ? backend.systemDark : themeMode === "dark"
    readonly property color panel: dark ? "#243149" : "#f7faff"
    readonly property color canvas: dark ? "#111a2b" : "#edf1fb"
    readonly property color ink: dark ? "#f0f5ff" : "#1b2943"
    readonly property color muted: dark ? "#b0bdd4" : "#505f79"
    readonly property color accent: dark ? "#aac1ff" : "#4759bb"
    readonly property color rim: dark ? "#5d8da6d5" : "#66859ccb"
    readonly property color buttonTop: dark ? "#dd586e91" : "#f8fbffff"
    readonly property color buttonMiddle: dark ? "#d536486a" : "#e6edf4ff"
    readonly property color buttonBottom: dark ? "#d522304a" : "#c8c9d8f9"
    readonly property color buttonLitTop: dark ? "#627eb0" : "#ffffff"
    readonly property color buttonLitMiddle: dark ? "#465e88" : "#e8f3ff"
    readonly property color buttonLitBottom: dark ? "#2d4268" : "#c2d3fa"
    property string category: "全部"
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
    property var categories: ["全部","图片","PDF","视频","音频","文档","文件","隐私"]
    color: canvas
    palette.window: canvas; palette.base: panel; palette.text: ink; palette.windowText: ink; palette.buttonText: ink; palette.button: panel; palette.highlight: accent
    palette.placeholderText: muted; palette.highlightedText: dark ? "#17233a" : "#ffffff"
    background: Rectangle {
        color: root.canvas
        Halo {
            anchors.fill: parent
            xRatio: 0.15; yRatio: 0.05
            tint: root.dark ? "#52648ff4" : "#70a4c3ff"
        }
        Halo {
            anchors.fill: parent
            xRatio: 0.92; yRatio: 0.72
            tint: root.dark ? "#41565ad0" : "#65c5b3f5"
        }
    }

    component Halo: Shape {
        id: glow
        property real xRatio: 0.5
        property real yRatio: 0.5
        property color tint: "transparent"
        ShapePath {
            strokeWidth: -1
            startX: 0; startY: 0
            fillGradient: RadialGradient {
                centerX: glow.width * glow.xRatio
                centerY: glow.height * glow.yRatio
                centerRadius: Math.max(glow.width, glow.height) * 0.7
                focalX: centerX; focalY: centerY
                GradientStop { position: 0; color: glow.tint }
                GradientStop { position: 1; color: Qt.rgba(glow.tint.r, glow.tint.g, glow.tint.b, 0) }
            }
            PathLine { x: glow.width; y: 0 }
            PathLine { x: glow.width; y: glow.height }
            PathLine { x: 0; y: glow.height }
            PathLine { x: 0; y: 0 }
        }
    }

    component GlassSurface: Rectangle {
        property bool accentBorder: false
        radius: 16
        border.color: accentBorder ? root.accent : root.rim
        gradient: Gradient {
            GradientStop { position: 0; color: root.dark ? "#d82a3852" : "#eaffffff" }
            GradientStop { position: 1; color: root.dark ? "#d7182336" : "#b8eff4ff" }
        }
        Rectangle {
            height: 1
            anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 18; rightMargin: 18; topMargin: 1 }
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: "transparent" }
                GradientStop { position: 0.42; color: root.dark ? "#55b9d1ff" : "#ffffff" }
                GradientStop { position: 1; color: "transparent" }
            }
        }
    }

    component GlassButton: Button {
        id: control
        property bool selected: false
        property bool primary: false
        property bool centered: true
        property bool compact: false
        readonly property bool lit: enabled && (selected || hovered || visualFocus)
        readonly property bool filled: enabled && primary
        implicitWidth: Math.max(compact ? 30 : 56, implicitContentWidth + leftPadding + rightPadding)
        implicitHeight: Math.max(compact ? 28 : 37, implicitContentHeight + topPadding + bottomPadding)
        horizontalPadding: compact ? 7 : 10
        verticalPadding: compact ? 2 : 5
        hoverEnabled: true
        font.weight: selected || primary ? Font.DemiBold : Font.Normal
        HoverHandler {
            id: pointer
            enabled: control.enabled
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onPointChanged: {
                if (hovered)
                    reflection.position = point.position
            }
            onHoveredChanged: {
                if (hovered)
                    reflection.position = point.position
            }
        }
        contentItem: Label {
            text: control.text
            font: control.font
            color: control.filled ? "#ffffff" : root.ink
            opacity: control.enabled ? 1 : 0.58
            wrapMode: Text.Wrap
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: control.centered ? Text.AlignHCenter : Text.AlignLeft
        }
        background: Item {
            Rectangle {
                anchors.fill: parent
                anchors.margins: -2
                radius: 12
                color: "transparent"
                border.width: 2
                border.color: root.dark ? "#5685b7ff" : "#45667cff"
                opacity: control.lit ? (control.down ? 0.5 : 1) : 0
                Behavior on opacity { NumberAnimation { duration: 140 } }
            }
            Rectangle {
                anchors.fill: parent
                radius: 10
                border.color: control.visualFocus ? root.accent
                              : control.filled ? "#8b9cff"
                              : control.lit ? root.accent : root.rim
                gradient: Gradient {
                    GradientStop {
                        position: 0
                        color: control.filled ? (control.down ? "#4858c2" : "#7c93f2")
                              : control.lit ? root.buttonLitTop : root.buttonTop
                    }
                    GradientStop {
                        position: 0.46
                        color: control.filled ? (control.down ? "#3544ac" : "#4a5fd9")
                              : control.lit ? root.buttonLitMiddle : root.buttonMiddle
                    }
                    GradientStop {
                        position: 1
                        color: control.filled ? "#313ea7"
                              : control.lit ? root.buttonLitBottom : root.buttonBottom
                    }
                }
            }
            Item {
                id: reflection
                objectName: "buttonReflection"
                property point position: Qt.point(0, 0)
                anchors.fill: parent
                anchors.margins: 3
                clip: true
                visible: opacity > 0
                opacity: pointer.hovered ? (control.down ? 0.55 : 1) : 0
                Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutQuad } }
                Image {
                    readonly property real radius: Math.max(24, Math.min(reflection.width * 0.6, reflection.height * 1.7))
                    width: radius * 2
                    height: width
                    x: reflection.position.x - 3 - radius
                    y: reflection.position.y - 3 - radius
                    source: "qrc:/branding/button-light.png"
                    smooth: true
                }
            }
            Rectangle {
                anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 9; rightMargin: 9; topMargin: 2 }
                height: 2
                radius: 1
                opacity: control.enabled ? (control.down ? 0.48 : 1) : 0.35
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: "transparent" }
                    GradientStop { position: 0.31; color: control.filled || root.dark ? "#d3f1ffff" : "#ffffff" }
                    GradientStop { position: 0.69; color: control.lit ? "#e4c2efff" : "#8acfddff" }
                    GradientStop { position: 1; color: "transparent" }
                }
            }
        }
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
            ids = ["pdf.compose", "pdf.compress_target", "pdf.text"]
        else if (suffixes.every(suffix => suffix === "pdf" || workbenchImages.includes(suffix)))
            ids = ["pdf.compose"]
        else if (suffixes.every(suffix => video.includes(suffix)))
            ids = ["video.convert", "video.compress", "audio.convert"]
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

    function useSuggestion(tool) {
        if ((tool.missing_engines || []).length) {
            engineSettings.open()
            return
        }
        if (tool.id !== "pdf.compose") {
            category = tool.category
            search.text = ""
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
            engineSettings.open()
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
            workflowNotice = "已载入工作流"
        } catch (error) {
            workflowNotice = String(error)
        }
    }
    Connections {
        target: backend
        function onStatusChanged() { root.workflowNotice = "" }
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
    EngineSettings { id: engineSettings; objectName: "engineSettings"; controller: backend }
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
        standardButtons: Dialog.Close
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
                    Button {
                        text: root.presetMissing(tools).length ? "配置引擎" : "运行"
                        enabled: root.presetFits(modelData, tools, root.inputs,
                                                Array.from(backend.inputSuffixes(root.inputs))) && output.text.trim() !== ""
                        onClicked: root.runPreset(modelData)
                    }
                    Button {
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
                Button {
                    text: "保存当前参数"
                    enabled: root.canSavePreset && presetName.text.trim() !== ""
                    onClicked: {
                        const error = backend.savePreset(presetName.text, root.selected.id, root.params, root.inputs)
                        presetManager.notice = error || "已保存预设"
                        if (!error)
                            presetName.clear()
                    }
                }
                Button {
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
        height: 75
        GlassSurface { anchors.fill: parent; anchors.margins: 14; anchors.bottomMargin: 0 }
        RowLayout { anchors.fill: parent; anchors.leftMargin: 28; anchors.rightMargin: 28; anchors.topMargin: 14; spacing: 12
            Image {
                Layout.preferredWidth: 42; Layout.preferredHeight: 42
                source: "qrc:/branding/formabox.png"
                fillMode: Image.PreserveAspectFit
                mipmap: true
            }
            Label { text: "万象"; font.pixelSize: 22; font.bold: true; color: root.ink }
            Label { text: Qt.application.version; color: root.muted; font.pixelSize: 12 }
            Item { Layout.fillWidth: true }
            ComboBox {
                model: ["跟随系统", "浅色", "深色"]
                currentIndex: ["system", "light", "dark"].indexOf(root.themeMode)
                onActivated: root.themeMode = ["system", "light", "dark"][currentIndex]
                Accessible.name: "界面主题"
            }
            GlassButton { text: "页面工作台"; onClicked: root.openWorkbench() }
            GlassButton { text: "引擎设置"; onClicked: engineSettings.open() }
            GlassButton { text: "常用预设"; onClicked: presetManager.open() }
        }
    }
    RowLayout {
        anchors.fill: parent; anchors.margins: 14; spacing: 14
        GlassSurface { Layout.preferredWidth: 132; Layout.fillHeight: true
            ColumnLayout { anchors.fill: parent; anchors.margins: 11; spacing: 5
                Label { text: "分类"; font.bold: true; color: root.muted; Layout.margins: 6 }
                Repeater {
                    model: root.categories
                    delegate: GlassButton {
                        required property string modelData
                        centered: false
                        text: modelData
                        selected: root.category === modelData
                        Layout.fillWidth: true
                        onClicked: root.category = modelData
                    }
                }
                Item { Layout.fillHeight: true }
            }
        }
        ColumnLayout { Layout.fillWidth: true; Layout.fillHeight: true; spacing: 10
            GlassSurface { Layout.fillWidth: true; Layout.preferredHeight: 122; accentBorder: drop.containsDrag
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
                ColumnLayout { anchors.centerIn: parent; spacing: 8
                    Label { text: "将文件拖入这里"; font.pixelSize: 23; font.bold: true; color: root.ink; Layout.alignment: Qt.AlignHCenter }
                    RowLayout { Layout.alignment: Qt.AlignHCenter; GlassButton { text: "选择文件"; onClicked: files.open() } GlassButton { text: "选择文件夹"; onClicked: folder.open() } Label { text: root.inputs.length+" 个输入"; color: root.muted } }
                }
            }
            Flow {
                Layout.fillWidth: true
                visible: root.suggestions.length > 0
                spacing: 6
                Label { text: "推荐操作"; color: root.muted; height: 34; verticalAlignment: Text.AlignVCenter }
                Repeater {
                    model: root.suggestions
                    delegate: GlassButton {
                        required property var modelData
                        compact: true
                        text: (modelData.missing_engines || []).length ? "配置 · " + modelData.label : modelData.label
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
                    delegate: GlassButton {
                        required property var modelData
                        compact: true
                        text: modelData.name
                        onClicked: root.runPreset(modelData)
                    }
                }
                GlassButton {
                    visible: root.matchingPresets.length > 3
                    compact: true
                    text: "更多"
                    onClicked: presetManager.open()
                }
            }
            RowLayout {
                Layout.fillWidth: true
                TextField { id: search; Layout.fillWidth: true; placeholderText: "搜索工具名称 / ID" }
                Label {
                    text: toolsView.count === backend.tools.length ? toolsView.count + " 个工具"
                                                                  : toolsView.count + " / " + backend.tools.length + " 个工具"
                    color: root.muted
                }
            }
            GlassSurface { Layout.fillWidth: true; Layout.fillHeight: true
                GridView {
                    id: toolsView
                    anchors.fill: parent; anchors.margins: 10; clip: true
                    cellWidth: Math.max(145, width / Math.max(1, Math.floor(width / 165)))
                    cellHeight: 72
                    model: backend.tools.filter(tool => (root.category === "全部" || tool.category === root.category)
                                                       && (tool.label + " " + tool.id).toLowerCase().includes(search.text.trim().toLowerCase()))
                    delegate: Item {
                        required property var modelData
                        width: toolsView.cellWidth; height: toolsView.cellHeight
                        GlassButton {
                            anchors.fill: parent; anchors.margins: 4
                            text: modelData.label
                            centered: true
                            selected: root.selected !== null && root.selected.id === modelData.id
                            onClicked: root.chooseTool(modelData)
                            Accessible.description: ToolTip.text
                            ToolTip.visible: hovered && ToolTip.text.length > 0
                            ToolTip.text: (modelData.missing_engines || []).length ? "需要 " + modelData.missing_engines.join("、") : ""
                            Rectangle {
                                visible: (modelData.missing_engines || []).length > 0
                                width: 6; height: 6; radius: 3
                                anchors { top: parent.top; right: parent.right; margins: 8 }
                                color: root.dark ? "#f5c692" : "#93521b"
                            }
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
            GlassSurface { Layout.fillWidth: true; Layout.preferredHeight: 174
                ColumnLayout { anchors.fill: parent; anchors.margins: 10
                    RowLayout { Label { text: "任务中心"; font.bold: true; color: root.ink } Item { Layout.fillWidth: true } GlassButton { text: "清除历史"; enabled: !backend.busy; onClicked: backend.clearHistory() } }
                    ListView { Layout.fillWidth: true; Layout.fillHeight: true; clip: true; model: backend.jobs; spacing: 4
                        delegate: RowLayout { required property var modelData; required property int index; width: ListView.view.width
                            ColumnLayout { Layout.fillWidth: true; Label { text: modelData.title+" · "+modelData.state; color: root.ink; Layout.fillWidth: true; elide: Text.ElideRight } Label { text: modelData.message; color: root.muted; Layout.fillWidth: true; elide: Text.ElideRight; font.pixelSize: 11 } }
                            ProgressBar {
                                value: Math.max(0, modelData.progress)
                                indeterminate: modelData.state === "运行中" && modelData.progress < 0
                                visible: modelData.state === "运行中" || modelData.state === "完成"
                                Layout.preferredWidth: 75
                            }
                            GlassButton { text: "重试"; visible: modelData.canRetry === true; onClicked: backend.retry(index) }
                            GlassButton { text: modelData.directory?"查看结果":"取消"; visible: !!modelData.directory||modelData.state==="运行中"||modelData.state==="等待"; onClicked: modelData.directory?taskResults.showJob(index, modelData.directory):backend.cancel(index) }
                        }
                        ScrollBar.vertical: ScrollBar {}
                    }
                }
            }
            Label { text: root.workflowNotice || backend.status; color: root.muted; Layout.fillWidth: true; elide: Text.ElideRight }
        }
        GlassSurface { Layout.preferredWidth: 310; Layout.fillHeight: true
            ScrollView { id: details; anchors.fill: parent; anchors.margins: 12; contentWidth: availableWidth; clip: true
                ColumnLayout { width: details.availableWidth; spacing: 9
                    Label { text: root.selected?root.selected.label:"选择一个工具"; color: root.ink; font.pixelSize: 19; font.bold: true; wrapMode: Text.Wrap; Layout.fillWidth: true }
                    Label { text: root.selected ? root.selected.description : "从工具列表选择一个工具"; color: root.muted; wrapMode: Text.Wrap; Layout.fillWidth: true; visible: text.length>0 }
                    Label {
                        visible: root.selected !== null && !root.selectedReady
                        text: visible ? "需要安装 " + (root.selected.missing_engines || []).join("、") : ""
                        color: root.muted; wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                    RowLayout { Label { text: "输入文件 ("+root.inputs.length+")"; color: root.ink; font.bold: true } Item { Layout.fillWidth: true } GlassButton { text: "清空"; onClicked: root.inputs=[] } }
                    ListView { Layout.fillWidth: true; Layout.preferredHeight: Math.min(100,root.inputs.length*30); clip: true; model: root.inputs
                        delegate: RowLayout {
                            required property string modelData
                            required property int index
                            width: ListView.view.width
                            readonly property bool manualOrder: root.selected !== null && root.selected.id === "file.rename"
                            Label { text: modelData; textFormat: Text.PlainText; Layout.fillWidth: true; color: root.muted; elide: Text.ElideMiddle; ToolTip.visible: h.hovered; ToolTip.text: modelData; HoverHandler{id:h} }
                            GlassButton { compact: true; text: "↑"; Accessible.name: "上移文件"; visible: manualOrder; enabled: index > 0; onClicked: root.moveInput(index, index - 1) }
                            GlassButton { compact: true; text: "↓"; Accessible.name: "下移文件"; visible: manualOrder; enabled: index + 1 < root.inputs.length; onClicked: root.moveInput(index, index + 1) }
                            GlassButton { compact: true; text:"×"; onClicked:{let a=root.inputs.slice();a.splice(index,1);root.inputs=a} }
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
                    RowLayout { Layout.fillWidth: true; TextField { id: output; objectName: "outputDirectory"; text: backend.outputDefault; Layout.fillWidth: true } GlassButton { compact: true; text:"…"; onClicked: outputFolder.open() } }
                    GlassButton {
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
                    GlassButton { text: "添加到工作流"; Layout.fillWidth: true; enabled: root.canAddStep; onClicked: root.addStep()
                        ToolTip.visible: hovered && root.selected !== null && !root.canAddStep && root.steps.length < 32
                        ToolTip.text: "密码工具无法保存到工作流"
                    }
                    Label { text: "自动化工作流 · "+root.steps.length+" 步"; font.bold: true; color: root.ink }
                    Repeater { model: root.steps; delegate: RowLayout { required property var modelData; required property int index; Layout.fillWidth: true; Label { text: (index+1)+". "+modelData.tool; color: root.muted; Layout.fillWidth: true; elide: Text.ElideRight } GlassButton { compact: true; text:"×"; onClicked:{let a=root.steps.slice();a.splice(index,1);root.steps=a} } } }
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
                    GlassButton { text:"执行工作流"; Layout.fillWidth: true; enabled: root.workflowReady && output.text.trim().length > 0; onClicked: backend.submitWorkflow(root.steps,root.inputs,output.text) }
                    TextArea { id:workflowText; Layout.fillWidth:true; Layout.preferredHeight:75; placeholderText:"工作流 JSON（可复制保存）"; wrapMode:TextEdit.Wrap }
                    RowLayout { GlassButton { text:"查看 JSON"; enabled: root.steps.length > 0; onClicked:workflowText.text=JSON.stringify(root.steps,null,2) } GlassButton { text:"载入文本"; enabled: workflowText.text.trim().length > 0; onClicked:root.loadWorkflow(workflowText.text) } }
                    RowLayout { GlassButton { text:"保存文件"; enabled: root.steps.length > 0; onClicked:saveWorkflowFile.open() } GlassButton { text:"打开文件"; onClicked:openWorkflowFile.open() } }
                    Label { text:"任务输出在独立目录；原始文件不会被覆盖。"; wrapMode:Text.Wrap; color:root.muted; Layout.fillWidth:true }
                }
            }
        }
    }
}
