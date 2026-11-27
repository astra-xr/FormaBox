# 万象（FormaBox）

万象是一个免费、开源的 Windows 文件工具箱。可以在一个界面里做图片转换与压缩、PDF 合并与拆分、文本整理、批量文件处理，也可以把操作串成工作流。文件在本机处理，无需注册账号。

**当前源码版本为 0.6.0，已发布的 Windows 安装包版本为 0.5.0。** 支持 64 位 Windows 10（1809 及以上）和 Windows 11。

拖入 SRT 或 WebVTT 字幕可以互转格式、按毫秒统一提前或延后，也可以导出纯文本讲稿。三项工具支持批量处理和工作流，直接在本机运行，无需 FFmpeg。

PDF 分类支持批量添加可复制页码、加半透明文字水印、按毫米裁白边。指定页码范围后可单独执行，也可以加入工作流。Windows 可使用系统字体添加中文水印。裁边只修改页面可见范围，底层内容仍在文件中。

0.4.0 的「查看结果」会列出每项输出、文件大小及适用的压缩目标。可打开结果，或勾选后用作当前输入。Windows 安装版可在资源管理器右键选择「发送到 → 万象（FormaBox）」导入选中的文件。

「批量重命名」支持编号与输入顺序调整、文字替换、EXIF 拍摄日期命名。先预览并解决重名，再输出副本。「常用预设」可以整个保存并执行多步工作流。

在 PDF 页面工作台用缩略图调整 PDF 和图片的页序、旋转或移除页面。0.3.0 可在导出时选择「限制导出大小」，查看选中页的压缩前后对照和实际大小，再决定是否保存。

0.3.0 还支持为扫描 PDF 添加可搜索文字层，保留原页面外观。已有可提取文字的页面会跳过。压缩和 OCR 支持未加密的 PDF，每份最多 300 页、256 MiB。扫描 OCR 需要 Tesseract 及相应语言包。

拖入文件后，会根据格式和数量推荐可用操作及匹配的预设。「常用预设」可以保存当前工具参数，也可以直接运行报名照压缩、Word 转 PDF 或扫描 PDF OCR。顶部「引擎设置」可选择 LibreOffice、FFmpeg 和 Tesseract 的可执行文件，使用本地样本测试并保存路径。

## 下载安装

1. 在 [GitHub Release](https://github.com/astra-xr/FormaBox/releases/tag/v0.5.0) 下载 [Windows x64 安装包](https://github.com/astra-xr/FormaBox/releases/download/v0.5.0/FormaBox-0.5.0-Windows-x64-Setup.exe)。
2. 双击安装包，按中文向导选择目录并安装。默认安装到 `%LOCALAPPDATA%\Programs\FormaBox`。升级时需先卸载旧版。
3. 安装完成后，从桌面或开始菜单打开「万象」，也可以直接运行安装目录中的 `FormaBox.exe`。卸载入口在 Windows「设置 → 应用」。

安装包自带 Qt 和 Python 运行环境。它暂未签名，Windows SmartScreen 可能显示未知发布者。可对照 Release 上的 `.sha256` 文件校验下载。

| 用途 | 需要单独安装的引擎 |
| --- | --- |
| 音视频转换、压缩和拼接 | FFmpeg |
| 图片文字识别、扫描 PDF OCR | Tesseract 及所选语言的数据 |
| Word、Excel、PPT 转 PDF | LibreOffice |

无需额外引擎即可使用内置的图片、PDF、文本和文件工具。程序会显示其他功能所缺的依赖。

[路线图](ROADMAP.md) · [测试记录](docs/TESTING.md) · [安全边界](docs/SECURITY.md) · [全部发布版本](https://github.com/astra-xr/FormaBox/releases)

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

需要 Visual Studio 2022 C++ 工具链、CMake 3.21+、Qt 6.5+（建议同一架构的 MSVC 2022 版本）、Python 3.11 或更高版本。Windows 安装包使用 Python 3.13。若使用 Qt 官方安装器，确认安装 Qt Quick / Quick Controls 所需组件。使用有 CMake/MSVC 环境的 PowerShell：

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

项目源码采用 [MIT 许可](LICENSE)。第三方组件的版本与许可见[安装包依赖说明](docs/DEPENDENCIES.md)。
