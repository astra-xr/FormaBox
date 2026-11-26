# 架构和协议

Desktop (Qt/C++20 + QML) → Qt QProcess → worker (Python) → mature libraries / external engines.

Qt 通过 `python -m formabox list` 获得 JSON 数组工具规格，规格含 id、分类、标题、参数列表、输入数量上下限、说明及依赖。0 代表输入数量不限。规格参数默认值主要为字符串；worker 独立验证、拒绝未知参数。

桌面加载目录时附加 `--check-engines`，工具规格里会增加 `missing_engines` 数组。原始 `list` 格式保持兼容。`doctor` 输出本机引擎可发现性。

运行时使用 `python -m formabox run --request -`，stdin 写入单个 UTF-8 JSON 对象再关闭。单进程一次任务。stdout JSONL：`progress` current/total/message，`result` directory/files，`error` message/type，`cancelled` message。只有真实返回并正常退出时可判定成功。退出码 0/1/2。进度目前通常按文件计数而非时间，单个长任务可能长时间不变化。

取消机制：桌面端创建每任务独立临时目录，取消时写标记文件，worker 在循环与外部进程轮询中检查；库内部的单次长调用未必能即时取消。Python 进程崩溃或被强制终止可能遗留暂存目录和外部子进程。后续用 Windows Job Object/受限令牌等做进程树控制与 OS 级沙箱。

任务输出 `FormaBox-<随机ID>/`：同一输出根中的临时目录 `.formabox-*`，处理全部完成后改名提交。用户文件保持原样；工作流按步骤使用独立子目录，失败则整批清理。该原子提交不代表断电持久性保证，当前无自动恢复。

UI 队列在内存、终态历史 QSettings（最多 100 条，包含输出文件路径、大小和消息，用户可清除）。任务历史不记录请求参数或密码。工作流 JSON 可手工导出保存，也可以和单工具参数一样存为本地预设。含密码参数的工具不能保存为预设。

`result` 可附带与 `files` 同序的 `details`。图片和 PDF 目标压缩报告原始大小、目标大小。桌面端使用实际输出大小计算是否达标，并在打开或复用结果前重新检查路径。批量改名用同一规则生成预览和输出名称，队列执行前核对预览校验值。

安装版的「发送到」快捷方式通过 `--send-to` 将本地文件路径传入 Qt，启动时放入当前输入。

桌面端收到 `result` 后等待进程以状态码 0 退出，再检查实际产物并更新任务状态。非密码任务失败时可在本次会话重试，请求参数保存在内存中，重启后仅保留终态历史。工作流文件使用原子写入。

Python worker 集成文件处理库和外部引擎。Qt/C++ 桌面端已在 Windows 上构建并验证，可通过安装包运行。后续可逐步用 libvips/qpdf/C++ worker 替换热点，保持工具接口与协议，不能从零重写编解码器。SQLite 持久任务状态、原生硬件加速、插件信任边界均在后续。
