import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

ApplicationWindow {
    id: root
    width: 1200; height: 800; minimumWidth: 860; minimumHeight: 600
    visible: true; title: "万象"
    property string themeMode: "system"
    readonly property bool dark: themeMode === "system" ? backend.systemDark : themeMode === "dark"
    property color panel: dark ? "#20232c" : "#ffffff"
    property color canvas: dark ? "#171923" : "#f3f5fa"
    property color ink: dark ? "#e5e7f0" : "#242b3e"
    property color muted: dark ? "#9ba5b8" : "#68748b"
    property color accent: "#6568db"
    property string category: "全部"
    property var selected: null
    property var inputs: []
    property var params: ({})
    property var steps: []
    property string workflowNotice: ""
    readonly property bool selectedReady: selected !== null && !(selected.missing_engines || []).length
    readonly property bool inputCountValid: selected !== null && inputs.length >= selected.minimum
                                            && (!selected.maximum || inputs.length <= selected.maximum)
    property var categories: ["全部","图片","PDF","视频","音频","文档","文件","隐私"]
    color: canvas
    palette.window: canvas; palette.base: panel; palette.text: ink; palette.windowText: ink; palette.buttonText: ink; palette.button: panel; palette.highlight: accent
    function addUrls(urls) { let a=inputs.slice(); for(let u of urls){let p=backend.localPath(u);if(p && a.indexOf(p)<0)a.push(p)} inputs=a }
    function chooseTool(t) { selected=t; let p={}; for(let v of t.params)p[v.key]=v.default; params=p }
    function setParam(k,v){let p=Object.assign({},params);p[k]=v;params=p}
    function addStep() {
        if (!selected || steps.length >= 32) return
        if (selected.params.some(p => p.kind === "password")) {
            workflowNotice = "密码工具无法保存到工作流"
            return
        }
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
    header: Rectangle {
        color: root.panel; height: 65
        RowLayout { anchors.fill: parent; anchors.margins: 16; spacing: 12
            Rectangle { width: 36; height: 36; radius: 10; color: root.accent; Label { anchors.centerIn: parent; text: "F"; color: "white"; font.pixelSize: 22; font.bold: true } }
            Label { text: "万象"; font.pixelSize: 20; font.bold: true; color: root.ink }
            Label { text: "本地文件工作台 / " + Qt.application.version; color: root.muted }
            Item { Layout.fillWidth: true }
            ComboBox {
                model: ["跟随系统", "浅色", "深色"]
                currentIndex: ["system", "light", "dark"].indexOf(root.themeMode)
                onActivated: root.themeMode = ["system", "light", "dark"][currentIndex]
                Accessible.name: "界面主题"
            }
            Button { text: "重载引擎"; onClicked: backend.reload() }
        }
    }
    RowLayout {
        anchors.fill: parent; anchors.margins: 14; spacing: 14
        Rectangle { Layout.preferredWidth: 145; Layout.fillHeight: true; color: root.panel; radius: 12
            ColumnLayout { anchors.fill: parent; anchors.margins: 10; spacing: 5
                Label { text: "工具分类"; font.bold: true; color: root.muted; Layout.margins: 6 }
                Repeater { model: root.categories; delegate: Button { required property string modelData; text: modelData; checkable: true; checked: root.category===modelData; Layout.fillWidth: true; onClicked: root.category=modelData } }
                Item { Layout.fillHeight: true }
                Label { text: "默认保留源文件\n无账号 · 无广告"; wrapMode: Text.Wrap; color: root.muted; Layout.fillWidth: true; font.pixelSize: 12 }
            }
        }
        ColumnLayout { Layout.fillWidth: true; Layout.fillHeight: true; spacing: 10
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 115; radius: 12; color: root.panel; border.color: drop.containsDrag?root.accent:"#b8bfd1"
                DropArea { id: drop; anchors.fill: parent; onDropped: function(event){if(event.hasUrls){root.addUrls(event.urls);event.acceptProposedAction()}} }
                ColumnLayout { anchors.centerIn: parent; spacing: 8
                    Label { text: "将文件拖入这里"; font.pixelSize: 23; font.bold: true; color: root.ink; Layout.alignment: Qt.AlignHCenter }
                    RowLayout { Layout.alignment: Qt.AlignHCenter; Button { text: "选择文件"; onClicked: files.open() } Button { text: "选择文件夹"; onClicked: folder.open() } Label { text: root.inputs.length+" 个输入"; color: root.muted } }
                }
            }
            RowLayout { Layout.fillWidth: true; TextField { id: search; Layout.fillWidth: true; placeholderText: "搜索工具名称 / ID" } Label { text: backend.tools.length+" 个工具"; color: root.muted } }
            Rectangle { Layout.fillWidth: true; Layout.fillHeight: true; radius: 12; color: root.panel
                GridView { id: toolsView; anchors.fill: parent; anchors.margins: 10; clip: true; cellWidth: Math.max(145,width/Math.max(1,Math.floor(width/165))); cellHeight: 78
                    model: backend.tools.filter(t=>(root.category==="全部"||t.category===root.category)&&((t.label+" "+t.id).toLowerCase().includes(search.text.toLowerCase())))
                    delegate: Item { required property var modelData; width: toolsView.cellWidth; height: toolsView.cellHeight
                        Button { anchors.fill: parent; anchors.margins: 4; text: modelData.label; checkable: true; checked: root.selected!==null&&root.selected.id===modelData.id; onClicked: root.chooseTool(modelData); contentItem: Label { text: parent.text; wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; color: root.ink } }
                    }
                    ScrollBar.vertical: ScrollBar {}
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 174; radius: 12; color: root.panel
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
        Rectangle { Layout.preferredWidth: 310; Layout.fillHeight: true; radius: 12; color: root.panel
            ScrollView { id: details; anchors.fill: parent; anchors.margins: 12; contentWidth: availableWidth; clip: true
                ColumnLayout { width: details.availableWidth; spacing: 9
                    Label { text: root.selected?root.selected.label:"选择一个工具"; color: root.ink; font.pixelSize: 19; font.bold: true; wrapMode: Text.Wrap; Layout.fillWidth: true }
                    Label { text: root.selected?root.selected.description:"从左侧选择需要的功能"; color: root.muted; wrapMode: Text.Wrap; Layout.fillWidth: true; visible: text.length>0 }
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
                    Button { text: "加入任务队列"; highlighted: true; Layout.fillWidth: true; enabled: root.selectedReady && root.inputCountValid && output.text.trim().length > 0; onClicked: {root.workflowNotice="";backend.submit(root.selected.id,root.inputs,root.params,output.text);if(root.selected.params.some(p=>p.kind==="password")){for(let p of root.selected.params)if(p.kind==="password")root.setParam(p.key,"")}} }
                    Button { text: "添加到工作流"; Layout.fillWidth: true; enabled: root.selected !== null && root.steps.length < 32; onClicked: root.addStep() }
                    Label { text: "自动化工作流 · "+root.steps.length+" 步"; font.bold: true; color: root.ink }
                    Repeater { model: root.steps; delegate: RowLayout { required property var modelData; required property int index; Layout.fillWidth: true; Label { text: (index+1)+". "+modelData.tool; color: root.muted; Layout.fillWidth: true; elide: Text.ElideRight } Button { text:"×"; onClicked:{let a=root.steps.slice();a.splice(index,1);root.steps=a} } } }
                    Button { text:"执行工作流"; Layout.fillWidth: true; enabled:root.steps.length>0&&root.inputs.length>0; onClicked: backend.submitWorkflow(root.steps,root.inputs,output.text) }
                    TextArea { id:workflowText; Layout.fillWidth:true; Layout.preferredHeight:75; placeholderText:"工作流 JSON（可复制保存）"; wrapMode:TextEdit.Wrap }
                    RowLayout { Button { text:"查看 JSON"; enabled: root.steps.length > 0; onClicked:workflowText.text=JSON.stringify(root.steps,null,2) } Button { text:"载入文本"; enabled: workflowText.text.trim().length > 0; onClicked:root.loadWorkflow(workflowText.text) } }
                    RowLayout { Button { text:"保存文件"; enabled: root.steps.length > 0; onClicked:saveWorkflowFile.open() } Button { text:"打开文件"; onClicked:openWorkflowFile.open() } }
                    Label { text:"任务输出在独立目录；原始文件不会被覆盖。"; wrapMode:Text.Wrap; color:root.muted; Layout.fillWidth:true }
                }
            }
        }
    }
}
