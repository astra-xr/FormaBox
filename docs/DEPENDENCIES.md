# 第三方依赖与分发

万象源代码采用 MIT 许可。Windows x64 安装包包含 Qt 6.8.3、CPython、Microsoft Visual C++ v143 运行时及 worker 所需的 Pillow、pypdf、pypdfium2、cryptography、cffi 和 pycparser。构建时从 Qt 套件提取 SPDX 清单，许可证放入安装目录的 `licenses`、`python` 和各 wheel 的元数据目录。Qt 通过动态链接使用，安装包内有适用的 GPL/LGPL 许可证文本和对应源码链接。

[安装包第三方声明](../packaging/windows/THIRD-PARTY-NOTICES.txt) · [运行时依赖版本](../packaging/windows/runtime-requirements.txt)

Windows 发布流程为完整安装包准备 FFmpeg、Tesseract 及中英语言数据、LibreOffice 和 whisper.cpp。Excel 导出使用 openpyxl，7z 处理使用 py7zr。语音模型在第一次需要时单独下载，存放于用户缓存。HEIC 扩展仍面向源码开发环境。

## 随安装包提供引擎

将已核验的完整运行时放入一个引擎目录，再给 `scripts/package-windows.ps1` 传入 `-EngineBundleDirectory <绝对路径>`。生成的安装包文件名以 `-Full-Setup.exe` 结尾。目录应包含：

- `ffmpeg/ffmpeg.exe` 及该构建的许可和所需依赖。
- `tesseract/tesseract.exe`、同目录运行库、`tesseract/tessdata/eng.traineddata`、`tesseract/tessdata/chi_sim.traineddata` 和许可。
- `libreoffice/program/soffice.com`、`soffice.bin`，以及保持相对路径的 LibreOffice 运行时、共享资源和许可声明。
- `whisper/whisper-cli.exe`、同目录的 CPU 运行库及 MIT 许可。模型单独附在 Release。
- `NOTICES.txt`，记录实际版本、来源和对应的再分发资料。

完整安装包把引擎写入万象安装目录下的 `engines`。桌面版检测到完整引擎目录时会直接使用随包附带的程序，并隐藏路径设置。用 `scripts/test-windows-installer.ps1 -Setup <完整安装包> -ExpectBundledEngines` 验证程序实际调用安装目录内的版本及全部工具的实跑结果。语音验收使用 `FORMABOX_TEST_AUDIO` 与 `FORMABOX_TEST_MODEL` 提供公开样本和正式模型，发布流程会自动准备。

可用 `-PrepareOnly` 代替 `-MakeNsis` 来保留待打包目录、卸载清单和对应的 `-Full-Setup.nsi`，再用 NSIS 编译该脚本。

`scripts/stage-windows-engines.ps1` 固定构建输入、核对下载校验值和许可证。FFmpeg 使用经 SHA-256 验证的 BtbN 8.1.2 Windows 构建，其对应的两个源码包随 Release 提供。Tesseract 通过固定 vcpkg 提交静态构建，Release 同时提供源码和构建步骤。LibreOffice 使用官方 26.8.3.1 Windows MSI 解出的原版运行时，保留许可资料。[LibreOffice 对应源码](https://mirrors.ibiblio.org/libreoffice/src/26.8.3/)

PyMuPDF 尚未引入。PDF 高级编辑可评估 qpdf、PDFium 等方案。
