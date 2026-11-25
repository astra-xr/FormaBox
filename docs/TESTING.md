# 实际测试记录

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
