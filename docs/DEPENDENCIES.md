# 第三方依赖与分发

万象源代码采用 MIT 许可。Windows x64 安装包包含 Qt 6.8.3、CPython、Microsoft Visual C++ v143 运行时及 worker 所需的 Pillow、pypdf、pypdfium2、cryptography、cffi 和 pycparser。构建时从 Qt 套件提取 SPDX 清单，许可证放入安装目录的 `licenses`、`python` 和各 wheel 的元数据目录。Qt 通过动态链接使用，安装包内有适用的 GPL/LGPL 许可证文本和对应源码链接。

[安装包第三方声明](../packaging/windows/THIRD-PARTY-NOTICES.txt) · [运行时依赖版本](../packaging/windows/runtime-requirements.txt)

音视频、OCR 和 Office 转 PDF 分别需要用户单独安装 FFmpeg、带语言数据的 Tesseract 和 LibreOffice。HEIC 扩展仍面向源码开发环境。为这些外部引擎制作任何未来分发版本时，需按实际构建版本核查许可证、编解码器、NOTICE 和源码提供义务。

PyMuPDF 尚未引入。PDF 高级编辑可评估 qpdf、PDFium 等方案。