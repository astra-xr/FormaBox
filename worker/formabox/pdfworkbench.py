import io
import json
import math
from contextlib import closing

from PIL import Image
from pypdf import PdfWriter

from .core import checked_path, extended_path
from .imageops import load
from .pdfops import reader, save


MAX_PAGES = 300
IMAGE_EXTENSIONS = {'.png', '.jpg', '.jpeg', '.webp', '.bmp', '.tif', '.tiff', '.avif', '.ico'}


def source_type(path):
    if path.is_file():
        if path.suffix.lower() == '.pdf':
            return 'pdf'
        if path.suffix.lower() in IMAGE_EXTENSIONS:
            return 'image'
    raise ValueError(f'{path.name}: 工作台支持 PDF 和单帧图片')


def rgb_image(path, thumbnail_size=None):
    with load(path) as image:
        if thumbnail_size:
            image.thumbnail(thumbnail_size, Image.Resampling.LANCZOS)
        with image.convert('RGBA') as transparent:
            result = Image.new('RGB', transparent.size, 'white')
            result.paste(transparent, mask=transparent.getchannel('A'))
            return result


def preview_pages(request):
    import pypdfium2 as pdfium

    inputs, limit = request.get('inputs'), request.get('limit')
    if not isinstance(inputs, list) or not 1 <= len(inputs) <= 32:
        raise ValueError('每次请选择 1–32 个文件')
    if type(limit) is not int or not 1 <= limit <= MAX_PAGES:
        raise ValueError('工作台最多容纳 300 页')
    output = extended_path(checked_path(request.get('output')))
    rows = []

    def record(index, page, thumbnail):
        path = output / f'{len(rows):04d}.png'
        thumbnail.save(path)
        rows.append(dict(source=index, page=page, thumbnail=path.name))

    for index, value in enumerate(inputs):
        path = extended_path(checked_path(value))
        if source_type(path) == 'image':
            if len(rows) == limit:
                raise ValueError('工作台最多容纳 300 页')
            with rgb_image(path, (160, 210)) as image:
                record(index, 0, image)
            continue

        with closing(pdfium.PdfDocument(str(path))) as doc:
            if not len(doc):
                raise ValueError(f'{path.name}: PDF 没有页面')
            if len(rows) + len(doc) > limit:
                raise ValueError('工作台最多容纳 300 页')
            for number in range(len(doc)):
                with closing(doc[number]) as page:
                    width, height = page.get_size()
                    if not all(math.isfinite(side) and side > 0 for side in (width, height)):
                        raise ValueError(f'{path.name}: PDF 页面尺寸无效')
                    scale = min(160 / width, 210 / height)
                    with closing(page.render(scale=scale)) as bitmap, bitmap.to_pil() as thumbnail:
                        record(index, number, thumbnail)
    return rows


def write_pages(ctx, inputs, plan):
    if not isinstance(plan, str) or len(plan) > 65536:
        raise ValueError('页面顺序必须是 JSON 文本')
    rows = json.loads(plan)
    if not isinstance(rows, list) or not 1 <= len(rows) <= MAX_PAGES:
        raise ValueError('请选择 1–300 页')

    writer = PdfWriter()
    sources = {}
    for i, row in enumerate(rows):
        if not isinstance(row, dict) or set(row) != {'source', 'page', 'rotation'}:
            raise ValueError('页面记录无效')
        index, number, rotation = row['source'], row['page'], row['rotation']
        if (any(type(value) is not int for value in (index, number, rotation)) or
                not 0 <= index < len(inputs) or number < 0 or rotation not in (0, 90, 180, 270)):
            raise ValueError('页面、来源或旋转角度无效')
        path = extended_path(inputs[index])
        ctx.tick(i, len(rows), f'{path.name} · {number + 1}')
        if index not in sources:
            if source_type(path) == 'pdf':
                sources[index] = reader(path)
            else:
                stream = io.BytesIO()
                with rgb_image(path) as image:
                    image.save(stream, 'PDF')
                sources[index] = reader(stream)
        source = sources[index]
        if number >= len(source.pages):
            raise ValueError(f'{path.name}: 页码超出范围')
        page = writer.add_page(source.pages[number])
        if rotation:
            page.rotate(rotation)
    return save(writer, ctx, 'workbench.pdf')
