"""Run every registered tool against local files through the desktop CLI protocol."""

import argparse
import csv
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import wave
import zipfile

from PIL import Image, ImageDraw, ImageFont, PngImagePlugin
from pypdf import PdfReader, PdfWriter

from formabox.__main__ import engine_availability
from formabox.core import TOOLS, exe


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8'))


def image_info(path):
    with Image.open(path) as image:
        image.load()
        return image.format, image.size


def image_modified(path):
    with Image.open(path) as image:
        return image.size == (320, 240) and image.convert('RGB').getextrema() != ((255, 255), (0, 0), (0, 0))


def pdf_pages(path):
    return len(PdfReader(path).pages)


def media_test(path, stream):
    subprocess.run([exe('ffmpeg'), '-v', 'error', '-xerror', '-i', str(path),
                    '-map', stream, '-f', 'null', '-'], check=True, capture_output=True)
    return path.stat().st_size > 0


def wav_duration(path):
    with wave.open(str(path), 'rb') as audio:
        return audio.getnframes() / audio.getframerate()


def write_audio_fixture(path, rate, frames, sample):
    with wave.open(str(path), 'wb') as audio:
        audio.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
        audio.writeframes(sample.to_bytes(2, 'little', signed=True) * frames)


def verify_concat(path):
    with wave.open(str(path), 'rb') as audio:
        if (audio.getframerate(), audio.getnchannels(), audio.getnframes()) != (48000, 2, 84000):
            return False
        audio.setpos(24000)
        first = int.from_bytes(audio.readframes(1)[:2], 'little', signed=True)
        audio.setpos(72000)
        second = int.from_bytes(audio.readframes(1)[:2], 'little', signed=True)
        return first > 0 > second


def run_suite(root):
    samples = root / '处理样本 测试'
    samples.mkdir()
    output = root / '转换结果'
    image = samples / '原图.png'
    metadata = PngImagePlugin.PngInfo()
    metadata.add_text('Author', 'Fixture author')
    Image.new('RGB', (320, 240), 'red').save(image, pnginfo=metadata)
    ocr = samples / '有文字.样本.png'
    text_image = Image.new('RGB', (500, 140), 'white')
    ImageDraw.Draw(text_image).text((25, 24), 'HELLO 123', fill='black', font=ImageFont.load_default(56))
    text_image.save(ocr)
    scan_pdf = samples / '扫描文字.pdf'
    text_image.save(scan_pdf, 'PDF')

    pdf = samples / '短文档.pdf'
    writer = PdfWriter()
    writer.add_blank_page(width=200, height=300)
    writer.add_blank_page(width=400, height=300)
    writer.add_metadata({'/Title': 'Fixture title'})
    writer.write(pdf)
    document = samples / '短文档.rtf'
    document.write_text(r'{\rtf1\ansi FormaBox Test}', encoding='ascii')
    captions = samples / '中文 字幕.srt'
    captions.write_text('1\n00:00:01,000 --> 00:00:03,000\n<b>演示字幕</b>\n', encoding='utf-8-sig')

    plain = samples / '示例.txt'
    plain.write_text('中文\n中文\n\nabc\n', encoding='utf-8')
    other = samples / '其他.txt'
    other.write_text('xyz', encoding='utf-8')
    duplicate = samples / '示例 副本.txt'
    duplicate.write_bytes(plain.read_bytes())
    data = samples / '分片.bin'
    data.write_bytes(bytes(range(256)) * 4097)
    raw_json = samples / '数据.json'
    raw_json.write_text('{"a": 1, "b": "中文"}', encoding='utf-8')
    raw_csv = samples / '数据.csv'
    raw_csv.write_text('a,b\n1,中文\n', encoding='utf-8')
    records = samples / '记录.json'
    records.write_text('[{"a":1,"b":"中文"},{"a":2,"b":"=1+2","c":[true]}]', encoding='utf-8')
    empty = samples / '空目录'
    empty.mkdir()
    left = samples / '左'
    right = samples / '右'
    for folder in (left, right):
        folder.mkdir()
        (folder / '对比.txt').write_text(folder.name, encoding='utf-8')

    availability = engine_availability()
    video = samples / '测试视频.mp4'
    first_audio = samples / '01 甲.wav'
    second_audio = samples / '02 乙.flac'
    if availability['ffmpeg']:
        subprocess.run([exe('ffmpeg'), '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=s=160x120:r=15',
                        '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '1', '-c:v', 'libx264',
                        '-c:a', 'aac', str(video)], check=True, capture_output=True)
        write_audio_fixture(first_audio, 32000, 40000, 10000)
        second_wav = second_audio.with_suffix('.wav')
        write_audio_fixture(second_wav, 22050, 11025, -10000)
        subprocess.run([exe('ffmpeg'), '-v', 'error', '-i', str(second_wav), str(second_audio)],
                       check=True, capture_output=True)
    entries = {}

    def check(tool, inputs, verify, params=None):
        declared = TOOLS[tool][0]['engines']
        missing = [engine for engine in declared if not availability[engine]]
        try:
            if not all(inputs):
                raise AssertionError('前置工具未生成结果')
            if 'ffmpeg' in missing:
                entries[tool] = {'status': 'blocked', 'details': '缺少 FFmpeg，无法生成测试视频'}
                return []
            request = dict(tool=tool, inputs=list(map(str, inputs)), output=str(output), params=params or {})
            process = subprocess.run([sys.executable, '-B', '-m', 'formabox', 'run', '--request', '-'],
                                     input=json.dumps(request, ensure_ascii=False).encode('utf-8'),
                                     capture_output=True, timeout=45)
            events = [json.loads(line) for line in process.stdout.decode('utf-8').splitlines()]
            state = events[-1] if events else {}
            if missing:
                assert process.returncode == 1 and state.get('event') == 'error', state
                assert not list(output.glob('.formabox-*')), '失败后仍有暂存目录'
                entries[tool] = {'status': 'blocked', 'details': state['message']}
                return []
            assert process.returncode == 0 and state.get('event') == 'result', state or process.stderr
            paths = [Path(name) for name in state['files']]
            assert paths and all(path.exists() for path in paths), '输出不存在'
            assert verify(paths), '输出内容与预期不一致'
            entries[tool] = {'status': 'passed'}
            return paths
        except Exception as error:
            entries[tool] = {'status': 'failed', 'details': str(error)}
            return []

    pw = {'password': 'FormaBox-smoke-2026'}
    check('image.convert', [image], lambda p: image_info(p[0]) == ('JPEG', (320, 240)))
    check('image.compress', [image], lambda p: p[0].stat().st_size <= 1024, {'target_kib': 1})
    check('image.resize', [image], lambda p: image_info(p[0])[1] == (100, 75), {'width': 100, 'height': 100})
    check('image.transform', [image], lambda p: image_info(p[0])[1] == (240, 320))
    check('image.crop', [image], lambda p: image_info(p[0])[1] == (90, 80), {'width': 90, 'height': 80})
    check('image.stitch', [image, image], lambda p: image_info(p[0])[1] == (320, 480))
    check('image.ocr', [ocr], lambda p: 'HELLO 123' in p[0].read_text(encoding='utf-8'), {'language': 'eng'})
    check('image.watermark', [image], lambda p: image_modified(p[0]))
    check('image.grid', [image, image], lambda p: image_info(p[0])[1] == (288, 288)
          and Image.open(p[0]).getpixel((48, 48)) == (255, 0, 0, 255)
          and Image.open(p[0]).getpixel((48, 192))[3] == 0, {'cell_size': 96, 'background': 'transparent'})

    check('pdf.merge', [pdf, pdf], lambda p: pdf_pages(p[0]) == 4)
    check('pdf.split', [pdf], lambda p: len(p) == 2 and all(pdf_pages(f) == 1 for f in p))
    check('pdf.split_groups', [pdf], lambda p: len(p) == 2 and pdf_pages(p[0]) == 2 and pdf_pages(p[1]) == 1
          and PdfReader(p[0]).pages[0].mediabox.width == 400, {'groups': '2,1|2'})
    check('pdf.select', [pdf], lambda p: PdfReader(p[0]).pages[0].mediabox.width == 400
          and PdfReader(p[0]).pages[0].rotation == 90, {'pages': '2,1', 'rotate': '90'})
    check('pdf.compress', [pdf], lambda p: pdf_pages(p[0]) == 2)
    locked = check('pdf.encrypt', [pdf], lambda p: PdfReader(p[0]).is_encrypted, pw)
    check('pdf.decrypt', locked or [None], lambda p: not PdfReader(p[0]).is_encrypted and pdf_pages(p[0]) == 2, pw)
    check('pdf.text', [pdf], lambda p: 'Page 2' in p[0].read_text(encoding='utf-8'))
    check('pdf.number', [pdf], lambda p: [page.extract_text() for page in PdfReader(p[0]).pages] == ['3', '4'],
          {'start': 3})
    check('pdf.watermark', [pdf], lambda p: [len(page.images) for page in PdfReader(p[0]).pages] == [1, 0],
          {'text': 'DRAFT', 'pages': '1'})
    check('pdf.crop', [pdf], lambda p: 170 < PdfReader(p[0]).pages[0].cropbox.width < 173)
    check('pdf.render', [pdf], lambda p: len(p) == 2 and image_info(p[0]) == ('PNG', (400, 600)))
    check('pdf.from_images', [image, image], lambda p: pdf_pages(p[0]) == 2)
    check('pdf.compose', [pdf, image],
          lambda p: pdf_pages(p[0]) == 2 and PdfReader(p[0]).pages[0].rotation == 90,
          {'pages': json.dumps([dict(source=0, page=1, rotation=90), dict(source=1, page=0, rotation=0)])})
    check('pdf.compress_target', [pdf], lambda p: pdf_pages(p[0]) == 2 and p[0].stat().st_size <= 1024,
          {'target_kib': 1})
    check('pdf.ocr', [scan_pdf], lambda p: 'HELLO 123' in PdfReader(p[0]).pages[0].extract_text(),
          {'language': 'eng'})

    check('video.convert', [video], lambda p: media_test(p[0], '0:v:0'), {'format': 'webm'})
    check('video.compress', [video], lambda p: media_test(p[0], '0:v:0'), {'height': 80, 'fps': 10})
    check('video.trim', [video], lambda p: media_test(p[0], '0:v:0'), {'start': .1, 'duration': .5})
    check('video.gif', [video], lambda p: image_info(p[0])[0] == 'GIF' and Image.open(p[0]).n_frames > 1,
          {'duration': .5, 'width': 80})
    check('video.snapshot', [video], lambda p: image_info(p[0]) == ('PNG', (160, 120)), {'time': .2})
    check('subtitle.convert', [captions], lambda p: p[0].suffix == '.vtt' and
          '00:00:01.000 --> 00:00:03.000\n<b>演示字幕</b>' in p[0].read_text(encoding='utf-8'))
    check('subtitle.shift', [captions], lambda p: p[0].suffix == '.srt' and
          '00:00:00,250 --> 00:00:02,250' in p[0].read_text(encoding='utf-8'), {'offset_ms': -750})
    check('subtitle.transcript', [captions], lambda p: p[0].read_text(encoding='utf-8') == '演示字幕\n')
    check('audio.convert', [video], lambda p: media_test(p[0], '0:a:0'), {'format': 'flac'})
    check('audio.trim', [video], lambda p: .45 < wav_duration(p[0]) < .55, {'start': .1, 'duration': .5})
    check('audio.volume', [video], lambda p: wav_duration(p[0]) > .9, {'db': -10, 'normalize': True})
    check('audio.denoise', [video], lambda p: wav_duration(p[0]) > .9)
    check('audio.concat', [first_audio, second_audio], lambda p: len(p) == 1 and verify_concat(p[0]))
    check('audio.split', [first_audio, second_audio], lambda p: [wav_duration(f) for f in p] == [1, .25, .5],
          {'seconds': 1})

    check('file.hash', [plain], lambda p: read_json(p[0])[0]['match'],
          {'expected': hashlib.sha256(plain.read_bytes()).hexdigest()})
    check('file.duplicates', [plain, duplicate], lambda p: len(read_json(p[0])[0]['files']) == 2)
    check('file.rename', [plain], lambda p: p[0].name == 'file-0001.txt' and p[0].read_bytes() == plain.read_bytes())
    check('file.large', [plain, other], lambda p: len(read_json(p[0])) == 2, {'limit_mib': 0})
    check('file.empty_dirs', [samples], lambda p: read_json(p[0]) == [str(empty)])
    check('file.identify', [pdf], lambda p: read_json(p[0])[0]['signature'] == 'PDF')
    parts = check('file.split', [data], lambda p: len(p) == 3 and len(read_json(p[0])['parts']) == 2, {'size_mib': 1})
    check('file.join', parts[:1] or [None], lambda p: p[0].read_bytes() == data.read_bytes())
    archive = check('file.zip', [plain], lambda p: zipfile.is_zipfile(p[0]))
    check('file.unzip', archive or [None], lambda p: next(p[0].iterdir()).read_bytes() == plain.read_bytes())
    check('file.compare', [left, right], lambda p: read_json(p[0])['changed'] == ['对比.txt'])
    check('file.classify', [plain, pdf], lambda p: [f.parent.name for f in p] == ['txt', 'pdf'])

    check('text.encoding', [plain], lambda p: p[0].read_bytes().decode('gb18030').startswith('中文'), {'target': 'gb18030'})
    check('text.clean', [plain], lambda p: p[0].read_text(encoding='utf-8') == '中文\nabc\n')
    check('text.replace', [plain], lambda p: '新的文本' in p[0].read_text(encoding='utf-8'), {'find': 'abc', 'replace': '新的文本'})
    check('text.diff', [plain, other], lambda p: '+xyz\n\\ No newline' in p[0].read_text(encoding='utf-8'))
    check('text.stats', [plain], lambda p: read_json(p[0])[0]['lines'] == 4)
    check('data.json', [raw_json], lambda p: p[0].read_text(encoding='utf-8') == '{"a":1,"b":"中文"}', {'compact': True})
    check('data.csv_json', [raw_csv], lambda p: read_json(p[0]) == [{'a': '1', 'b': '中文'}])
    check('data.json_csv', [records], lambda p: list(csv.reader(p[0].read_text(encoding='utf-8-sig').splitlines()))
          == [['a', 'b', 'c'], ['1', '中文', ''], ['2', "'=1+2", '[true]']])
    check('doc.pdf', [document], lambda p: pdf_pages(p[0]) == 1 and 'FormaBox' in PdfReader(p[0]).pages[0].extract_text())

    encrypted = check('privacy.encrypt', [data], lambda p: p[0].read_bytes().startswith(b'FBXENC\x01'), pw)
    check('privacy.decrypt', encrypted or [None], lambda p: p[0].read_bytes() == data.read_bytes(), pw)
    check('privacy.image_clean', [image], lambda p: not Image.open(p[0]).info)
    check('privacy.image_info', [image], lambda p: 'Author' in read_json(p[0])[0]['metadata_keys'])
    check('privacy.image_redact', [image], lambda p: Image.open(p[0]).getpixel((2, 2)) == (0, 0, 0, 255)
          and Image.open(p[0]).getpixel((200, 200)) == (255, 0, 0, 255))

    assert set(entries) == TOOLS.keys(), f'未覆盖的工具: {TOOLS.keys() - entries.keys()}'
    assert plain.read_text(encoding='utf-8') == '中文\n中文\n\nabc\n' and image_info(image) == ('PNG', (320, 240))
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path)
    parser.add_argument('--scratch', type=Path, help='在指定目录下创建临时测试文件')
    args = parser.parse_args()
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    with tempfile.TemporaryDirectory(prefix='formabox-test-',dir=args.scratch) as temporary:
        entries = run_suite(Path(temporary).resolve())
    counts = {status: sum(entry['status'] == status for entry in entries.values())
              for status in ('passed', 'blocked', 'failed')}
    if args.report:
        args.report.write_text(json.dumps({'summary': counts, 'tools': entries}, indent=2, ensure_ascii=False), encoding='utf-8')
    for tool, entry in entries.items():
        print(f"{entry['status']:7} {tool} {entry.get('details', '')}")
    print(counts)
    return 1 if counts['failed'] else 2 if counts['blocked'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
