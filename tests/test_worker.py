import hashlib,json,os,subprocess,sys,zipfile,shutil
from contextlib import closing
import random
from pathlib import Path
import pytest
from PIL import Image, ImageDraw, ImageFont
from pypdf import PdfReader,PdfWriter
from formabox.core import execute,Cancelled,TOOLS
from formabox import imageops,pdfops,mediaops,fileops,textops,privacyops

def run(tmp,tool,inputs,params=None):
    return execute(dict(tool=tool,inputs=[str(i) for i in inputs],params=params or {},output=str(tmp/'out')),lambda *a,**kw:None)
def result(r):return Path(r['files'][0])
@pytest.fixture
def img(tmp_path):
    p=tmp_path/'中文.png'; Image.new('RGB',(320,240),'red').save(p);return p
@pytest.fixture
def pdf(tmp_path):
    p=tmp_path/'sample.pdf'; w=PdfWriter();w.add_blank_page(width=200,height=300);w.add_blank_page(width=400,height=300);w.write(p);return p

def test_manifest():
    manifest=Path(__file__).resolve().parents[1]/'docs'/'tools-manifest.json'
    assert json.loads(manifest.read_text(encoding='utf-8'))==[spec for spec,_ in TOOLS.values()]
def test_image_convert(tmp_path,img):
    p=result(run(tmp_path,'image.convert',[img])); assert Image.open(p).format=='JPEG' and img.exists()
def test_target(tmp_path,img):
    p=result(run(tmp_path,'image.compress',[img],{'target_kib':1})); assert p.stat().st_size<=1024
@pytest.mark.parametrize('tool,params,size',[('image.resize',{'width':100,'height':100},(100,75)),('image.transform',{'rotate':'90'},(240,320)),('image.crop',{'width':80,'height':50},(80,50)),('image.watermark',{},(320,240)),('privacy.image_clean',{},(320,240)),('privacy.image_redact',{},(320,240))])
def test_images(tmp_path,img,tool,params,size):
    p=result(run(tmp_path,tool,[img],params)); assert Image.open(p).size==size
    if tool=='privacy.image_redact':assert Image.open(p).getpixel((1,1))==(0,0,0,255)
def test_stitch(tmp_path,img):
    assert Image.open(result(run(tmp_path,'image.stitch',[img,img]))).size==(320,480)
def test_metadata(tmp_path,img):
    assert json.loads(result(run(tmp_path,'privacy.image_info',[img])).read_text())[0]['format']=='PNG'
def test_pdf(tmp_path,pdf,img):
    assert len(PdfReader(result(run(tmp_path,'pdf.merge',[pdf,pdf]))).pages)==4
    assert len(run(tmp_path,'pdf.split',[pdf])['files'])==2
    p=result(run(tmp_path,'pdf.select',[pdf],{'pages':'2,1','rotate':'90'})); r=PdfReader(p);assert r.pages[0].mediabox.width==400 and r.pages[0].rotation==90
    assert len(PdfReader(result(run(tmp_path,'pdf.compress',[pdf]))).pages)==2
    assert len(PdfReader(result(run(tmp_path,'pdf.from_images',[img,img]))).pages)==2
    assert len(run(tmp_path,'pdf.render',[pdf])['files'])==2
    assert 'Page 2' in result(run(tmp_path,'pdf.text',[pdf])).read_text()
def test_pdf_password(tmp_path,pdf):
    e=result(run(tmp_path,'pdf.encrypt',[pdf],{'password':'secret123'}));assert PdfReader(e).is_encrypted
    d=result(run(tmp_path,'pdf.decrypt',[e],{'password':'secret123'}));assert not PdfReader(d).is_encrypted and len(PdfReader(d).pages)==2
    with pytest.raises(ValueError):run(tmp_path,'pdf.decrypt',[e],{'password':'wrong'})


def test_workbench_thumbnails_and_export(tmp_path, pdf, img):
    from formabox.pdfworkbench import preview_pages

    before = pdf.read_bytes()
    thumbnails = tmp_path / '缩略图'
    thumbnails.mkdir()
    request = dict(inputs=[str(pdf), str(img)], limit=3, output=str(thumbnails))
    previews = preview_pages(request)
    assert [(row['source'], row['page']) for row in previews] == [(0, 0), (0, 1), (1, 0)]
    for row in previews:
        with Image.open(thumbnails / row['thumbnail']) as thumbnail:
            assert thumbnail.format == 'PNG'
            assert thumbnail.width <= 161 and thumbnail.height <= 211
    with Image.open(thumbnails / previews[2]['thumbnail']) as thumbnail:
        assert thumbnail.getpixel((20, 20)) == (255, 0, 0)

    order = [dict(source=0, page=1, rotation=90), dict(source=1, page=0, rotation=0),
             dict(source=0, page=1, rotation=180)]
    output = result(run(tmp_path, 'pdf.compose', [pdf, img], {'pages': json.dumps(order)}))
    pages = PdfReader(output).pages
    assert [(page.mediabox.width, page.rotation) for page in pages] == [(400, 90), (320, 0), (400, 180)]
    assert pdf.read_bytes() == before
    assert Image.open(img).size == (320, 240)


def test_workbench_limits_and_cleanup(tmp_path, pdf):
    from formabox.pdfworkbench import preview_pages

    thumbnails = tmp_path / 'preview'
    thumbnails.mkdir()
    with pytest.raises(ValueError, match='300'):
        preview_pages(dict(inputs=[str(pdf)], limit=1, output=str(thumbnails)))
    assert not list(thumbnails.iterdir())

    order = json.dumps([dict(source=0, page=0, rotation=90), dict(source=0, page=2, rotation=0)])
    with pytest.raises(ValueError, match='页码超出范围'):
        run(tmp_path, 'pdf.compose', [pdf], {'pages': order})
    assert not list((tmp_path / 'out').iterdir())


def text_page(writer):
    from pypdf.generic import DecodedStreamObject, DictionaryObject, NameObject

    page = writer.add_blank_page(width=220, height=140)
    font = DictionaryObject({NameObject('/Type'): NameObject('/Font'),
                             NameObject('/Subtype'): NameObject('/Type1'),
                             NameObject('/BaseFont'): NameObject('/Helvetica')})
    resources = DictionaryObject({NameObject('/Font'): DictionaryObject({NameObject('/F1'): font})})
    page[NameObject('/Resources')] = resources
    stream = DecodedStreamObject()
    stream.set_data(b'BT /F1 12 Tf 20 45 Td (Digital reference) Tj ET')
    page[NameObject('/Contents')] = stream
    return page


def test_target_pdf_compression_and_preview(tmp_path):
    from formabox.pdfworkbench import preview_compression

    image_pdf = tmp_path / '扫描图.pdf'
    pixels = random.Random(42).randbytes(1000 * 1000 * 3)
    with Image.frombytes('RGB', (1000, 1000), pixels) as image:
        image.save(image_pdf, 'PDF', quality=96)
    mixed = tmp_path / '扫描图和数字文字.pdf'
    writer = PdfWriter()
    writer.append(image_pdf)
    text_page(writer)
    writer.write(mixed)
    original = mixed.read_bytes()
    output = result(run(tmp_path, 'pdf.compress_target', [mixed], {'target_kib': 160}))
    assert output.stat().st_size <= 160 * 1024 < len(original)
    optimized = PdfReader(output)
    assert optimized.pages[1].extract_text() == 'Digital reference'
    assert optimized.pages[0].images[0].image.width < 1000
    assert mixed.read_bytes() == original

    directory = tmp_path / '预览'
    directory.mkdir()
    plan = json.dumps([dict(source=0, page=0, rotation=0), dict(source=0, page=1, rotation=0)])
    preview = preview_compression(dict(inputs=[str(mixed)], pages=plan, output=str(directory),
                                       target_kib=1, page=0))
    assert not preview['met']
    assert 1024 < preview['size'] < preview['original']
    assert preview['size'] == (directory / 'compressed.pdf').stat().st_size
    with Image.open(directory / 'before.png') as before, Image.open(directory / 'after.png') as after:
        assert before.size == after.size
        assert before.tobytes() != after.tobytes()

    with pytest.raises(ValueError, match='未达到'):
        run(tmp_path, 'pdf.compress_target', [mixed], {'target_kib': 1})
    assert not list((tmp_path / 'out').glob('.formabox-*'))


def test_searchable_pdf_keeps_rotated_scan_appearance(tmp_path):
    from formabox.core import find_executable
    import pypdfium2 as pdfium

    if not find_executable('tesseract'):
        pytest.skip('Tesseract unavailable')
    scan = tmp_path / '图片页.pdf'
    with Image.new('RGB', (700, 300), 'white') as image:
        ImageDraw.Draw(image).text((50, 35), 'SEARCHABLE PAGE', fill='black', font=ImageFont.load_default(52))
        image.transpose(Image.Transpose.ROTATE_90).save(scan, 'PDF')
    mixed = tmp_path / '带旋转的扫描件.pdf'
    writer = PdfWriter()
    writer.append(scan)
    writer.pages[0].rotate(90)
    writer.pages[0].cropbox.lower_left = (30, 15)
    text_page(writer)
    writer.write(mixed)
    original = mixed.read_bytes()

    output = result(run(tmp_path, 'pdf.ocr', [mixed], {'language': 'eng'}))
    pages = PdfReader(output).pages
    assert 'SEARCHABLE PAGE' in pages[0].extract_text()
    assert pages[0].rotation == 90
    assert pages[1].extract_text() == 'Digital reference'
    assert mixed.read_bytes() == original

    def pixels(path):
        with closing(pdfium.PdfDocument(str(path))) as document, closing(document[0]) as page:
            with closing(page.render(scale=1)) as bitmap, bitmap.to_pil() as image:
                return image.size, image.tobytes()

    assert pixels(output) == pixels(mixed)


def test_engine_configuration_uses_saved_path(tmp_path, monkeypatch):
    from formabox.core import find_executable

    executable = tmp_path / 'ffmpeg.exe'
    executable.touch()
    monkeypatch.setenv('FORMABOX_FFMPEG', str(executable))
    assert find_executable('ffmpeg') == str(executable)
    monkeypatch.setenv('FORMABOX_FFMPEG', str(tmp_path / 'missing.exe'))
    assert find_executable('ffmpeg') is None

def test_encryption(tmp_path):
    f=tmp_path/'data.bin';f.write_bytes(os.urandom(2**20+35)); pw={'password':'correct horse battery staple'}; e=result(run(tmp_path,'privacy.encrypt',[f],pw)); assert e.read_bytes()!=f.read_bytes()
    assert result(run(tmp_path,'privacy.decrypt',[e],pw)).read_bytes()==f.read_bytes()
    with pytest.raises(ValueError):run(tmp_path,'privacy.decrypt',[e],{'password':'wrong'})
    data=bytearray(e.read_bytes());data[-20]^=1;e.write_bytes(data)
    with pytest.raises(ValueError):run(tmp_path,'privacy.decrypt',[e],pw)
    assert not list((tmp_path/'out').glob('.formabox-*'))
def test_files(tmp_path):
    a=tmp_path/'a.txt';b=tmp_path/'b.txt';a.write_text('abc');b.write_text('abc'); data=json.loads(result(run(tmp_path,'file.duplicates',[a,b])).read_text());assert len(data)==1
    h=json.loads(result(run(tmp_path,'file.hash',[a],{'expected':hashlib.sha256(b'abc').hexdigest()})).read_text());assert h[0]['match']
    assert len(run(tmp_path,'file.rename',[a,b])['files'])==2
    assert len(run(tmp_path,'file.classify',[a,b])['files'])==2
    assert len(json.loads(result(run(tmp_path,'file.large',[a,b],{'limit_mib':0})).read_text()))==2
    assert json.loads(result(run(tmp_path,'file.identify',[a])).read_text())[0]['signature']=='unknown'
def test_split_join(tmp_path):
    p=tmp_path/'data.dat';p.write_bytes(os.urandom(2**20+17));s=run(tmp_path,'file.split',[p],{'size_mib':1});assert len(s['files'])==3
    assert result(run(tmp_path,'file.join',[result(s)])).read_bytes()==p.read_bytes()
    Path(s['files'][1]).write_bytes(b'bad')
    with pytest.raises(ValueError):run(tmp_path,'file.join',[result(s)])
def test_zip(tmp_path):
    p=tmp_path/'hello.txt';p.write_text('hi');z=result(run(tmp_path,'file.zip',[p]));d=result(run(tmp_path,'file.unzip',[z]));assert next(d.iterdir()).read_text()=='hi'

def test_zip_keeps_empty_directories(tmp_path):
    source = tmp_path / '资料'
    (source / 'nested' / 'empty').mkdir(parents=True)
    (source / 'notes.txt').write_text('notes', encoding='utf-8')
    empty = tmp_path / 'empty-input'
    empty.mkdir()

    archive = result(run(tmp_path, 'file.zip', [source, empty]))
    unpacked = result(run(tmp_path, 'file.unzip', [archive]))

    assert (unpacked / '0001-资料' / 'notes.txt').read_text(encoding='utf-8') == 'notes'
    assert (unpacked / '0001-资料' / 'nested' / 'empty').is_dir()
    assert (unpacked / '0002-empty-input').is_dir()

@pytest.mark.parametrize('name',['../escape.txt','/abs.txt','C:/bad','a/../../bad','a\\..\\bad','CON.txt'])
def test_zip_path_traversal(tmp_path,name):
    z=tmp_path/'bad.zip';
    with zipfile.ZipFile(z,'w') as f:f.writestr(name,'bad')
    with pytest.raises(ValueError):run(tmp_path,'file.unzip',[z])
    assert not list((tmp_path/'out').glob('.formabox-*'))
def test_zip_size(tmp_path):
    z=tmp_path/'big.zip';
    with zipfile.ZipFile(z,'w',zipfile.ZIP_DEFLATED) as f:f.writestr('large.txt',b'a'*(1024**2+1))
    with pytest.raises(ValueError):run(tmp_path,'file.unzip',[z],{'max_mib':1})
def test_compare(tmp_path):
    a=tmp_path/'a';b=tmp_path/'b';a.mkdir();b.mkdir();(a/'x').write_text('a');(b/'x').write_text('b'); assert json.loads(result(run(tmp_path,'file.compare',[a,b])).read_text())['changed']==['x']
def test_text(tmp_path):
    a=tmp_path/'a.txt';a.write_text('中文\n中文\n\nabc\n',encoding='utf-8');b=tmp_path/'b.txt';b.write_text('xyz',encoding='utf-8')
    assert result(run(tmp_path,'text.encoding',[a],{'target':'gbk'})).read_bytes().decode('gbk').startswith('中文')
    assert result(run(tmp_path,'text.clean',[a])).read_text(encoding='utf-8')=='中文\nabc\n'
    assert 'xyz' in result(run(tmp_path,'text.replace',[a],{'find':'abc','replace':'xyz'})).read_text(encoding='utf-8')
    assert '+xyz' in result(run(tmp_path,'text.diff',[a,b])).read_text(encoding='utf-8')
    assert json.loads(result(run(tmp_path,'text.stats',[a])).read_text())[0]['lines']==4
    j=tmp_path/'a.json';j.write_text('{"a": 1}');assert result(run(tmp_path,'data.json',[j],{'compact':True})).read_text()=='{"a":1}'
    c=tmp_path/'a.csv';c.write_text('a,b\n1,2');assert json.loads(result(run(tmp_path,'data.csv_json',[c])).read_text())==[{'a':'1','b':'2'}]
def test_workflow(tmp_path,img):
    r=execute({'steps':[{'tool':'image.resize','params':{'width':100,'height':100}},{'tool':'image.convert','params':{'format':'webp'}}],'inputs':[str(img)],'output':str(tmp_path/'out')},lambda *a,**k:None);p=result(r);assert Image.open(p).format=='WEBP' and Image.open(p).size==(100,75)

def test_workflow_progress_across_steps(tmp_path, img):
    second = tmp_path / 'second.png'
    shutil.copyfile(img, second)
    progress = []

    def record(event, current, total, message):
        assert event == 'progress'
        progress.append(current / total)

    execute({'steps': [{'tool': 'image.resize', 'params': {'width': 100, 'height': 100}},
                       {'tool': 'image.convert', 'params': {'format': 'webp'}}],
             'inputs': [str(img), str(second)], 'output': str(tmp_path / 'out')}, record)

    assert progress == sorted(progress)
    assert {0.0, 0.25, 0.5, 0.75} <= set(progress)

def test_cancel(tmp_path,img):
    flag=tmp_path/'cancel';flag.touch()
    with pytest.raises(Cancelled):execute({'tool':'image.convert','inputs':[str(img)],'output':str(tmp_path/'out'),'cancel':str(flag)},lambda *a,**k:None)
    assert not list((tmp_path/'out').iterdir())

def test_invalid_cancel_path_leaves_no_output(tmp_path, img):
    output = tmp_path / 'out'
    with pytest.raises(ValueError, match='取消标记'):
        execute({'tool': 'image.convert', 'inputs': [str(img)], 'output': str(output),
                 'cancel': 123}, lambda *args, **kwargs: None)

    assert not output.exists()

def test_bad_parameter(tmp_path,img):
    with pytest.raises(ValueError):run(tmp_path,'image.resize',[img],{'width':-1})
    with pytest.raises(ValueError):run(tmp_path,'image.convert',[img],{'bogus':1})
    assert img.exists()
def test_inside_input(tmp_path):
    with pytest.raises(ValueError):run(tmp_path,'file.hash',[tmp_path])
def test_cli(tmp_path,img):
    req=dict(tool='image.convert',inputs=[str(img)],output=str(tmp_path/'out')); p=subprocess.run([sys.executable,'-m','formabox','run','--request','-'],input=json.dumps(req),text=True,encoding='utf-8',capture_output=True);assert p.returncode==0 and json.loads(p.stdout.splitlines()[-1])['event']=='result'
@pytest.mark.skipif(not shutil.which('ffmpeg'),reason='FFmpeg unavailable')
def test_media(tmp_path):
    p=tmp_path/'clip.mp4';subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','color=c=blue:s=160x120:r=15','-f','lavfi','-i','sine=frequency=440','-t','1','-c:v','libx264','-c:a','aac',str(p)],check=True)
    for t,params in [('video.convert',{}),('video.compress',{}),('video.trim',{'duration':.5}),('video.gif',{'duration':.5}),('video.snapshot',{}),('audio.convert',{}),('audio.trim',{'duration':.5}),('audio.volume',{}),('audio.denoise',{})]:
        assert result(run(tmp_path,t,[p],params)).stat().st_size>0,t

@pytest.mark.skipif(not shutil.which('ffmpeg'), reason='FFmpeg unavailable')
def test_audio_staging_and_limits(tmp_path, monkeypatch):
    import wave

    good = tmp_path / '完整音轨.wav'
    empty = tmp_path / '空音轨.wav'
    for path, frames in ((good, 96000), (empty, 0)):
        with wave.open(str(path), 'wb') as audio:
            audio.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
            audio.writeframes(b'\x01\x00' * frames)

    output = tmp_path / '结果 100%'
    request = dict(inputs=[str(good)], output=str(output), params={'seconds': 1})
    files = execute(dict(request, tool='audio.split'), lambda *a, **kw: None)['files']
    assert len(files) == 2
    for path in files:
        with wave.open(path, 'rb') as audio:
            assert audio.getnframes() == 48000

    committed = list(output.iterdir())
    with pytest.raises(ValueError, match='需要整数'):
        execute(dict(request, tool='audio.split', params={'seconds': 1.5}))
    monkeypatch.setattr(mediaops, 'MAX_AUDIO_PARTS', 1)
    with pytest.raises(ValueError, match='最多输出'):
        execute(dict(request, tool='audio.split'))
    with pytest.raises(RuntimeError, match='外部工具失败'):
        execute(dict(request, tool='audio.concat', inputs=[str(good), str(empty)], params={}))
    monkeypatch.setattr(mediaops, 'MAX_AUDIO_FRAMES', 144000)
    with pytest.raises(ValueError, match='总时长'):
        execute(dict(request, tool='audio.concat', inputs=[str(good), str(good)], params={}))
    assert list(output.iterdir()) == committed

@pytest.mark.skipif(not shutil.which('tesseract'),reason='Tesseract unavailable')
def test_ocr(tmp_path):
    from PIL import ImageDraw,ImageFont
    p=tmp_path/'ocr.png'; im=Image.new('RGB',(500,130),'white');ImageDraw.Draw(im).text((20,20),'HELLO 123',fill='black',font=ImageFont.load_default(size=56));im.save(p)
    assert 'HELLO' in result(run(tmp_path,'image.ocr',[p],{'language':'eng'})).read_text().upper()

@pytest.fixture
def libreoffice_engine():
    engine = textops.office_engine()
    if engine is None:
        pytest.skip('LibreOffice unavailable')
    return Path(engine).absolute()


@pytest.mark.usefixtures('libreoffice_engine')
def test_office_rtf(tmp_path):
    document = tmp_path / 'doc.rtf'
    document.write_text(r'{\rtf1\ansi FormaBox RTF test}', encoding='ascii')
    pages = PdfReader(result(run(tmp_path, 'doc.pdf', [document]))).pages
    assert len(pages) == 1
    assert 'FormaBox RTF test' in pages[0].extract_text()


def test_office_docx(tmp_path, libreoffice_engine, monkeypatch):
    document = tmp_path / '中文 示例.docx'
    expected_text = 'FormaBox Word conversion test'
    with zipfile.ZipFile(document, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('[Content_Types].xml', '''
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Override PartName="/word/document.xml"
            ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''')
        archive.writestr('_rels/.rels', '''
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Target="word/document.xml"
                Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"/>
</Relationships>''')
        archive.writestr('word/document.xml', f'''
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p><w:r><w:t>{expected_text}</w:t></w:r></w:p></w:body>
</w:document>''')

    original = document.read_bytes()
    monkeypatch.setenv('FORMABOX_SOFFICE', str(libreoffice_engine))
    request = dict(tool='doc.pdf', inputs=[str(document)], output=str(tmp_path / '输出 文件'))
    process = subprocess.run(
        [sys.executable, '-m', 'formabox', 'run', '--request', '-'],
        input=json.dumps(request, ensure_ascii=False), encoding='utf-8', capture_output=True,
    )
    assert process.returncode == 0, process.stdout + process.stderr
    event = json.loads(process.stdout.splitlines()[-1])
    assert event['event'] == 'result'
    output = Path(event['files'][0])
    assert output.name == '0001-中文 示例.pdf'
    pages = PdfReader(output).pages
    assert len(pages) == 1
    assert expected_text in pages[0].extract_text()
    assert document.read_bytes() == original
