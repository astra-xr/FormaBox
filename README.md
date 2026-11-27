# 万象（FormaBox）

万象是一个免费、开源的 Windows 文件工具箱。可以在一个界面里做图片转换与压缩、PDF 合并与拆分、文本整理、批量文件处理，也可以把操作串成工作流。文件在本机处理，无需注册账号。

**当前版本为 0.8.0（Windows 完整预览版）。** 支持 64 位 Windows 10（1809 及以上）和 Windows 11。

## 下载安装

1. 在 [GitHub Release](https://github.com/astra-xr/FormaBox/releases/tag/v0.8.0) 下载 [Windows x64 完整安装包](https://github.com/astra-xr/FormaBox/releases/download/v0.8.0/FormaBox-0.8.0-Windows-x64-Full-Setup.exe)。
2. 双击安装包，按中文向导选择目录并安装。默认安装到 `%LOCALAPPDATA%\Programs\FormaBox`。升级时需先卸载旧版。
3. 安装完成后，从桌面或开始菜单打开「万象」，也可以直接运行安装目录中的 `FormaBox.exe`。卸载入口在 Windows「设置 → 应用」。

**完整包内置 Qt、Python、FFmpeg 8.1.2、Tesseract 5.5.4（英文和简体中文语言包）及 LibreOffice 26.8.3.1。** 装一次万象即可使用音视频转换、图片和扫描 PDF OCR、Word / Excel / PPT 转 PDF，无需单独安装或手动配置引擎。

安装包暂未签名，Windows SmartScreen 可能显示未知发布者。可使用 Release 的 `.sha256` 文件核对下载。对应源码附件供开发者查阅，日常使用下载完整安装包即可。

## 使用万象

首页默认显示 12 个常用工具。左栏按图片、PDF、视频、音频、文档与数据、文件与隐私分类。「全部工具」可浏览完整列表，搜索框始终查找所有工具。

拖入文件后，万象会推荐适用的操作和预设。任务中心和工作流可以收起，开始新任务或添加工作流步骤时会自动展开。右上角可切换浅色、深色或跟随系统。主界面和弹窗的按钮都采用柔和的随鼠标反光。

- **图片与文档**。转换、压缩图片或识别中英文。可以从「常用预设」压缩报名照，也可以直接把 Word、Excel 或 PPT 转成 PDF。
- **PDF**。合并、拆分、加页码、加文字水印或裁白边。页面工作台支持拖动排序、旋转、移除和插入页面，也可以在导出前按目标大小预览压缩结果。扫描件 OCR 可保留页面外观并添加可搜索文字层。压缩和 OCR 支持未加密的 PDF，每份最多 300 页、256 MiB。裁白边保留底层内容。
- **音视频与字幕**。转换、压缩、裁剪，或按间隔批量抽取 PNG 帧。SRT 和 WebVTT 可互转、平移时间或导出纯文本。
- **批量文件**。可按序号、替换文字或 EXIF 拍摄时间预览重命名，再输出副本。任务结果可打开或重新用作输入。也可在资源管理器右键选择「发送到 → 万象（FormaBox）」导入文件。

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

## 从源码开发

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
