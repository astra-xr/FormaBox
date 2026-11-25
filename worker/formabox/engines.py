from pathlib import Path
import tempfile
import wave
from zipfile import ZipFile

from PIL import Image, ImageDraw, ImageFont
from pypdf import PdfReader

from .core import Context, find_executable
from .textops import office, office_engine


def test_ffmpeg(ctx, engine):
    result = ctx.path('sample.wav')
    ctx.run([engine, '-nostdin', '-loglevel', 'error', '-f', 'lavfi', '-i',
             'sine=frequency=440:sample_rate=16000:duration=0.2', '-c:a', 'pcm_s16le', result], timeout=15)
    with wave.open(str(result), 'rb') as audio:
        if audio.getnframes() != 3200 or not any(audio.readframes(3200)):
            raise RuntimeError('FFmpeg 未输出有效音频')
    return '音频生成测试通过'


def test_tesseract(ctx, engine):
    langs = set(ctx.run([engine, '--list-langs'], timeout=10).splitlines())
    if 'eng' not in langs:
        raise RuntimeError('缺少英文字库 eng，请在安装目录补齐语言包')
    sample = ctx.path('sample.png')
    with Image.new('RGB', (380, 85), 'white') as image:
        ImageDraw.Draw(image).text((20, 12), 'FORMA BOX', font=ImageFont.load_default(size=42), fill='black')
        image.save(sample)
    language = 'chi_sim+eng' if 'chi_sim' in langs else 'eng'
    text = ctx.run([engine, sample, 'stdout', '-l', language, '--psm', '7'], timeout=12)
    if 'FORMA' not in text.upper():
        raise RuntimeError('Tesseract 未识别出测试文字')
    if 'chi_sim' not in langs:
        return '英文识别通过，简体中文字库 chi_sim 缺失'
    return '中英文字库可用，文字识别测试通过'


def test_office(ctx, _engine):
    path = ctx.path('sample.docx')
    with ZipFile(path, 'w') as archive:
        archive.writestr('[Content_Types].xml',
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
            '</Types>')
        archive.writestr('_rels/.rels',
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
            '</Relationships>')
        archive.writestr('word/document.xml',
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
            '<w:body><w:p><w:r><w:t>FormaBox Engine Test</w:t></w:r></w:p></w:body></w:document>')
    pdf, = office(ctx, [path], {}, timeout=25)
    document = PdfReader(pdf)
    if len(document.pages) != 1 or 'FormaBox Engine Test' not in (document.pages[0].extract_text() or ''):
        raise RuntimeError('转换结果缺少测试文档正文')
    return 'Word 转 PDF 测试通过'


def check_engines():
    engines = (
        ('LibreOffice', office_engine(), test_office),
        ('ffmpeg', find_executable('ffmpeg'), test_ffmpeg),
        ('tesseract', find_executable('tesseract'), test_tesseract),
    )
    results = {}
    for name, path, check in engines:
        ok = False
        message = '未找到可用程序'
        if path:
            try:
                with tempfile.TemporaryDirectory(prefix='formabox-engine-') as temp:
                    message = check(Context(Path(temp), progress=lambda *args, **fields: None), path)
                    ok = True
            except Exception as error:
                message = str(error).strip()[-650:] or '试跑失败'
        results[name] = dict(ok=ok, path=path or '', message=message)
    return results
