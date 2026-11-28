# 架构和协议

Desktop (Qt/C++20 + QML) → Qt QProcess → worker (Python) → mature libraries / external engines.

Qt 通过 `python -m formabox list` 获得 JSON 数组工具规格，规格含 id、分类、标题、参数列表、输入数量上下限、说明及依赖。0 代表输入数量不限。规格参数默认值主要为字符串；worker 独立验证、拒绝未知参数。

桌面加载目录时附加 `--check-engines`，工具规格里会增加 `missing_engines` 数组。原始 `list` 格式保持兼容。`doctor` 输出本机引擎可发现性。

桌面的 `ToolRegistry` 负责异步目录加载、刷新请求合并，以及按工具 ID 查询规格。`Controller` 提供 worker 启动配置，并将目录和刷新状态转发给原有 QML 接口。预设、常用工具和任务标题共用注册表查询。加载失败时保留上一次成功获取的目录。

桌面的 `EngineRegistry` 提供引擎设置选项、内置路径识别和 worker 环境配置。完整安装版优先使用内置的 FFmpeg、Tesseract、LibreOffice 和 whisper.cpp，继续隐藏引擎设置入口。开发版可测试并保存手动路径，留空时沿用环境变量和 worker 自动查找。`check-engines` 用独立样本验证转换与 OCR，并检查 whisper.cpp 能否启动。语音模型在实际转写任务中校验。保存前核对诊断返回的可执行文件路径与用户选择一致。

桌面的 `PreviewService` 负责 PDF 页面、压缩对照、批量改名及交互工具的预览。它验证预览文件位于当前临时目录，保留工作台分批导入的缩略图，清除正在生成的预览时等 worker 退出后再删除临时文件。保存 PDF 压缩预览时复用已经验证的文件并原子提交。`InspectionRunner` 为预览和引擎诊断共用，负责进程启动、超时和返回结果。`Controller` 转发原有 QML 接口并记录已保存的 PDF 任务。

运行时使用 `python -m formabox run --request -`，stdin 写入单个 UTF-8 JSON 对象再关闭。单进程一次任务。请求可包含整数 `protocol_version: 1`，省略时按现有请求处理。显式传入其他版本或类型时，worker 在读取输入文件或创建输出目录前返回 `unsupported_protocol`。桌面发送版本 1，也能读取旧 worker 省略版本号的消息。`list` 与 `doctor` 保持原有的数组和对象结构。

`run` 的 stdout 是 UTF-8 JSONL，每条消息含 `event` 和 `protocol_version`。可先发送 `progress`（`current`、`total`、`message`），最后发送且只发送一条 `result`、`error` 或 `cancelled`。成功消息包含 `directory` 和 `files`，进程退出码为 0。失败消息保留 `message` 和诊断字段 `type`，退出码为 1。取消消息保留 `message`，退出码为 2。失败和取消消息另有稳定的 `error_code`。进度目前通常按文件计数，单个长任务可能长时间不变化。预览与引擎诊断返回单个 JSON 对象，保留 `result` 或 `error`，增加 `protocol_version`，整体失败时增加 `error_code`。引擎诊断中的各引擎继续用对应项的 `ok` 表示状态。

自动调用应读取 `error_code`。`invalid_request` 表示无法解析请求或缺少请求结构，`unsupported_protocol` 表示协议版本错误，`invalid_argument` 表示工具或参数无效。`file_not_found`、`permission_denied`、`file_conflict` 和 `io_error` 区分文件系统问题。`missing_dependency`、`engine_failed` 和 `timeout` 区分依赖缺失、外部程序失败和超时。`cancelled` 表示取消，`task_failed` 用作其他失败。桌面将错误码保存到对应任务，并会单独报告无效消息、进程启动或输出验证错误。

取消机制：桌面端创建每任务独立临时目录，取消时写标记文件，worker 在循环与外部进程轮询中检查；库内部的单次长调用未必能即时取消。Python 进程崩溃或被强制终止可能遗留暂存目录和外部子进程。后续用 Windows Job Object/受限令牌等做进程树控制与 OS 级沙箱。

任务输出到同一输出根下的 `Omnora-<随机ID>/`。处理结束后将临时目录改名提交，保留原始文件。工作流按步骤使用独立子目录，失败时整批清理。文件夹批处理逐文件提交，旧的批处理目录仍可用于续跑。

UI 队列在内存、终态历史 QSettings（最多 100 条，包含输出文件路径、大小和消息，用户可清除）。任务历史不记录请求参数或密码。工作流 JSON 可手工导出保存，也可以和单工具参数一样存为本地预设。含密码参数的工具不能保存为预设。

`result` 可附带与 `files` 同序的 `details`。图片和 PDF 目标压缩报告原始大小、目标大小。桌面端使用实际输出大小计算是否达标，并在打开或复用结果前重新检查路径。批量改名用同一规则生成预览和输出名称，队列执行前核对预览校验值。

PDF 页码、水印与裁边沿用独立任务和工作流协议。每批最多 32 份未加密 PDF，每份最多 300 页、256 MiB。页码和文字水印叠加在原页面之上，原有文字和矢量内容仍保留。裁边只写入页面可见范围（CropBox），按页面当前显示方向处理上、右、下、左。

字幕工具离线解析 SRT 与 WebVTT。接受 UTF-8、带 BOM 的 UTF-8 和带 BOM 的 UTF-16，统一输出 UTF-8。每批最多 32 份，每份最多 8 MiB。WebVTT 平移时同步更新正文内时间码并保留布局、样式和注释。跨格式转换保留正文及基础格式，省略 WebVTT 专属设置。

安装版的「发送到」快捷方式通过 `--send-to` 将本地文件路径传入 Qt，启动时放入当前输入。

桌面端收到 `result` 后等待进程以状态码 0 退出，再检查实际产物并更新任务状态。非密码任务失败时可在本次会话重试，请求参数保存在内存中，重启后仅保留终态历史。工作流文件使用原子写入。

Python worker 集成文件处理库和外部引擎。Qt/C++ 桌面端已在 Windows 上构建并验证，可通过安装包运行。后续可逐步用 libvips/qpdf/C++ worker 替换热点，保持工具接口与协议，不能从零重写编解码器。SQLite 持久任务状态、原生硬件加速、插件信任边界均在后续。
