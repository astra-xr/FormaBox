# 实际测试记录

## 0.9.4 · 进程回收与覆盖升级

本机 Windows x64 使用 Qt 6.8.3 和 MSVC 2022 编译。新桌面二进制通过 `--verify-runtime`，包含真实 Python 子进程的强制终止、自然退出、析构回收和多进程组隔离测试。安装事务在含中文和空格的样本目录模拟文件锁，确认部分替换失败后恢复原文件，解除锁定后可重试，并保留用户文件。

发布工作流依次验证完整安装包、0.9.0 与 0.9.3 的真实覆盖升级及回滚。以对应 GitHub Actions 运行和 Release 为发布依据。

## 0.9.3 Windows 完整预览版

本机 Windows x64 使用 Qt 6.8.3 与 MSVC 2022 编译 Release。覆盖项目根目录启动器及 `dist/Omnora.exe` 后，`Omnora.exe --verify-runtime` 退出 0。用现有虚拟环境和引擎运行 `python -m pytest -q -ra tests`，73 项通过。对已部署的 worker 实跑 `python -X utf8 -B tests/smoke_tools.py`，79 项通过，0 项失败，0 项阻塞。

[发布流水线](https://github.com/astra-xr/Omnora/actions/runs/46129440414)在 Windows 上通过 73 项 pytest，生成完整安装包并在含中文与空格的路径中测试安装、应用启动、资源管理器「发送到」、已安装环境的 79 项工具实跑和卸载。已发布为 [v0.9.3 Windows 完整预览版](https://github.com/astra-xr/Omnora/releases/tag/v0.9.3)。后续工作见[维护进度](maintenance/STATUS.md)与[下一步](maintenance/NEXT.md)。

## 0.9.3 开发中 · 文件提交恢复

Windows 桌面回归覆盖了三种中断结果。文件已提交时，重启会恢复完成状态和产物记录。文件仍在暂存目录时，任务保持中断，待结果实际提交后，下次启动才恢复。文件大小与回执不符时，任务保持中断。常规任务成功入库后会清理内部回执。本机 6 项定向 worker 用例还覆盖了提交前改名失败、重试时保留已有结果，以及旧 CLI 请求兼容。

[Windows CI](https://github.com/astra-xr/Omnora/actions/runs/46121697518) 通过桌面回归和 NSIS 模板编译。内置引擎下 73 项 pytest 和 79 项工具实跑全部通过，工具实跑失败和阻塞均为 0。校验并同步 Windows 构建后，从本机项目根目录运行 `Omnora.exe --verify-runtime`，退出码为 0。

## 0.9.2 开发中 · 任务产物记录

`Omnora.exe --verify-runtime` 在隔离目录升级旧 SQLite v2，验证已移走的旧结果仍显示在历史里。实际转换任务先因缺文件失败，再成功重试。重新打开后，产物关联第二次执行，结果文件大小变化时会提示。清除历史级联清除产物记录，源文件和输出文件保留。

[Windows CI](https://github.com/astra-xr/Omnora/actions/runs/46101707290) 通过桌面回归和 NSIS 模板编译。内置引擎下 71 项 pytest 与 79 项工具实跑通过，失败和阻塞均为 0。校验并同步 Windows 构建后，本机 `Omnora.exe --verify-runtime` 退出 0，5 项本机定向 worker 用例通过。

## 0.9.2 开发中 · 任务执行记录

`Omnora.exe --verify-runtime` 在隔离目录验证 SQLite v1 升级和旧 QSettings 导入。对同一任务写入排队与运行状态，重开后记录中断并触发实际缺文件失败的重试，核对两次尝试的编号、原任务 ID、错误码与时间。还验证了重复状态不追加事件、旧记录没有虚构时间、密码未写入数据库、清除历史会一并删除事件，以及任务中心可打开执行记录。

[Windows CI](https://github.com/astra-xr/Omnora/actions/runs/46100423861) 通过桌面回归和 NSIS 模板编译。内置引擎下 71 项 pytest 和 79 项工具实跑全部通过，工具失败与阻塞均为 0。校验构建产物后同步本机 `dist/Omnora.exe`，本机启动器的 `--verify-runtime` 退出 0。

## 0.9.2 开发中 · SQLite 任务存储

在隔离的 Windows 测试目录运行 `Omnora.exe --verify-runtime`，验证旧 QSettings 历史与批处理记录只迁移一次、并行实例的任务不会误判中断、重开后能手动重试普通任务并保留 ID。含密码的工作流只恢复状态，数据库文件中没有测试密码。清除历史后再次开启不会重新迁移。验证使用样本历史。

首次 Windows 构建发现 Qt 6.8 的 `QJsonObject` 迭代器兼容问题，改用 `constBegin` 和 `constEnd` 后，[Windows CI](https://github.com/astra-xr/Omnora/actions/runs/46099227049) 通过桌面启动、SQLite 驱动部署和 NSIS 模板编译。内置引擎下 71 项 pytest 和 79 项工具实跑均通过，工具失败和阻塞均为 0。

校验 Windows 产物后同步本机 `dist/Omnora.exe`、`Qt6Sql.dll` 和 `plugins/sqldrivers/qsqlite.dll`。本机启动器的 `--verify-runtime` 和中文文件名的 `--verify-quick --quick-photo --send-to` 均退出 0，4 项本机定向 worker 兼容测试通过。

## 0.9.1 开发中 · Worker 协议 v1

本机 Windows 的 6 项定向 pytest 通过，验证无版本号请求、显式 v1 请求、无效 JSON、未知版本、缺文件、缺引擎、无效参数和取消。用项目启动器运行同步后的 `Omnora.exe --verify-runtime`，退出码为 0。桌面回归验证缺文件时记录 `file_not_found`，保留重试状态，并且未建立输出目录。

[GitHub Windows CI](https://github.com/astra-xr/Omnora/actions/runs/46097470211) 通过桌面验收和 NSIS 模板编译。内置引擎环境执行 `python -m pytest -q -ra tests` 通过 71 项。在暂存目录用已校验的内置引擎执行 `python -X utf8 -B tests/smoke_tools.py`，79 项通过，失败和阻塞均为 0。

## 0.9.1 开发中 · 预览服务

本机 Windows 的 7 项定向测试通过，覆盖工具清单、批量改名、PDF 缩略图与压缩、证件照及归档预览。下载并校验 Windows CI 产物后更新 `dist/Omnora.exe`，使用项目启动器运行 `Omnora.exe --verify-runtime`，退出码为 0。

[GitHub Windows CI](https://github.com/astra-xr/Omnora/actions/runs/46095619723) 通过桌面回归。PDF 分两批导入时保留第一批缩略图，生成期间清除预览会在进程退出后删除临时目录，保存的 PDF 与压缩预览逐字节一致。内置引擎环境运行 `python -m pytest -q -ra tests` 通过 67 项。使用已校验的引擎在暂存目录运行 `python -X utf8 -B tests/smoke_tools.py`，79 项通过，失败与阻塞均为 0。安装相关检查覆盖 NSIS 模板编译。

## 0.9.1 开发中 · 引擎注册表

本机 Windows x64 的工具清单、命令行和引擎路径回归共 4 项通过。用显式不存在的路径运行 `python -B -X utf8 -m formabox check-engines`，四套引擎均正确报告不可用。校验 Windows CI 产物后同步本机桌面和 worker，根目录 `Omnora.exe --verify-runtime` 退出码为 0。

[GitHub Windows CI](https://github.com/astra-xr/Omnora/actions/runs/46094521437) 编译并验证开发版的路径选择、保存前的诊断路径核对和重置。内置引擎环境中 `python -m pytest -q -ra tests` 通过 67 项。`check-engines` 验证四个引擎实际选中预期路径，Word 转 PDF、OCR、音频生成与 whisper.cpp 启动均通过。给桌面进程注入失效的引擎路径和 OCR 字库环境变量后，验证了内置程序优先和设置入口隐藏。

使用从 0.9.0 完整包提取并校验的引擎，在桌面暂存目录运行 `python -X utf8 -B tests/smoke_tools.py`。79 个工具全部通过，失败、阻塞均为 0，含真实的语音转写。此轮的安装验证覆盖 NSIS 模板编译，完整包安装和卸载的实际记录见上一轮。

## 0.9.1 开发中 · 工具目录拆分

在本机 Windows x64 上，改动前用 `Omnora.exe --verify-runtime` 验证项目现有启动器，退出码为 0。用项目虚拟环境运行 `python -B -m pytest -q -ra -p no:cacheprovider --basetemp .dev/registry-091/pytest-before tests`，61 项通过，6 项跳过。跳过的用例需要 PATH 中的 FFmpeg（3 项）、Tesseract（1 项）或可运行的 LibreOffice（2 项）。本轮基线有意关闭 LibreOffice。

运行 `python -m formabox list` 后与 `docs/tools-manifest.json` 比对，79 项工具的 ID、顺序和规格一致。拆分后重跑 `test_manifest`、`test_cli` 和 `test_workflow_progress_across_steps`，3 项通过。Qt 6.8.3 的 `moc` 成功生成 `ToolRegistry` 和 `Controller` 的元对象，保留了原有的 `tools` 属性和通知信号。

本机编译和全工具实跑因 Visual Studio 诊断连接被自动拦截，后续使用 [GitHub Windows CI](https://github.com/astra-xr/Omnora/actions/runs/46045286553) 验收。Windows x64、Qt 6.8.3 和 MSVC 2022 成功编译并运行 `Omnora.exe --verify-runtime`。新增回归验证连续三次刷新合并为两次加载，工具规格和顺序一致。校验 CI 产物 SHA-256 后更新本机 `dist/Omnora.exe`，通过项目启动器再次运行桌面回归，退出码为 0。

临时分支 `qa/omnora-091-tool-registry` 使用从已发布的 0.9.0 安装包提取且经校验的引擎运行 `python -m pytest -q -ra tests`，67 项通过，无跳过。重新构建完整 NSIS 安装包后运行 `scripts/test-windows-installer.ps1 -ExpectBundledEngines`，验证中文安装路径、桌面启动、发送到和快捷动作、卸载保留用户文件。安装环境中 79 个工具全部实跑通过，失败和阻塞均为 0。安装包用于临时分支验收。

## 0.9.0 文件工作台扩展

本机 Windows x64 执行 `python -m pytest -q -ra tests` 通过 65 项，`python tests/smoke_tools.py` 实跑 79 个工具，失败和阻塞均为 0。用真实媒体验证两遍压缩的目标体积、视频剪切拼接、静音编辑、本机语音转写，以及 TXT/SRT 输出。用真实归档验证 7z、TAR、TAR.GZ 和 GZ 的创建、预览和指定文件提取。

PDF 用例核对了预览表格和 Excel 字符串结果、遮盖后的黑色像素、附件和源文字移除。文件夹任务在第一份成功后取消，用同一编号再次启动时保留旧文件并只处理剩余项。桌面测试验证了自定义常用工具、报名照预览及生成后的尺寸，并实际启动了两个右键快捷动作。

GitHub Windows x64 完整安装包在带中文和空格的路径安装，验收启动、两个资源管理器「发送到」快捷动作、79 个工具实跑和卸载保留用户文件。语音测试使用单独下载的固定模型，在已安装环境中实际产出 TXT 和 SRT。[发布验收记录](https://github.com/astra-xr/FormaBox/actions/runs/46002098582)

## 0.8.1 沉浸式 Windows 边框

在 Windows x64、Qt 6.8.3 和 150% 缩放下运行 `FormaBox.exe --verify-runtime`。通过 Win32 命中测试核对顶栏拖动区域、按钮点击区域、右边和两个角的缩放区域，验证顶栏双击最大化和还原、按钮最大化和还原、最小化。浅色和深色界面均检查了渲染效果。

本机 `python -m pytest -q -ra tests` 通过 59 项，`python tests/smoke_tools.py` 实跑 66 个工具，失败和阻塞均为 0。

GitHub 发布流程另从完整安装包安装到带中文和空格的目录。通过桌面边框、快捷方式、三个内置引擎、66 个工具实跑以及卸载保留用户文件的检查。[发布验收记录](https://github.com/astra-xr/FormaBox/actions/runs/45982142198)

## 0.8.0 界面与工具导航

Windows x64 使用 MSVC 2022 和 Qt 6.8.3 编译并运行 `FormaBox.exe --verify-runtime`。检查首页 12 个互不重复的常用工具、文档与数据和文件与隐私分组、跨分类搜索、全部工具入口，以及任务中心和工作流的初始折叠状态。切换浅色和深色后，按钮跟随主题。向窗口发送两个鼠标移动事件，确认按钮反光位置随指针改变。

本机 `python -m pytest -q -ra tests` 通过 59 项，`python tests/smoke_tools.py` 实跑 66 个工具，失败和阻塞均为 0。桌面回归同时覆盖 PDF 页面工作台、结果、重命名预览、预设、多步工作流和字幕。

发布流程在 Windows 上用 0.8.0 完整安装包安装到带中文和空格的路径。通过明暗主题、常用工具、分类和搜索、按钮反光、资源管理器「发送到」、三个内置引擎、66 项实跑，以及卸载保留用户文件的验收。[发布验收记录](https://github.com/astra-xr/FormaBox/actions/runs/45973825707)

## 0.7.0 视频批量抽帧与 Windows 完整安装包

Windows x64 的 `python -m pytest -q -ra tests` 通过 59 项。新增用例使用带中文、空格和百分号的文件名，在真实视频中依序提取不同的 PNG 帧，核对尺寸、张数上限和原文件字节。

本机 `python tests/smoke_tools.py` 实跑 66 个工具，通过 66 项、失败 0 项、阻塞 0 项。完整引擎目录的桌面回归和项目根目录的 `FormaBox.exe --verify-runtime` 均返回 0。

发布流程在 Windows Server 2022 安装到含中文和空格的路径，用随包提供的 FFmpeg、Tesseract 和 LibreOffice 分别验证音频生成、中英文 OCR 语言包与识别、Word 转 PDF。清除外部配置后，已安装的 66 个工具全部通过实跑。另验证了资源管理器「发送到」导入两个中文路径、桌面启动，以及卸载保留用户创建的文件。[发布验收记录](https://github.com/astra-xr/FormaBox/actions/runs/45960414096)

## 内置引擎开发验收

在 Windows x64 用 MSVC 2022 和 Qt 6.8.3 构建。暂存目录包含 Qt、独立 Python、工作进程及三个引擎。仅保留 Windows 系统 PATH，并清除外部引擎与语言包环境变量后，`python -m formabox check-engines` 通过 FFmpeg 音频生成、Tesseract 识别和 LibreOffice Word 转 PDF。结果路径均位于该暂存目录下的 `engines`。

- `python -m pytest -q -ra tests` 通过 58 项，0 失败、0 跳过。新增用例覆盖内置路径及用户指定路径优先级。
- `python tests/smoke_tools.py` 使用暂存目录自带的 Python 实跑 65 项工具，0 失败、0 阻塞。另用中文图片识别出「万象文件处理」。
- 暂存程序及项目根目录的 `FormaBox.exe --verify-runtime` 都返回 0。内置引擎约占 1 GB 安装空间。打包脚本已验证暂存文件、完整包名称与卸载清单。完整安装向导的 NSIS 编译与实机安装仍待完成。
- Windows 桌面回归验证了两种引擎配置。完整构建在注入无效外部路径和语言包路径后仍通过三项内置引擎试跑，且引擎设置按钮不可见、对话框未加载。常规构建的引擎设置面板可正常打开和关闭。
- 使用 `scripts/package-windows.ps1 -PrepareOnly` 生成完整包的编译脚本。待打包目录的卸载清单、桌面回归和三个内置引擎试跑均通过。用户在本机 PowerShell 用 NSIS 编译出 `FormaBox-0.6.0-Windows-x64-Full-Setup.exe`，大小为 316,177,979 字节。通过文件长度与 NSIS CRC 校验，并生成 SHA-256 校验文件。自动化会话无法读取现有安装的注册表项，安装和卸载验收因此停在前置检查。

## 0.6.0 外挂字幕

在 Windows x64 上用 MSVC 2022 与 Qt 6.8.3 构建。运行 `FormaBox.exe --verify-send-to --send-to` 并传入两个带空格的中文路径，桌面验收返回 0。新增回归通过拖入推荐运行「平移 -600 毫秒 → 转 WebVTT → 导出带时间的讲稿」，核对原件字节和最终的 TXT。

- `python -m pytest -q -ra tests` 通过 57 项，无失败或跳过。新增用例检查中文与 UTF-16 输入、互转后多行正文、WebVTT 样式和行内时间码、负偏移过零、跨小时进位、混合格式批量和错误回滚。
- `python tests/smoke_tools.py` 在关闭可选引擎时通过 51 项内置工具，无失败。FFmpeg、Tesseract 与 LibreOffice 对应的 14 项逐工具实跑按缺引擎跳过。
- 字幕输入为独立 SRT 或 WebVTT 文件。视频内嵌字幕的抽取和封装保留在路线图。跨格式转换省略布局设置和扩展样式。

## 0.5.0 PDF 页码、文字水印与裁白边

在 Windows x64 上用 MSVC 2022 与 Qt 6.8.3 构建。用 `FormaBox.exe --verify-send-to --send-to` 传入两个带空格的中文路径，桌面回归返回 0。回归从 PDF 拖入推荐选择三项新工具，执行先裁边、再加页码、最后加文字水印的三步工作流，并检查任务结果。

- `python -m pytest -q -ra tests` 运行 53 项测试，0 失败、0 跳过。
- 用已部署的 worker 实跑 48 项内置工具，0 失败。仅此轮实跑关闭了外部引擎，涉及 FFmpeg、Tesseract 和 LibreOffice 的 14 项实跑跳过。
- 新用例验证每份文档独立计数、旋转页左下角定位、页码可复制、水印透明度在渲染图上的实际效果、四种旋转角度的裁边、原文保留，以及无效边距触发整批回滚。
- 在本机对带空格的中文路径输入实际渲染「内部资料」水印。PDF 裁边只修改可见范围，原有内容仍可从文件中提取。

## 0.4.0 结果面板、发送到、批量改名和多步工作流

在 Windows x64 上用 MSVC 2022 和 Qt 6.8.3 构建，并运行 `FormaBox.exe --verify-runtime --send-to`，传入两个含空格的中文文件路径。退出码为 0。

- `python -m pytest -q -ra tests` 为 46 项通过、0 失败、0 跳过。回归包含目标压缩的原始大小、批量改名的预览一致性、大小写重名、失效预览拒绝、EXIF 日期，以及原文件保留。
- `python tests/smoke_tools.py` 为 59 项通过、0 失败、0 阻塞。
- Windows 桌面回归检查启动参数导入、压缩结果统计与选中复用、三步预设保存和执行、中文路径的改名预览和副本输出。


## 0.3.0 PDF 限大小导出、扫描 OCR 与常用预设

在 Windows x64 上用 MSVC 2022 和 Qt 6.8.3 构建。暂存构建及项目根目录 `FormaBox.exe --verify-runtime` 均返回 0。桌面回归覆盖压缩前后预览、保存后的大小与预览一致、内置报名照预设执行、自定义预设保存和移除、同名校验及密码工具拒绝保存。

- `python -m pytest -q -ra tests` 通过 44 项，0 失败，0 跳过。包含目标大小、未达标、原件不变、原有文字保留和 OCR 旋转裁剪页的像素一致性。系统 Python 的 `pyreadline3` 仍在退出时打印控制台句柄清理警告，退出码为 0。
- `python tests/smoke_tools.py` 通过 59 项，0 失败，0 阻塞。含扫描 PDF OCR、PDF 按大小压缩及 Word 转 PDF。
- 申请 160 KiB 时，含扫描图和数字文字的样本由 1,281,563 字节降至 57,472 字节，文字仍可提取。申请 1 KiB 时，对照预览显示未达标，并保留 6,334 字节的候选结果供用户选择。
- 本机 Tesseract 使用中英语言包生成可搜索 PDF。PDFium 能在双语样本中搜到「文档」，也提取出了英文行。该样本把「扫描」误识别为「扫拍」，另一份中文样本误识别更多，识别准确度取决于字库、扫描质量和版面。

记录针对本机开发版。压缩和扫描 OCR 支持未加密 PDF，每份最多 300 页、256 MiB。

## 0.2.0 PDF 页面工作台、引擎设置与拖入推荐

在 Windows x64 上用 MSVC 2022 和 Qt 6.8.3 编译。通过项目根目录运行 `FormaBox.exe --verify-runtime`，退出码为 0。桌面回归用中文及空格路径的 PDF 与 PNG 验证混合输入推荐、生成三张缩略图、调页、旋转、移除及通过任务队列写出 PDF。引擎设置面板在桌面回归里实际打开。

- `python -m pytest -q -ra tests` 通过 42 项，0 失败，0 跳过。覆盖原 PDF 字节保留、重复插入页面、不同旋转角度、页数上限和错误清理。系统 Python 的 `pyreadline3` 仍在退出时打印控制台句柄清理警告，退出码为 0。
- `python tests/smoke_tools.py` 通过 57 项，0 失败，0 阻塞。
- `python -m formabox check-engines` 在本机真实运行 LibreOffice、FFmpeg 和 Tesseract。校验了 DOCX 转 PDF 的正文、FFmpeg 输出的音频采样及 Tesseract 的文字识别。

页面工作台支持未加密 PDF 和单帧图片，每次最多 32 个来源、300 页。当前为本机开发构建。

## 0.1.6 ZIP、工作流和任务取消回归

在 Windows x64 上复现了空目录压缩后丢失、工作流切换步骤时进度倒退、无效取消标记遗留临时目录三个问题。新增的三个回归用例在修复前均失败，修复后均通过。

- `python -m pytest -q -ra tests` 通过 39 项，0 失败，0 跳过。测试结束时，系统 Python 的 `pyreadline3` 打印了控制台句柄清理警告，退出码为 0。
- `python tests/smoke_tools.py` 通过 56 项，0 失败，0 阻塞。使用本机 FFmpeg、Tesseract 和 LibreOffice 验证外部引擎，包括 DOCX 转 PDF。
- 用 MSVC 2022 和 Qt 6.8.3 构建，再运行 `FormaBox.exe --verify-runtime` 检查更新后的项目启动入口，退出码为 0。随程序部署的 worker 报告版本 0.1.6。

## 0.1.5 指针跟随光效与 Windows 图标

在 Windows x64、Qt 6.8.3 和 MSVC 2022 上编译。使用 Windows 平台插件和 Qt 软件渲染测试实际绘制。鼠标在同一按钮内从左侧移至右侧时，两处采样亮度按光斑所在位置切换。移出后光斑渐隐，点击“重载引擎”仍按原逻辑工作。项目根目录的启动器及主程序使用多分辨率 ICO，Windows 安装包同时为安装与卸载程序提供应用图标。

本机编译使用 `./.dev/build-msvc-release.cmd`，根目录 `FormaBox.exe --verify-runtime` 返回 0，已部署的工作进程报告版本 0.1.5。原版本文件保存在 `D:\tool\FormaBox\.dev\pointer-v015-cb890838`。

## 本机按钮光感与 EXE 图标（2026-11-25）

普通按钮、侧栏和工具卡使用三段渐变及更亮的顶部反光。悬停、选中和键盘聚焦有外圈光晕。增大深色模式输入提示和选中文字的对比度。蓝紫色「万」字图标同时用于界面、窗口及两份 Windows EXE。

用 `./.dev/build-msvc-release.cmd` 在 Windows 编译并部署。用 Windows 平台插件抓取浅色和深色界面，确认按钮和文字可辨。校验启动器及主程序的 PE 图标资源和源 ICO 一致，含 16 到 256 像素的 10 档尺寸。项目根目录 `FormaBox.exe --verify-runtime` 启动回归返回 0。替换前的二进制位于 `D:\tool\FormaBox\.dev\glass-icon-668d9174\before`。

## 0.1.4 本机 Windows 更新（2026-11-25）

将发布标签 v0.1.4 的源码同步到本机，保留本地测试记录。使用 MSVC 2022、Qt 6.8.3 和 Ninja 编译，先部署到独立目录并验证启动，再更新项目根目录的启动器及 dist 中的应用。通过 Windows 平台插件和 Qt 软件渲染执行启动回归，验证工具清单加载、重复选择保留参数和工作流输入数量检查。

```powershell
.\.dev\build-msvc-release.cmd
cmake --install build/windows-msvc-release --config Release --prefix 'D:\tool\FormaBox\.dev\local-v014-3a543314\dist'
.\FormaBox.exe --verify-runtime
```

两次启动检查均返回 0。通过 dist/engines 中的 FFmpeg 和 Tesseract 以及用户配置的 LibreOffice，完整 pytest 为 **36 通过、0 跳过**，逐项工具试跑为 **56 通过、0 跳过、0 失败**。旧源码和替换前的程序文件已保存在同一独立目录中。

## Windows 项目启动入口（2026-11-25）

在 Windows x64 使用 MSVC 2022 编译项目根目录的 `FormaBox.exe`，由它启动同一项目下的 `dist/FormaBox.exe`。运行 `cmake --build build/windows-msvc-release --parallel 2` 并重新部署 `dist` 后，从不同的工作目录调用根目录启动器 `--verify-runtime`。桌面和 worker 正常加载，启动器返回 0。

安装器脚本在保留开始菜单快捷方式的同时增加了桌面「万象」快捷方式，并在卸载时移除。安装器测试脚本已加入对应检查并通过 PowerShell 语法检查。新安装包的安装和卸载待下次构建验证。

## 0.1.3 Windows Office 转 PDF 回归验收（2026-11-25）

测试复用 worker 的 LibreOffice 查找逻辑，覆盖默认位置、PATH 和 `FORMABOX_SOFFICE` 指定程序。在用户的 Windows x64 环境使用 `D:\Assembler\LibreOffice\program\soffice.com`（26.8.3.1），实测 DOCX 和 RTF 转 PDF。DOCX 通过桌面使用的 JSONL worker 入口转换，验证了中文和空格路径、PDF 页数与可提取正文、原文件保留。随 0.1.3 桌面程序部署的 Python worker 也独立完成 DOCX 转 PDF，`build/windows-release-check/FormaBox.exe --verify-runtime` 启动检查返回 0。

```powershell
$env:FORMABOX_SOFFICE = [Environment]::GetEnvironmentVariable('FORMABOX_SOFFICE', 'User')
$env:PYTHONPATH = (Resolve-Path worker).Path
$env:PYTHONUTF8 = '1'
$env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = '1'
$engines = (Resolve-Path dist/engines).Path
$env:Path = "$engines;$env:Path"
$env:TESSDATA_PREFIX = Join-Path $engines 'tessdata'
$scratch = New-Item -ItemType Directory -Path (Join-Path (Resolve-Path .dev).Path ('office-regression-' + [guid]::NewGuid().ToString('N')))
$env:TEMP = $scratch.FullName
$env:TMP = $scratch.FullName
.\.venv\Scripts\python.exe -m formabox doctor
.\.venv\Scripts\python.exe -m pytest -q -ra tests --basetemp (Join-Path $scratch.FullName 'pytest')
.\.venv\Scripts\python.exe tests/smoke_tools.py --scratch $scratch.FullName --report (Join-Path $scratch.FullName 'smoke.json')
```

pytest **36 通过、0 跳过**。逐项工具试跑 **56 通过、0 跳过、0 失败**。系统 Python 的 pyreadline3 在 pytest 退出时报告句柄关闭异常，pytest 退出码为 0。Excel、PowerPoint 和复杂 Word 排版待专项验收。

## 0.1.3 Windows x64 桌面与运行时

于 Windows x64 上使用 MSVC 2022 和 Qt 6.8.3 完成 Release 编译。通过 CMake 部署至独立测试目录，用应用目录旁的 Qt、CPython 和 worker 启动「万象」，程序确认 QML 窗口实例和工具清单加载成功。以仅包含 Windows 系统目录的 PATH 启动桌面程序，并独立运行打包后的 worker，使用真实文件验证 43 项内置操作，0 项失败。13 项音视频、OCR 和 Office 转 PDF 操作因测试环境未提供可选外部引擎而跳过。

安装包流程会在 Windows 上安装到包含中文和空格的路径，检查程序启动、开始菜单快捷方式、卸载注册和用户文件保留。发布仅在安装与卸载的检查通过后执行。

## 0.1.2 Windows 桌面构建验收（2026-11-25）

在用户的 Windows x64 机器上使用 Qt 6.8.3、Visual Studio Build Tools 2022 的 MSVC 19.44、Windows SDK 10.0.26100.0 与 CMake 3.23.1。使用 Windows SDK 的 C++20 探测程序已编译、链接并运行。CMake 的默认调试探测曾遇到 MSVC C1902，单独创建 Ninja Release 构建目录并将编译器探测配置设为 Release 后完成编译。

```powershell
cmake -S . -B build/windows-msvc-release -G Ninja `
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_TRY_COMPILE_CONFIGURATION=Release `
  '-DCMAKE_PREFIX_PATH=D:/Assembler/Qt/6.8.3/msvc2022_64' `
  '-DCMAKE_MAKE_PROGRAM:FILEPATH=D:/C++/CLion 2023.3.6/bin/ninja/win/x64/ninja.exe'
cmake --build build/windows-msvc-release --parallel 2
cmake --install build/windows-msvc-release --config Release --prefix dist
.\dist\FormaBox.exe
```

首次部署启动返回 `0xC0000135`。EXE 安装在 `dist` 根目录，Qt DLL 被部署到 `dist/bin`。将 Windows 的 `CMAKE_INSTALL_BINDIR` 对齐 EXE 位置后，干净部署包含根目录下的 Qt DLL 和 `qt.conf`，重新启动观察到真实 Windows 窗口。

Windows Qt 自动化检查使用实际的 `Main.qml`、控制器及已部署 Python worker。覆盖 56 个工具的参数默认值、8 个分类、搜索、浅色及深色主题、中文与空格路径、输入去重、JPEG 转换、两步缩放转码工作流、JSON 文本导入导出操作、无效图片报错、取消、关闭保护与终态历史。验证图像大小、原始图片保留和历史文件。当前工具会话的默认临时目录出现清理警告且未观察到任务取消，改用可写项目临时目录后验收通过。窗口通过真实 Windows 平台启动，自动化检查使用 Qt 的 offscreen 平台。自动化尚未验证系统文件对话框和鼠标拖放。

本机开发目录 `dist/engines` 已配置 FFmpeg、Tesseract 和中英文数据，Tesseract 从同目录读取 `chi_sim`、`eng` 和 `osd`。pytest 结果为 **34 通过、1 跳过**，逐工具试跑为 **55 通过、1 缺少依赖、0 失败**。LibreOffice 转 PDF、干净机器部署、依赖授权清单与正式安装包待验收。

## 0.1.2 Windows 引擎依赖验收（2026-11-25）

项目虚拟环境已通过 pip 安装 setuptools 84.2.1、pypdfium2 5.15.2、cryptography 47.0.0、pytest 9.2.0 和可编辑的 FormaBox worker。简体中文模型从 Tesseract 上游取得并核对 Git blob 哈希，安装在 `.dev/tessdata`，同目录保留英文字库和方向检测数据。

```powershell
$env:PYTHONUTF8 = '1'
$ffmpeg = (Resolve-Path '.dev/ffmpeg-9.1-essentials_build/bin').Path
$env:PATH = "$ffmpeg;D:\tool\ocr;" + $env:PATH
$env:TESSDATA_PREFIX = (Resolve-Path '.dev/tessdata').Path
$env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = '1'
tesseract --list-langs
.\.venv\Scripts\python.exe -m pytest -q -ra tests
.\.venv\Scripts\python.exe tests\smoke_tools.py --scratch .dev --report .dev\smoke-tools-local-ocr.json
```

pytest **34 通过、1 跳过**。逐工具试跑 **55 通过、1 缺少依赖、0 失败**。两套测试中只有 LibreOffice 转 PDF 待验证。另用带「中文识别测试」的图片经 FormaBox CLI 验证了 `chi_sim` 的文字输出。

微软 Build Tools 2022 和 Qt 官方安装器均已下载并通过 Windows 代码签名核验。微软安装流程返回 1602，系统中尚未检测到已安装的 MSVC 工具链。Qt SDK 尚未检测到，LibreOffice MSI 下载尚未完成。桌面构建与 EXE 启动待齐备工具链后验证。

## 0.1.2 Windows 依赖复验（2026-11-25）

Windows 虚拟环境可从项目内的 `.dev/test-dependency-source` 加载 pytest 8.3.5、pluggy 1.5.0、iniconfig 2.0.0。其上游发布标签的 87 个源文件均已核对 Git blob 哈希。通过虚拟环境中的 `formabox_offline_tests.pth` 加载，版本元数据根据已校验的标签生成。

```powershell
$env:PYTHONPATH = (Resolve-Path worker).Path
$ffmpeg = (Resolve-Path '.dev/ffmpeg-9.1-essentials_build/bin').Path
$env:PATH = "$ffmpeg;D:\tool\ocr;" + $env:PATH
$env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = '1'
.\.venv\Scripts\python.exe -m pytest -q -ra tests
```

完整 pytest 收集并运行 35 项，得到 **33 通过、1 失败、1 跳过**。失败项是缺少 pypdfium2 的 PDF 渲染测试，LibreOffice 转 PDF 跳过。音频拼接与分段回归测试通过。测试结束后，系统 Python 的 pyreadline3 输出了一条 Windows 句柄关闭异常。

`build-windows.ps1 -TestOnly -Wheelhouse 'C:\path\to\wheelhouse'` 仍停在 `setuptools>=68`，项目要求的 `cryptography>=44` 也待安装。Tesseract 仍只列出 `eng` 和 `osd`。CMake 已用现有 MinGW 13.1 配置到 Qt 查找阶段，缺少 `Qt6Config.cmake`，Qt 6 MSVC 工具链、桌面程序编译与启动待验证。当前会话无法把外部二进制依赖下载到工作目录，后续可从可联网的环境准备 Windows x64 wheel、Qt SDK/MSVC Build Tools、LibreOffice 安装包与 `chi_sim.traineddata` 后补装。

## 0.1.2 Windows 音频验收（2026-11-25）

新增 `audio.concat` 和 `audio.split`，两项工具共用现有 CLI 及桌面工具清单。拼接按输入顺序取首条音轨，支持不同格式和采样率。定长分段使用 1–600 秒的整数间隔，保留末段实际时长。输出为 48 kHz、16 位双声道 WAV，每次最多处理 4 小时音频，分段最多 256 个。

```powershell
$env:PYTHONPATH = (Resolve-Path worker).Path
$ffmpeg = (Resolve-Path '.dev/ffmpeg-9.1-essentials_build/bin').Path
$env:PATH = "$ffmpeg;D:\tool\ocr;" + $env:PATH
.\.venv\Scripts\python.exe -m formabox doctor
.\.venv\Scripts\python.exe tests\smoke_tools.py --scratch .dev --report .dev\smoke-tools-0.1.2.json
```

逐工具测试为 **54 通过、2 缺少依赖、0 失败**。WAV 和 FLAC 拼接后按样本验证输入顺序与总时长，分段验证 1 秒、0.25 秒和 0.5 秒输出。另用 Windows 上的 Python 3.11 和 FFmpeg 9.1 验证超过 260 字符的中文输入和含百分号的输出路径、整数边界、空音轨拒绝、段数与总时长限制、取消和暂存清理。工具清单与运行时注册一致。

```powershell
.\scripts\build-windows.ps1 -TestOnly -Wheelhouse 'C:\path\to\wheelhouse'
.\.venv\Scripts\python.exe -m pytest -q -ra tests
cmake -S . -B build/windows-mingw -G Ninja '-DCMAKE_CXX_COMPILER=g++.exe' '-DCMAKE_BUILD_TYPE=Release'
tesseract --list-langs
```

离线 wheel 目录缺少 `setuptools>=68`，在线下载也未取得所需依赖。当前环境缺少 pytest，完整 pytest 套件待运行。PDF 渲染缺少 pypdfium2，Office 转 PDF 缺少 LibreOffice，Tesseract 仅安装 `eng` 和 `osd`。CMake 配置停在 `Qt6Config.cmake` 查找，Windows GUI、EXE 启动和打包待验收。下一步优先补齐 Qt 6 MSVC 工具链和上述依赖，完成桌面构建、全套 pytest 与中文 OCR 验证。其他开发目标见 `ROADMAP.md`。

## 0.1.1 Windows 开发验收（2026-11-25）

在 `D:\tool\FormaBox` 运行真实文件用例。环境使用 Python 3.11.3、Pillow 12.3.0、pypdf 5.9.0、cryptography 43.0.1、FFmpeg 9.1 essentials、Tesseract 5.4.0 和 CMake 3.23.1。此次使用现有环境中的 cryptography 43.0.1 实测，项目声明的 `>=44` 安装组合仍待验证。

```powershell
$env:PYTHONPATH = (Resolve-Path worker).Path
$ffmpeg = (Resolve-Path '.dev/ffmpeg-9.1-essentials_build/bin').Path
$env:PATH = "$ffmpeg;D:\tool\ocr;" + $env:PATH
.\.venv\Scripts\python.exe -m formabox doctor
.\.venv\Scripts\python.exe tests\smoke_tools.py --scratch .dev --report .dev\smoke-tools.json
```

逐项结果为 **52 通过、2 依赖阻塞、0 失败**。原有 50 项中 48 项验证了实际输出，新增的 4 项通过。`pdf.render` 缺少 pypdfium2，`doc.pdf` 缺少 LibreOffice。两项均实测返回错误，工具级测试的退出码为 2。英文 OCR 输出已验证，中文语言包 `chi_sim` 待安装。

回归检查覆盖空工作流拒绝、错误参数、源文件保留、取消清理、篡改密文拒绝、禁止把结果写进输入目录、Windows 保留名称、格式转换实际解码。长路径测试完成了 337 字符输入、371 字符输出的文件哈希任务。目录递归测试从短路径根目录发现并读取了 341 字符路径。当前权限拒绝创建测试 junction，重解析点的实机夹具验证待完成。

格式专项检查通过 20 个独立输出组合。图片为 JPG、JPEG、PNG、WebP、AVIF、BMP、TIFF、ICO，视频为 MP4、MKV、WebM、MOV、AVI，音频为 MP3、WAV、FLAC、AAC、OGG、Opus、M4A。每项均重新解码产物。超出音频长度的剪切会返回错误，缺少 `chi_sim` 时默认 OCR 会明确提示缺少语言包。

```powershell
.\scripts\build-windows.ps1 -TestOnly -Wheelhouse 'C:\path\to\wheelhouse'
cmake -S . -B build/windows-mingw -G Ninja '-DCMAKE_CXX_COMPILER=g++.exe' '-DCMAKE_BUILD_TYPE=Release'
```

初始脚本调用 `py` 时找不到 Python。改用实际安装的 `python.exe` 后，本地 wheel 目录缺少 `setuptools>=68`，原有 pytest 套件未运行。CMake 识别了现有 MinGW 13.1 编译器，配置阶段缺少 `Qt6Config.cmake`。桌面编译、启动、交互检查、便携包和干净系统验证待完成。浏览器依赖下载中途停止，当前终端无法联网补齐缺件。

当前仍待完成的产品功能在 `ROADMAP.md` 保留。桌面 SDK 到位后的验收项包括拖放、动态表单、引擎状态提示、取消、重试、工作流文件、系统主题、历史和关闭行为。后续仍需 OS 级进程与网络隔离、资源配额和依赖分发审查。

## 0.1.0 Linux 交接测试

本次交接包在 Linux 容器内执行：

```
PYTHONPATH=worker pytest -q -ra tests
..................................                                       [100%]
34 passed in 4.38s
```

覆盖真实图片编码、目标大小、尺寸调整、拼接、遮盖；PDF 合并、拆分、重排、压缩、渲染、加解密；AES-GCM 往返、错误密码和篡改拒绝；文件分片哈希、目录比较、ZIP 恶意路径/大小限制、文件复制、文本与 JSON/CSV；工作流、取消、参数验证、CLI；FFmpeg 视频/音频处理、Tesseract 英文 OCR、LibreOffice RTF 转 PDF。

已注册 50 项工具，34 个 pytest 用例（部分用例覆盖多项功能）。测试不等于覆盖所有文件格式和边界，尤其未逐一验证 HEIC、AVIF、ICO、每种音视频编码器、所有 Office 格式、中文 OCR 质量、大文件极限、损坏文件与 Windows 行为。

本次 Linux 环境依赖：Pillow 12.3.0、pypdf 5.9.0、cryptography 46.0.4、FFmpeg 7.1.5、Tesseract 与 LibreOffice 已可执行、pypdfium2 已导入。具体依赖版本以用户实际环境为准。

Qt 配置检查 `cmake -S . -B /tmp/formabox-cmake-check` 在 find_package(Qt6) 失败：环境没有 Qt6Config.cmake。因此 C++ 编译、QML 加载、Windows UI 实际运行、打包均未验证；未生成 EXE。GitHub CI 配置也未执行。

Windows 下一轮验收：在实际机器运行脚本和 GUI；测试文件/文件夹拖拽、中文路径、工具表单、输出目录、队列、任务取消、工作流、历史、深色主题、缺依赖错误、启动与关闭、权限、重解析点、大文件和磁盘不足。对 GUI 与底层引擎都要检查真实输出，不接受假成功。发布前做干净虚拟机测试、第三方许可和安全审查。
