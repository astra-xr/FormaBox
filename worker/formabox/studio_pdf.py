"""Page comparison, scan cleanup, tables and burned-in redaction."""
from collections import defaultdict
from contextlib import closing
from difflib import SequenceMatcher
from html import escape
import hashlib
import io
import json
import statistics

from PIL import Image, ImageChops, ImageDraw
from pypdf import PdfReader, PdfWriter

from .core import extended_path, integer, param, tool, truth
from .pdfops import pages, save
from .pdfprocessing import add_ocr, open_pdf, render_page
from .pdfworkbench import rgb_image, source_type
from .studio_images import pixel_rectangle, rectangle


def snapshot(document, index, limit=900, dpi=150):
    with closing(document[index]) as page, closing(render_page(page, limit, dpi/72)) as bitmap:
        with bitmap.to_pil() as image:
            return image.convert('RGB')


def image_page(writer, image, dpi=150):
    with io.BytesIO() as stream:
        image.save(stream, 'PDF', resolution=dpi, quality=92)
        writer.add_page(PdfReader(stream).pages[0])


def clean_scan(image):
    output = image.copy()
    output.thumbnail((2800, 2800), Image.Resampling.LANCZOS)
    gray = output.convert('L')
    gray.thumbnail((360, 360), Image.Resampling.LANCZOS)
    w, h = gray.size

    # Trim contiguous dark edge strips before estimating horizontal text rows.
    pixels = gray.load()
    left, top, right, bottom = 0, 0, w, h
    for side, bound in (('left', w//8), ('right', w//8), ('top', h//8), ('bottom', h//8)):
        count = 0
        for offset in range(bound):
            if side in ('left', 'right'):
                x = offset if side == 'left' else w-1-offset
                coverage = sum(pixels[x, y] < 70 for y in range(h//5, h-h//5))/max(1, h-2*(h//5))
            else:
                y = offset if side == 'top' else h-1-offset
                coverage = sum(pixels[x, y] < 70 for x in range(w//5, w-w//5))/max(1, w-2*(w//5))
            if coverage < .55:
                break
            count += 1
        if side == 'left':
            left = count
        elif side == 'right':
            right = w-count
        elif side == 'top':
            top = count
        else:
            bottom = h-count
    bounds = (left, top, right, bottom)
    if bounds != (0, 0, w, h):
        output = output.crop(tuple(round(value*size/base) for value, size, base in
                                   zip(bounds, (*output.size, *output.size), (w, h, w, h))))
        gray = gray.crop(bounds)

    histogram = gray.histogram()
    blank = sum(histogram[:155]) <= max(2, gray.width*gray.height*.0012)
    angle = 0
    if not blank:
        ink = gray.point(lambda value: 255 if value < 145 else 0)
        def score(degrees):
            rotated = ink.rotate(degrees, fillcolor=0)
            lines = [sum(rotated.crop((0, y, rotated.width, y+1)).tobytes()) for y in range(rotated.height)]
            return sum((b-a)**2 for a, b in zip(lines, lines[1:]))
        straight = score(0)
        angle = max((a/2 for a in range(-12, 13)), key=score)
        if abs(angle) >= 1 and score(angle) > straight*1.12:
            output = output.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True, fillcolor='white')
        else:
            angle = 0
    return output, blank, angle


def scan_pages(paths):
    import pypdfium2 as pdfium

    count = 0
    for path in paths:
        if source_type(path) == 'image':
            count += 1
            if count > 100:
                raise ValueError('每批最多 100 页')
            yield rgb_image(path, (2800, 2800)), path.name
        else:
            source = open_pdf(extended_path(path))
            count += len(source.pages)
            if count > 100:
                raise ValueError('每批最多 100 页')
            with closing(pdfium.PdfDocument(str(extended_path(path)))) as document:
                for index in range(len(document)):
                    yield snapshot(document, index, 2600, 220), f'{path.name} · {index+1}'


@tool('pdf.clean_scan', 'PDF', '扫描件整理',
      [param('ocr', '生成可搜索文字层', 'true', 'bool'),
       param('language', 'OCR 语言', 'chi_sim+eng'),
       param('remove', '排除页码', '', 'internal')], maximum=100, engines=['pypdfium2', 'tesseract'],
      description='纠偏、去暗边，预览空白页后选择保留范围，再合成 PDF。')
def clean_scans(ctx, inputs, params):
    removed = set(pages(params['remove'], 100)) if str(params['remove']).strip() else set()
    writer = PdfWriter()
    for index, (image, label) in enumerate(scan_pages(inputs)):
        ctx.tick(index, 0, label)
        with image:
            if index not in removed:
                cleaned, _, _ = clean_scan(image)
                with cleaned:
                    image_page(writer, cleaned, 170)
    if not writer.pages:
        raise ValueError('至少保留一页')
    if not truth(params['ocr']):
        return [save(writer, ctx, '整理扫描件.pdf')]
    source = save(writer, ctx, '待识别.pdf')
    try:
        result = add_ocr(ctx, source, str(params['language']), '整理扫描件.pdf')
    finally:
        source.unlink()
    return [result]


def page_fingerprints(ctx, document):
    fingerprints = []
    for index in range(len(document)):
        ctx.check()
        with snapshot(document, index, 790) as image:
            fingerprints.append((image.size, hashlib.sha256(image.tobytes()).digest()))
    return fingerprints


@tool('pdf.compare', 'PDF', 'PDF 版本对比', minimum=2, maximum=2, engines=['pypdfium2'],
      description='并列比较两份 PDF 的可视页面，识别插入、删除和修改并生成可跳转报告。')
def compare_pdfs(ctx, inputs, params):
    import pypdfium2 as pdfium

    for path in inputs:
        open_pdf(extended_path(path))
    resources = ctx.path('页面对照')
    resources.mkdir()
    blocks = []
    with closing(pdfium.PdfDocument(str(extended_path(inputs[0])))) as left, \
         closing(pdfium.PdfDocument(str(extended_path(inputs[1])))) as right:
        matcher = SequenceMatcher(None, page_fingerprints(ctx, left), page_fingerprints(ctx, right), autojunk=False)
        for label, a, b, c, d in matcher.get_opcodes():
            if label == 'equal':
                continue
            for offset in range(max(b-a, d-c)):
                index = len(blocks)+1
                ctx.tick(index-1, 0, f'对照第 {index} 项')
                numbers = (a+offset if a+offset < b else None, c+offset if c+offset < d else None)
                images = [snapshot(doc, n, 920) if n is not None else None for doc, n in zip((left, right), numbers)]
                if all(im is not None for im in images) and images[0].size == images[1].size:
                    box = ImageChops.difference(*images).getbbox()
                    if box:
                        for im in images:
                            ImageDraw.Draw(im).rectangle(box, outline='#db3636', width=3)
                columns = []
                for side, n, im in zip(('A', 'B'), numbers, images):
                    if im is None:
                        columns.append('<figure>—</figure>')
                    else:
                        name = f'{index}-{side}.png'
                        with im:
                            im.save(resources/name)
                        columns.append(f'<figure><figcaption>{side} · 第 {n+1} 页</figcaption>'
                                       f'<img loading="lazy" src="页面对照/{name}" alt=""></figure>')
                label = '新增' if numbers[0] is None else '删除' if numbers[1] is None else '修改'
                blocks.append(f'<section id="d{index}"><h2>{index} · {label}</h2><div>{"".join(columns)}</div></section>')
    nav = ' '.join(f'<a href="#d{i}">{i}</a>' for i in range(1, len(blocks)+1))
    output = ctx.path('PDF版本对比.html')
    output.write_text('<!doctype html><html lang="zh-CN"><meta charset="utf-8">'
                      '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src \'self\' file:; style-src \'unsafe-inline\'">'
                      '<title>PDF 版本对比</title><style>body{font:16px system-ui;background:#edf1f5;color:#213344;margin:2rem}'
                      'nav{position:sticky;top:0;background:#fff;padding:12px}a{margin:7px}section{scroll-margin-top:65px}'
                      'section div{display:grid;grid-template-columns:1fr 1fr;gap:8px}figure{margin:0;background:white;padding:9px}'
                      'img{max-width:100%}</style><h1>PDF 版本对比</h1>'
                      f'<p>A · {escape(inputs[0].name)}　B · {escape(inputs[1].name)}</p>'
                      f'<nav>差异 {len(blocks)} 项　{nav}</nav>'+(''.join(blocks) or '<p>页面渲染一致。</p>'),
                      encoding='utf-8')
    return [output]


def table_rows(path, params):
    import pypdfium2 as pdfium

    source = open_pdf(extended_path(path))
    index = integer(params, 'page', 1, len(source.pages))-1
    x, y, w, h = rectangle(params['region'])
    with closing(pdfium.PdfDocument(str(extended_path(path)))) as document, closing(document[index]) as page:
        if page.get_rotation():
            raise ValueError('当前表格识别支持未旋转的 PDF 页面')
        left, bottom, right, top = page.get_bbox()
        width, height = right-left, top-bottom
        region = (left+x*width, top-(y+h)*height, left+(x+w)*width, top-y*height)
        with closing(page.get_textpage()) as text:
            count = text.count_chars()
            if count > 70_000:
                raise ValueError('此页文字过多，请先拆分页')
            glyphs = []
            for char in range(count):
                token = text.get_text_range(char, 1)
                if not token.strip():
                    continue
                ax, ay, bx, by = text.get_charbox(char, loose=True)
                if region[0] <= (ax+bx)/2 <= region[2] and region[1] <= (ay+by)/2 <= region[3]:
                    glyphs.append((ax, bx, (ay+by)/2, by-ay, token))
    if not glyphs:
        raise ValueError('所选区域没有可提取的文字，请先做扫描 PDF OCR')
    glyphs.sort(key=lambda g: (-g[2], g[0]))
    height = max(1, statistics.median(g[3] for g in glyphs))
    lines = []
    for glyph in glyphs:
        if not lines or abs(glyph[2]-lines[-1][0][2]) > height*.55:
            lines.append([])
        lines[-1].append(glyph)
    sections = []
    for line in lines:
        cells = []
        start = end = None
        value = ''
        for a, b, _, _, token in sorted(line):
            if end is None or a-end > height*.92:
                if value:
                    cells.append((start, value.strip()))
                start, value = a, token
            else:
                value += (' ' if a-end > height*.23 else '') + token
            end = b
        cells.append((start, value.strip()))
        sections.append(cells)
    raw = str(params['columns']).strip()
    if raw:
        try:
            cuts = [float(n)/100 for n in raw.split(',')]
        except ValueError:
            raise ValueError('列边界使用逗号分隔的百分数') from None
        if cuts != sorted(set(cuts)) or not all(0 < n < 1 for n in cuts) or len(cuts) > 31:
            raise ValueError('列边界需要 1–99 的升序百分数')
        boundaries = [region[0]+n*(region[2]-region[0]) for n in cuts]
        sections = []
        for line in lines:
            grouped = defaultdict(list)
            for a, b, _, _, token in sorted(line):
                grouped[sum(a >= boundary for boundary in boundaries)].append((a, b, token))
            cells = []
            for glyphs in grouped.values():
                value = glyphs[0][2]
                for (_, end, _), (start, _, token) in zip(glyphs, glyphs[1:]):
                    value += (' ' if start-end > height*.18 else '')+token
                cells.append((glyphs[0][0], value))
            sections.append(cells)
    else:
        reference = max(sections, key=len)
        boundaries = [a-height*.55 for a, _ in reference[1:]]
        if len(boundaries) > 31:
            raise ValueError('检测到的列过多，请缩小区域或指定列边界')
    rows = []
    for cells in sections:
        row = ['']*(len(boundaries)+1)
        for x, text in cells:
            index = sum(x >= boundary for boundary in boundaries)
            row[index] = (row[index]+(' ' if row[index] else '')+text).strip()
        rows.append(row)
    return rows


@tool('pdf.table_xlsx', 'PDF', 'PDF 表格转 Excel', [
    param('page', '第几页', '1', 'number'),
    param('columns', '列边界百分比（可选，如 25,50,75）', ''),
    param('region', '选区（相对比例）', '0,0,1,1', 'internal')
], maximum=1, engines=['pypdfium2', 'openpyxl'],
      description='选定页码和表格区域，预览识别内容后导出 Excel。现支持规则的文字表格。')
def table_xlsx(ctx, inputs, params):
    from openpyxl import Workbook

    rows = table_rows(inputs[0], params)
    book = Workbook(write_only=True)
    sheet = book.create_sheet('提取表格')
    from openpyxl.cell import WriteOnlyCell
    for row in rows:
        ctx.check()
        cells = [WriteOnlyCell(sheet, value=value) for value in row]
        for cell in cells:
            cell.data_type = 's'
        sheet.append(cells)
    out = ctx.path('提取表格.xlsx')
    book.save(out)
    return [out]


@tool('pdf.redact', '隐私', 'PDF 永久遮盖', [
    param('regions', '页面选区', '[]', 'internal')
], maximum=1, engines=['pypdfium2'],
      description='在预览画面框选需遮盖处。导出为重新渲染的 PDF，删除源文字层、附件和隐藏对象。')
def redact_pdf(ctx, inputs, params):
    import pypdfium2 as pdfium

    original = open_pdf(extended_path(inputs[0]))
    raw = str(params['regions'])
    if len(raw) > 24576:
        raise ValueError('选区数量超出限制')
    regions = json.loads(raw)
    if not isinstance(regions, list) or not 1 <= len(regions) <= 128:
        raise ValueError('至少添加一处遮盖，最多 128 处')
    grouped = defaultdict(list)
    for row in regions:
        if not isinstance(row, dict) or type(row.get('page')) is not int or not 1 <= row['page'] <= len(original.pages):
            raise ValueError('遮盖页码无效')
        grouped[row['page']-1].append(rectangle(row.get('region')))
    writer = PdfWriter()
    with closing(pdfium.PdfDocument(str(extended_path(inputs[0])))) as document:
        for index in range(len(document)):
            ctx.tick(index, len(document), f'重建第 {index+1} 页')
            with closing(document[index]) as page:
                size = page.get_size()
            with snapshot(document, index, 3400, 215) as image:
                draw = ImageDraw.Draw(image)
                for region in grouped[index]:
                    draw.rectangle(pixel_rectangle(region, image.size), fill='black')
                image_page(writer, image, 72*image.width/size[0])
    return [save(writer, ctx, '永久遮盖.pdf')]
