# 万象（FormaBox）

万象是一个免费、开源的 Windows 文件工具箱。可以在一个界面里做图片转换与压缩、PDF 合并与拆分、文本整理、批量文件处理，也可以把操作串成工作流。文件在本机处理，无需注册账号。

**当前版本为 0.2.0（Windows 预览版）。** 支持 64 位 Windows 10（1809 及以上）和 Windows 11。

0.2.0 增加 PDF 页面工作台。用真实缩略图调整 PDF 和图片的页序、旋转或移除页面，再导出到任务输出目录。一次最多编辑 32 个文件、300 页，支持未加密 PDF 和单帧图片。

拖入文件后，会根据格式和数量推荐可用操作。顶部「引擎设置」可选择 LibreOffice、FFmpeg 和 Tesseract 的可执行文件，使用本地样本测试并保存路径。

## 下载安装

1. 在 [GitHub Release](https://github.com/astra-xr/FormaBox/releases/tag/v0.2.0) 下载 [Windows x64 安装包](https://github.com/astra-xr/FormaBox/releases/download/v0.2.0/FormaBox-0.2.0-Windows-x64-Setup.exe)。
2. 双击安装包，按中文向导选择目录并安装。默认安装到 `%LOCALAPPDATA%\Programs\FormaBox`。
3. 安装完成后，从桌面或开始菜单打开「万象」，也可以直接运行安装目录中的 `FormaBox.exe`。卸载入口在 Windows「设置 → 应用」。

安装包自带 Qt 和 Python 运行环境。它暂未签名，Windows SmartScreen 可能显示未知发布者。可对照 Release 上的 `.sha256` 文件校验下载。

| 用途 | 需要单独安装的引擎 |
| --- | --- |
| 音视频转换、压缩和拼接 | FFmpeg |
| 图片文字识别 | Tesseract 及所选语言的数据 |
| Word、Excel、PPT 转 PDF | LibreOffice |

无需额外引擎即可使用内置的图片、PDF、文本和文件工具。程序会显示其他功能所缺的依赖。

## 项目结构

```
CMakeLists.txt           Qt 桌面构建
 desktop/                C++ 控制器 + QML 界面
 worker/formabox/        独立文件处理进程及工具注册表
 worker/pyproject.toml   Python 依赖与 CLI
 tests/                  真实文件夹具与安全回归测试
 scripts/                开发构建脚本
 docs/                   架构、测试、安全、第三方依赖
 .github/workflows/      持续集成和 Windows 安装包发布
 AGENTS.md               Codex 接手约定
 ROADMAP.md              完整目标与实际实现状态
```

## Windows 开发运行

需要 Visual Studio 2022 C++ 工具链、CMake 3.21+、Qt 6.5+（建议同一架构的 MSVC 2022 版本）、Python 3.11 或 3.12。若使用 Qt 官方安装器，确认安装 Qt Quick / Quick Controls 所需组件。使用有 CMake/MSVC 环境的 PowerShell：

```powershell
# 仅测试后端
.\scripts\build-windows.ps1 -TestOnly
# 测试、编译、安装开发构建（按实际 Qt 路径修改）
.\scripts\build-windows.ps1 -QtPrefix 'C:\Qt\6.8.3\msvc2022_64'
.\FormaBox.exe
```

FFmpeg、Tesseract（含所需语言包，例如 eng / chi_sim）可通过 PATH 检测。万象会自动查找 Windows 默认安装位置的 LibreOffice。自定义目录可通过 `FORMABOX_SOFFICE` 指定 `soffice.com` 或 `soffice.exe` 的绝对路径，配置后重开万象。开发版可把 ffmpeg 等可执行文件放在 `dist/engines`，同时准备其运行时依赖。构建脚本支持 `-Python` 指定创建虚拟环境的 Python，`-Wheelhouse` 使用本地 wheel，`-WithHeic` 启用可选 HEIC 扩展。

Qt 桌面程序优先使用 `FORMABOX_PYTHON` 指定的 Python，也可查找 `python/python.exe`、与 `dist` 同级的 `.venv` 和系统 Python。构建脚本会在当前 PowerShell 环境设置 Python 和工作进程路径。

## 仅运行后端（已验证）

```bash
python -m pip install -e './worker[test]'
python -m formabox list
python -m formabox doctor
python -m formabox run --request request.json
python -m pytest -q -ra tests
python tests/smoke_tools.py
```

`request.json` 示例（请修改实际路径）：

```json
{
  "tool": "image.compress",
  "inputs": ["C:/Pictures/demo.png"],
  "output": "C:/Users/Me/Documents/FormaBox Output",
  "params": {"format": "jpg", "quality": "85", "target_kib": "100"}
}
```

也可用 `run --request -` 从 UTF-8 stdin 读取（桌面端采用此方式，密码不经命令行参数）。不要把包含密码的请求写入文件或提交 Git。

工作流请求用 `steps` 替代 `tool` 与 `params`，如：

```json
{"inputs":["input.png"],"output":"output","steps":[{"tool":"image.resize","params":{"width":1000,"height":1000}},{"tool":"image.convert","params":{"format":"webp"}}]}
```

工作流为线性传递前一步所有输出，尚不支持分支、文件夹监听与类型匹配。输出目录中保留中间步骤。请先用副本测试。

## 产品与安全边界

当前为独立进程，不等同于 OS 安全沙箱。处理不可信文件前仍需建立 OS 级隔离、文件与网络权限控制和安全更新机制。高级 AI、复杂 PDF 编辑、无损多帧处理、完整 Office 互转、右键扩展及真正的跨平台发布均尚未完成。不要将这个包宣传为安全审计通过或生产级稳定版。

项目代码暂定 MIT，第三方组件遵循各自许可；分发前必须完成实际许可证和二进制来源审核。
