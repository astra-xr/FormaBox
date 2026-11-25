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
    readonly property color selection: dark ? "#526b9e" : "#dde7ff"
    readonly property color hoverFill: dark ? "#415474" : "#ffffff"
    readonly property color buttonTop: dark ? "#56475b7c" : "#b8ffffff"
    readonly property color buttonBottom: dark ? "#2b263954" : "#5ee6eefc"
    property string category: "全部"
    property var selected: null
    property var inputs: []
    property var params: ({})
    property var steps: []
    property string workflowNotice: ""
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
        property bool centered: false
        implicitHeight: 37
        padding: 10
        hoverEnabled: true
        font.weight: selected || primary ? Font.DemiBold : Font.Normal
        contentItem: Label {
            text: control.text
            font: control.font
            color: control.primary && control.enabled ? "#ffffff" : root.ink
            opacity: control.enabled ? 1 : 0.62
            wrapMode: Text.Wrap
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: control.centered ? Text.AlignHCenter : Text.AlignLeft
        }
        background: Rectangle {
            radius: 10
            border.color: control.selected || control.visualFocus ? root.accent : root.rim
            gradient: Gradient {
                GradientStop {
                    position: 0
                    color: control.primary && control.enabled ? (control.down ? "#414abf" : "#5264dc")
                          : control.selected || control.down ? root.selection
                          : control.hovered ? root.hoverFill : root.buttonTop
                }
                GradientStop {
                    position: 1
                    color: control.primary && control.enabled ? "#3945b5"
                          : control.selected || control.down ? root.selection
                          : root.buttonBottom
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

    function chooseTool(tool) {
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
    onClosing: function(close){if(backend.busy){close.accepted=false;root.workflowNotice="请先取消或等待当前任务结束再关闭"}}
    header: Item {
        height: 75
        GlassSurface { anchors.fill: parent; anchors.margins: 14; anchors.bottomMargin: 0 }
        RowLayout { anchors.fill: parent; anchors.leftMargin: 28; anchors.rightMargin: 28; anchors.topMargin: 14; spacing: 12
            Rectangle {
                Layout.preferredWidth: 38; Layout.preferredHeight: 38; radius: 11
                gradient: Gradient {
                    GradientStop { position: 0; color: "#778bf2" }
                    GradientStop { position: 1; color: "#424fbd" }
                }
                border.color: "#aebaff"
                Label { anchors.centerIn: parent; text: "万"; color: "#ffffff"; font.pixelSize: 22; font.bold: true }
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
            GlassButton { text: "重载引擎"; centered: true; onClicked: backend.reload() }
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
                    RowLayout { Layout.alignment: Qt.AlignHCenter; Button { text: "选择文件"; onClicked: files.open() } Button { text: "选择文件夹"; onClicked: folder.open() } Label { text: root.inputs.length+" 个输入"; color: root.muted } }
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
                    RowLayout { Label { text: "任务中心"; font.bold: true; color: root.ink } Item { Layout.fillWidth: true } Button { text: "清除历史"; enabled: !backend.busy; onClicked: backend.clearHistory() } }
                    ListView { Layout.fillWidth: true; Layout.fillHeight: true; clip: true; model: backend.jobs; spacing: 4
                        delegate: RowLayout { required property var modelData; required property int index; width: ListView.view.width
                            ColumnLayout { Layout.fillWidth: true; Label { text: modelData.title+" · "+modelData.state; color: root.ink; Layout.fillWidth: true; elide: Text.ElideRight } Label { text: modelData.message; color: root.muted; Layout.fillWidth: true; elide: Text.ElideRight; font.pixelSize: 11 } }
                            ProgressBar {
                                value: Math.max(0, modelData.progress)
                                indeterminate: modelData.state === "运行中" && modelData.progress < 0
                                visible: modelData.state === "运行中" || modelData.state === "完成"
                                Layout.preferredWidth: 75
                            }
                            Button { text: "重试"; visible: modelData.canRetry === true; onClicked: backend.retry(index) }
                            Button { text: modelData.directory?"打开":"取消"; visible: !!modelData.directory||modelData.state==="运行中"||modelData.state==="等待"; onClicked: modelData.directory?backend.openFolder(modelData.directory):backend.cancel(index) }
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
                    RowLayout { Label { text: "输入文件 ("+root.inputs.length+")"; color: root.ink; font.bold: true } Item { Layout.fillWidth: true } Button { text: "清空"; onClicked: root.inputs=[] } }
                    ListView { Layout.fillWidth: true; Layout.preferredHeight: Math.min(100,root.inputs.length*30); clip: true; model: root.inputs
                        delegate: RowLayout { required property string modelData; required property int index; width: ListView.view.width; Label { text: modelData; Layout.fillWidth: true; color: root.muted; elide: Text.ElideMiddle; ToolTip.visible: h.hovered; ToolTip.text: modelData; HoverHandler{id:h} } Button { text:"×"; onClicked:{let a=root.inputs.slice();a.splice(index,1);root.inputs=a} } }
                    }
                    Repeater { model: root.selected?root.selected.params:[]; delegate: ColumnLayout { required property var modelData; Layout.fillWidth: true
                        Label { text: modelData.label; color: root.ink; Layout.fillWidth: true; wrapMode: Text.Wrap }
                        Loader { Layout.fillWidth: true; sourceComponent: modelData.kind==="choice"?combo:modelData.kind==="bool"?check:field
                            Component { id: combo; ComboBox { model: modelData.choices; currentIndex: Math.max(0,model.indexOf(root.params[modelData.key])); onActivated: root.setParam(modelData.key,currentText) } }
                            Component { id: check; CheckBox { checked: String(root.params[modelData.key])==="true"; onToggled: root.setParam(modelData.key,checked?"true":"false") } }
                            Component { id: field; TextField { text: String(root.params[modelData.key]??""); echoMode: modelData.kind==="password"?TextInput.Password:TextInput.Normal; onTextEdited: root.setParam(modelData.key,text) } }
                        }
                    }}
                    Label { text: "输出目录"; color: root.ink; font.bold: true }
                    RowLayout { Layout.fillWidth: true; TextField { id: output; text: backend.outputDefault; Layout.fillWidth: true } Button { text:"…"; onClicked: outputFolder.open() } }
                    GlassButton { text: "加入任务队列"; primary: true; centered: true; Layout.fillWidth: true; enabled: root.selectedReady && root.inputCountValid && output.text.trim().length > 0; onClicked: {root.workflowNotice="";backend.submit(root.selected.id,root.inputs,root.params,output.text);if(root.selected.params.some(p=>p.kind==="password")){for(let p of root.selected.params)if(p.kind==="password")root.setParam(p.key,"")}} }
                    Button { text: "添加到工作流"; Layout.fillWidth: true; enabled: root.canAddStep; onClicked: root.addStep()
                        ToolTip.visible: hovered && root.selected !== null && !root.canAddStep && root.steps.length < 32
                        ToolTip.text: "密码工具无法保存到工作流"
                    }
                    Label { text: "自动化工作流 · "+root.steps.length+" 步"; font.bold: true; color: root.ink }
                    Repeater { model: root.steps; delegate: RowLayout { required property var modelData; required property int index; Layout.fillWidth: true; Label { text: (index+1)+". "+modelData.tool; color: root.muted; Layout.fillWidth: true; elide: Text.ElideRight } Button { text:"×"; onClicked:{let a=root.steps.slice();a.splice(index,1);root.steps=a} } } }
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
                    Button { text:"执行工作流"; Layout.fillWidth: true; enabled: root.workflowReady && output.text.trim().length > 0; onClicked: backend.submitWorkflow(root.steps,root.inputs,output.text) }
                    TextArea { id:workflowText; Layout.fillWidth:true; Layout.preferredHeight:75; placeholderText:"工作流 JSON（可复制保存）"; wrapMode:TextEdit.Wrap }
                    RowLayout { Button { text:"查看 JSON"; enabled: root.steps.length > 0; onClicked:workflowText.text=JSON.stringify(root.steps,null,2) } Button { text:"载入文本"; enabled: workflowText.text.trim().length > 0; onClicked:root.loadWorkflow(workflowText.text) } }
                    RowLayout { Button { text:"保存文件"; enabled: root.steps.length > 0; onClicked:saveWorkflowFile.open() } Button { text:"打开文件"; onClicked:openWorkflowFile.open() } }
                    Label { text:"任务输出在独立目录；原始文件不会被覆盖。"; wrapMode:Text.Wrap; color:root.muted; Layout.fillWidth:true }
                }
            }
        }
    }
}
