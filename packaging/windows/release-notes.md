## 万象 0.9.3

- **任务历史**。使用本地 SQLite 保存任务状态、每次执行记录和输出文件。首启迁移旧版历史和批处理续跑记录，普通任务失败后可从任务中心重试。
- **中断恢复**。程序在文件提交后意外退出时，下次启动会核对产物并补回完成记录。仍在暂存中的任务会保留「已中断」状态。
- **预览与引擎**。PDF 分批导入保留已有缩略图，压缩预览可以直接保存。工具清单、引擎诊断和 worker 错误码统一维护，延续 79 项工具。

下载 `Omnora-0.9.3-Windows-x64-Full-Setup.exe`，双击进入中文安装向导。支持 Windows 10（1809 及以上）和 Windows 11 x64。已有旧版需先卸载。可使用同页的 SHA-256 校验文件核对下载。

完整安装包内置 Qt、Python、FFmpeg、Tesseract（含英文和简体中文语言包）、LibreOffice 及 whisper.cpp。语音转写的模型约 75 MiB，首次使用可勾选下载，之后可离线运行。音视频文件在本机处理。

安装目录的 `engines/NOTICES.txt` 列有内置引擎出处和许可证。FFmpeg 与 Tesseract 对应源码附件供开发者查阅，LibreOffice 26.8.3.1 的源码见其上游镜像。[LibreOffice 源码目录](https://mirrors.ibiblio.org/libreoffice/src/26.8.3/)
