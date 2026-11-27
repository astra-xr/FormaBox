"""Read-only previews prepared in the desktop's temporary directory."""
from contextlib import closing
from hashlib import sha256
import json

from .core import Context, TOOLS, checked_path, extended_path, integer, invoke, number
from .imageops import load, save_png
from .studio_files import archive_rows, batch_plan
from .studio_media import detect_silence, probe, video_still
from .studio_pdf import clean_scan, open_pdf, scan_pages, snapshot, table_rows


def batch_fingerprint(records):
    return sha256(json.dumps(records, ensure_ascii=False).encode('utf-8')).hexdigest()


def preview_tool(request):
    import pypdfium2 as pdfium
    from .mediaops import ff

    tool = request.get('tool')
    allowed = {'image.id_photo', 'image.region_ocr', 'pdf.redact', 'pdf.clean_scan', 'pdf.table_xlsx',
               'video.timeline', 'audio.silence', 'file.archive', 'folder.batch'}
    if not isinstance(tool, str) or tool not in allowed:
        raise ValueError('此工具没有交互预览')
    values = request.get('inputs')
    spec = TOOLS[tool][0]
    if not isinstance(values, list) or not spec['minimum'] <= len(values) <= spec['maximum']:
        raise ValueError('预览输入数量不符合要求')
    paths = [checked_path(value) for value in values]
    params = {p['key']: p['default'] for p in spec['params']}
    configured = request.get('params', {})
    if not isinstance(configured, dict) or set(configured) - params.keys():
        raise ValueError('预览参数有误')
    params.update(configured)
    ctx = Context(extended_path(checked_path(request.get('output'))), progress=lambda *a, **fields: None)
    purpose = request.get('purpose', 'initial')
    if tool == 'folder.batch':
        _, records = batch_plan(ctx, paths, params)
        return dict(rows=[dict(name=name, bytes=size) for name, size, _ in records],
                    fingerprint=batch_fingerprint(records))
    if tool == 'file.archive':
        return dict(rows=archive_rows(paths[0], integer(params, 'max_mib', 1, 8192)*1024**2))
    if tool == 'pdf.clean_scan':
        rows = []
        for index, (image, label) in enumerate(scan_pages(paths), 1):
            with image:
                clean, blank, angle = clean_scan(image)
                with clean:
                    filename = f'page-{index}.jpg'
                    clean.thumbnail((240, 280))
                    clean.save(ctx.path(filename), quality=85)
            rows.append(dict(name=label, page=index, blank=blank, angle=angle, thumbnail=filename))
        return dict(rows=rows)
    if tool == 'video.timeline':
        if purpose == 'shot':
            index = integer(request, 'index', 0, len(paths)-1)
            duration, _ = probe(ctx, paths[index], 'v')
            start = number(request, 'start', 0, duration)
            end = number(request, 'end', 0, duration)
            if end-start < .04:
                raise ValueError('结束点应晚于开始点至少 0.04 秒')
            for name, position in (('start.png', start), ('end.png', max(start, end-.10))):
                video_still(ctx, paths[index], position, ctx.path(name))
            return dict(pictures=['start.png', 'end.png'])
        return dict(rows=[dict(name=path.name, source=index, start=0, end=duration, duration=duration)
                          for index, path in enumerate(paths) for duration, _ in [probe(ctx, path, 'v')]])
    if tool == 'audio.silence':
        duration, spans = detect_silence(ctx, paths[0], params)
        if purpose == 'listen':
            index = integer(request, 'index', 0, len(spans)-1)
            start, end = spans[index]
            position = max(0, start-.6)
            ff(ctx, paths[0], ctx.path('sample.wav'), ['-ss', str(position), '-t', str(min(end+.7-position, 6)),
                                                     '-map', '0:a:0', '-vn', '-c:a', 'pcm_s16le'])
            return dict(sample='sample.wav')
        return dict(rows=[dict(start=a, end=b) for a, b in spans[:280]], total=len(spans), duration=duration)
    if tool == 'image.id_photo' and purpose == 'evaluate':
        jpeg, sheet = invoke(tool, paths, params, ctx)
        with closing(pdfium.PdfDocument(str(sheet))) as document, snapshot(document, 0, 860) as image:
            image.save(ctx.path('print.png'))
        with load(jpeg) as image:
            image.save(ctx.path('photo.png'))
            size = image.size
        return dict(pictures=['photo.png', 'print.png'], photoSize=list(size), jpegBytes=jpeg.stat().st_size)
    if tool == 'image.region_ocr' and purpose == 'evaluate':
        text, = invoke(tool, paths, params, ctx)
        value = text.read_text(encoding='utf-8', errors='replace')
        if len(value) > 500_000:
            raise ValueError('选区文字过长，请缩小选区')
        return dict(text=value)
    if tool == 'pdf.table_xlsx' and purpose == 'evaluate':
        return dict(cells=table_rows(paths[0], params))
    if tool in ('pdf.redact', 'pdf.table_xlsx'):
        path = extended_path(paths[0])
        count = len(open_pdf(path).pages)
        page = integer(request, 'page', 1, count)
        with closing(pdfium.PdfDocument(str(path))) as document, snapshot(document, page-1, 1024) as image:
            image.save(ctx.path('source.png'))
        return dict(image='source.png', pages=count, page=page)
    with load(paths[0]) as image:
        image.thumbnail((1200, 1050))
        save_png(image, ctx.path('source.png'))
    return dict(image='source.png')
