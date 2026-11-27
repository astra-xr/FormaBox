## 万象 0.9.0

- **图片与 PDF**。报名照和 6 英寸冲印排版、框选 OCR、扫描件纠偏和去边、PDF 版本对照、规则表格转 Excel、重新渲染式永久遮盖。
- **音视频**。目标大小压缩、带切点预览的剪切拼接、缩略图总览、静音试听与删除或缩短、本地语音转 TXT 和 SRT。
- **批量处理**。文件夹预览、分文件提交与重启续跑、7z/TAR/GZ 浏览和按成员提取、首页常用工具可排序。
- **资源管理器**。右键「发送到」可直接执行 Office 转 PDF 或把所选图片压到 100 KiB。

下载 `FormaBox-0.9.0-Windows-x64-Full-Setup.exe`，双击进入中文安装向导。支持 Windows 10（1809 及以上）和 Windows 11 x64。已有旧版需先卸载。可使用同页的 SHA-256 校验文件核对下载。

完整安装包内置 Qt、Python、FFmpeg、Tesseract（含英文和简体中文语言包）、LibreOffice 及 whisper.cpp。语音转写的模型约 75 MiB，首次使用可勾选下载，之后可离线运行。音视频文件在本机处理。

安装目录的 `engines/NOTICES.txt` 列有内置引擎出处和许可证。FFmpeg 与 Tesseract 对应源码附件供开发者查阅，LibreOffice 26.8.3.1 的源码见其上游镜像。[LibreOffice 源码目录](https://mirrors.ibiblio.org/libreoffice/src/26.8.3/)
