## 万象 0.9.4

- **覆盖升级**。关闭万象后运行安装包即可沿原目录升级。安装器先暂存新文件、备份被替换的组件，再验证新版能启动。失败时恢复旧文件，中断后可以重新运行安装器恢复。设置、预设、任务历史和用户文件保存在原处。
- **进程回收**。Windows 上的任务、预览及引擎探测使用独立进程组。任务先尝试协作取消，超过 5 秒再终止该组。任务历史区分启动失败、取消超时、引擎超时和进程崩溃。
- **安装日志**。安装、启动验证和回滚阶段记录在 `%LOCALAPPDATA%\Omnora\installer.log`。

下载 `Omnora-0.9.4-Windows-x64-Full-Setup.exe`，双击进入中文安装向导。支持 Windows 10（1809 及以上）和 Windows 11 x64。可使用同页的 SHA-256 校验文件核对下载。

完整安装包内置 Qt、Python、FFmpeg、Tesseract（含英文和简体中文语言包）、LibreOffice 及 whisper.cpp。语音转写的模型约 75 MiB，首次使用可勾选下载，之后可离线运行。音视频文件在本机处理。

安装目录的 `engines/NOTICES.txt` 列有内置引擎出处和许可证。FFmpeg 与 Tesseract 对应源码附件供开发者查阅，LibreOffice 26.8.3.1 的源码见其上游镜像。[LibreOffice 源码目录](https://mirrors.ibiblio.org/libreoffice/src/26.8.3/)
