# 接手指南

## 在新电脑上启动开发

从 Windows x64 开始。准备 Git、PowerShell 7、Visual Studio 2022 的「使用 C++ 的桌面开发」工作负载、CMake 3.21+、Qt 6.8.3 的 MSVC 2022 x64 套件和 Python 3.11+。Windows 安装包流水线使用 Python 3.13。克隆地址和 Qt 路径示例如下，Qt 路径按新电脑的安装位置替换。

```powershell
git clone https://github.com/astra-xr/Omnora.git
Set-Location Omnora
git status --short --branch
git log -5 --oneline
git describe --tags --always

.\scripts\build-windows.ps1 -TestOnly
.\scripts\build-windows.ps1 -QtPrefix 'C:\Qt\6.8.3\msvc2022_64'
.\Omnora.exe
```

构建脚本在项目内创建 `.venv`，部署程序到 `dist`，另在仓库根目录放置启动器。开发启动和自检应保留这两个位置的相对关系。发布的安装向导从[正式下载页](https://github.com/astra-xr/Omnora/releases)获取。旧机器的绝对路径、虚拟环境和构建缓存随各自机器管理。

命令行测试通过 PATH、引擎环境变量或已部署的引擎目录查找 FFmpeg、Tesseract、LibreOffice 和 whisper.cpp。桌面另有引擎设置。OCR 需要对应的语言包，简体中文用 `chi_sim`。优先按[依赖文档](../DEPENDENCIES.md)检查配置。

```powershell
.\.venv\Scripts\python.exe -X utf8 -m formabox check-engines
.\.venv\Scripts\python.exe -X utf8 -B tests/smoke_tools.py
$test = Start-Process -FilePath (Resolve-Path .\Omnora.exe).Path -ArgumentList '--verify-runtime' -PassThru -Wait
$test.ExitCode
```

逐工具实跑中的「阻塞」通常需要补引擎或测试素材。语音转写验收还需 `FORMABOX_TEST_AUDIO` 和 `FORMABOX_TEST_MODEL`。本机默认临时目录遇到权限问题时，可为测试进程指定仓库允许写入的独立临时目录，再复查失败项。

## 找到要改的代码

| 关注点 | 当前入口 |
| --- | --- |
| 桌面界面、任务提交与取消 | [desktop/qml](../../desktop/qml) · [controller.cpp](../../desktop/controller.cpp) |
| 工具清单、引擎探测与预览 | [toolregistry.cpp](../../desktop/toolregistry.cpp) · [engineregistry.cpp](../../desktop/engineregistry.cpp) · [previewservice.cpp](../../desktop/previewservice.cpp) · [tools-manifest.json](../tools-manifest.json) |
| 任务历史与文件提交恢复 | [taskstore.cpp](../../desktop/taskstore.cpp) · [committedoutput.cpp](../../desktop/committedoutput.cpp) · [core.py](../../worker/formabox/core.py) |
| 文件处理协议与回归 | [worker/formabox](../../worker/formabox) · [协议说明](../ARCHITECTURE.md) · [tests](../../tests) |
| Windows 安装与发布 | [installer.nsi](../../packaging/windows/installer.nsi) · [打包脚本](../../scripts/package-windows.ps1) · [安装包验收脚本](../../scripts/test-windows-installer.ps1) · [发布流水线](../../.github/workflows/release-windows.yml) |

## 换 AI 时先对齐范围

给新的维护者仓库地址和具体任务。可以用下面这段话开始。

> 请先读根目录的 AGENTS.md 和 docs/maintenance 下的维护文档，核对当前分支、已经发布的版本和未完成项。按这轮需求做最小改动，完成后记录 Windows 实测结果和下一步。

源码相同版本可从标签检出。任务历史位于本机 `%LOCALAPPDATA%\Omnora\tasks.sqlite`，用户偏好也保存在本机。需要迁移私人数据时，在两台设备之间单独备份。提交到 GitHub 的测试资料应使用公开素材或合成样本。

发布前对齐 CMake 项目版本、worker 模块与包版本、README 和发行说明。发布工作流允许手动触发，主分支改动 `packaging/windows/release-notes.md` 也会触发。它会构建并测试安装包，再发布预览版。发版前先确认用户授权及标签是否已存在。[第三方依赖与分发](../DEPENDENCIES.md)
