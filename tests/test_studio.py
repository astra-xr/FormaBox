"""Regressions for previews, verified size limits and durable results."""
from contextlib import closing
import json
from pathlib import Path
import tarfile
import wave

from PIL import Image, ImageDraw, ImageFont
from openpyxl import load_workbook
import pypdfium2
import pytest
from pypdf import PdfReader, PdfWriter
from pypdf.generic import DecodedStreamObject, DictionaryObject, NameObject

from formabox.core import Cancelled, Context, execute, find_executable
from formabox.__main__ import engine_availability
from formabox.studio_preview import preview_tool


def run(tmp, tool, inputs, **params):
    result = execute(dict(tool=tool, inputs=[str(p) for p in inputs], params=params, output=str(tmp/'导出')),
                     lambda *a, **k: None)
    return [Path(p) for p in result['files']]


def preview(tmp, tool, inputs, params=None, **options):
    output = tmp/'预览'
    output.mkdir(exist_ok=True)
    return preview_tool(dict(tool=tool, inputs=list(map(str, inputs)), output=str(output),
                             params=params or {}, **options))


def pdf_with_rows(path):
    writer = PdfWriter()
    page = writer.add_blank_page(400, 280)
    font = writer._add_object(DictionaryObject({
        NameObject('/Type'): NameObject('/Font'), NameObject('/Subtype'): NameObject('/Type1'),
        NameObject('/BaseFont'): NameObject('/Helvetica')
    }))
    page[NameObject('/Resources')] = DictionaryObject({
        NameObject('/Font'): DictionaryObject({NameObject('/F1'): font})
    })
    data = DecodedStreamObject()
    data.set_data(b'BT /F1 15 Tf 35 235 Td (Name) Tj 140 0 Td (Score) Tj ET\n'
                  b'BT /F1 15 Tf 35 200 Td (ALICESECRET) Tj 140 0 Td (=1+9) Tj ET\n')
    page[NameObject('/Contents')] = writer._add_object(data)
    writer.add_attachment('secret.txt', b'ATTACHMENT-SECRET')
    writer.add_metadata({'/Title': 'PRIVATE-DATA'})
    writer.write(path)


def test_photo_preview_and_output(tmp_path):
    source = tmp_path/'证件照片.png'
    Image.new('RGB', (600, 740), '#124789').save(source)
    prepared = preview(tmp_path, 'image.id_photo', [source], {'target_kib': '97'}, purpose='evaluate')
    assert prepared['photoSize'] == [295, 413] and prepared['jpegBytes'] <= 97*1024
    photo, paper = run(tmp_path, 'image.id_photo', [source], region='0.1,0.1,0.8,0.8')
    assert Image.open(photo).size == (295, 413)
    assert tuple(PdfReader(paper).pages[0].mediabox)[2:] == (432, 288)


def test_pdf_tables_and_redaction(tmp_path):
    source = tmp_path/'带附件的表格.pdf'
    pdf_with_rows(source)
    settings = {'region': '0.04,0.08,0.71,0.30'}
    shown = preview(tmp_path, 'pdf.table_xlsx', [source], settings, purpose='evaluate')
    assert shown['cells'] == [['Name', 'Score'], ['ALICESECRET', '=1+9']]
    table, = run(tmp_path, 'pdf.table_xlsx', [source], **settings)
    book = load_workbook(table, read_only=True)
    try:
        assert [list(row) for row in book.active.values] == shown['cells']
        assert book.active['B2'].data_type == 's'
    finally:
        book.close()
    redacted, = run(tmp_path, 'pdf.redact', [source], regions='[{"page":1,"region":[0.07,0.20,0.35,0.12]}]')
    assert not PdfReader(redacted).pages[0].extract_text()
    assert not PdfReader(redacted).attachments
    assert b'ALICESECRET' not in redacted.read_bytes() and b'PRIVATE-DATA' not in redacted.read_bytes()
    with closing(pypdfium2.PdfDocument(str(redacted))) as doc, closing(doc[0]) as page, closing(page.render()) as bitmap:
        assert bitmap.to_pil().convert('RGB').getpixel((50, 75)) == (0, 0, 0)
    report, = run(tmp_path, 'pdf.compare', [source, redacted])
    assert 'href="#d1"' in report.read_text(encoding='utf-8')


def test_blank_scan_confirmation(tmp_path):
    paper = tmp_path/'讲义.png'
    blank = tmp_path/'空白.png'
    with Image.new('RGB', (450, 200), 'white') as image:
        image.save(blank)
        ImageDraw.Draw(image).text((30, 45), 'FORMABOX NOTES', font=ImageFont.load_default(size=41), fill='black')
        image.save(paper)
    previewed = preview(tmp_path, 'pdf.clean_scan', [paper, blank])
    assert [row['blank'] for row in previewed['rows']] == [False, True]
    result, = run(tmp_path, 'pdf.clean_scan', [paper, blank], remove='2', ocr='false')
    assert len(PdfReader(result).pages) == 1


def test_archive_preview_partial_extract_and_links(tmp_path):
    source = tmp_path/'内容'
    source.mkdir()
    (source/'甲.txt').write_text('甲', encoding='utf-8')
    (source/'乙.txt').write_text('乙', encoding='utf-8')
    for operation in ('创建 7z', '创建 TAR', '创建 TAR.GZ'):
        archive, = run(tmp_path, 'file.archive', [source], operation=operation)
        listing = preview(tmp_path, 'file.archive', [archive])
        assert {row['name'] for row in listing['rows']} == {'甲.txt', '乙.txt'}
        unpacked, = run(tmp_path, 'file.archive', [archive], selected='["乙.txt"]')
        assert [f.name for f in unpacked.iterdir()] == ['乙.txt']
        assert (unpacked/'乙.txt').read_text(encoding='utf-8') == '乙'
    gz, = run(tmp_path, 'file.archive', [source/'甲.txt'], operation='创建 GZ')
    unpacked, = run(tmp_path, 'file.archive', [gz])
    assert (unpacked/'甲.txt').read_text(encoding='utf-8') == '甲'
    malformed = tmp_path/'link.tar'
    item = tarfile.TarInfo('shortcut')
    item.type, item.linkname = tarfile.SYMTYPE, 'other'
    with tarfile.open(malformed, 'w') as fixture:
        fixture.addfile(item)
    with pytest.raises(ValueError, match='链接'):
        preview(tmp_path, 'file.archive', [malformed])


def test_folder_resume_skips_completed_file(tmp_path):
    source = tmp_path/'输入'
    source.mkdir()
    (source/'子文件夹').mkdir()
    for path in (source/'a.png', source/'子文件夹'/'b.png'):
        Image.new('RGB', (90, 80), 'teal').save(path)
    previewed = preview(tmp_path, 'folder.batch', [source])
    assert {row['name'] for row in previewed['rows']} == {'a.png', '子文件夹/b.png'}
    cancel = tmp_path/'cancel'
    request = dict(tool='folder.batch', inputs=[str(source)], output=str(tmp_path/'导出'), cancel=str(cancel),
                   params={'session': 'a'*32, 'fingerprint': previewed['fingerprint']})
    def stop(event, current, **fields):
        if current == 1:
            cancel.touch()
    with pytest.raises(Cancelled):
        execute(request, stop)
    first, = list((tmp_path/'导出').rglob('*.jpg'))
    saved = first.stat().st_mtime_ns
    cancel.unlink()
    results, report = map(Path, execute(request, lambda *a, **k: None)['files'])
    summary = json.loads(report.read_text(encoding='utf-8'))
    assert summary == {'completed': 1, 'resumed': 1, 'failures': []}
    assert first.stat().st_mtime_ns == saved
    assert len(list((results/'子文件夹').rglob('*.jpg'))) == 1


@pytest.mark.skipif(not engine_availability()['ffmpeg'], reason='FFmpeg dependency unavailable')
def test_video_target_reencodes_and_silence_edits(tmp_path):
    from subprocess import run as subprocess_run
    from formabox.studio_media import probe
    video = tmp_path/'源片段.mkv'
    subprocess_run([find_executable('ffmpeg'), '-v', 'error', '-f', 'lavfi', '-i',
                    'testsrc2=s=640x360:r=24', '-t', '2', '-c:v', 'libx264', '-crf', '12', str(video)], check=True)
    result, = run(tmp_path, 'video.target_size', [video], target_mib='.12', height='144')
    assert result.stat().st_size <= .12*1024**2
    assert probe(Context(tmp_path), result, 'v')[0] > 1.95
    wave_file = tmp_path/'停顿.wav'
    with wave.open(str(wave_file), 'wb') as audio:
        audio.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        audio.writeframes(b'\x33\x33'*8000 + b'\0\0'*16000 + b'\x33\x33'*8000)
    spans = preview(tmp_path, 'audio.silence', [wave_file])['rows']
    assert len(spans) == 1 and abs(spans[0]['start']-.5) < .1
    shortened, _ = run(tmp_path, 'audio.silence', [wave_file], mode='缩短选中', selected='[0]', keep='.25')
    with wave.open(str(shortened)) as audio:
        assert 1.18 < audio.getnframes()/audio.getframerate() < 1.35
