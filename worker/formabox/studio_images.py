"""Photo preparation and visual OCR selections."""
from contextlib import closing
import math
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps

from .core import integer, param, tool
from .imageops import encode, load, ocr_engine, recognize_png
from .pdfworkbench import rgb_image


def rectangle(value):
    parts = value.split(',') if isinstance(value, str) else value
    try:
        x, y, width, height = map(float, parts)
    except (TypeError, ValueError):
        raise ValueError('选区应包含四个 0–1 的比例坐标') from None
    if not all(math.isfinite(v) for v in (x, y, width, height)) or not (
        0 <= x < 1 and 0 <= y < 1 and 0 < width <= 1 - x + 1e-8 and 0 < height <= 1 - y + 1e-8
    ):
        raise ValueError('选区超出页面，或面积为零')
    return x, y, width, height


def pixel_rectangle(value, size):
    x, y, width, height = rectangle(value)
    w, h = size
    return math.floor(x*w), math.floor(y*h), min(w, math.ceil((x+width)*w)), min(h, math.ceil((y+height)*h))


PHOTO = {'一寸': (25, 35), '二寸': (35, 49)}


def photo_image(path, params):
    preset = str(params['size'])
    if preset in PHOTO:
        width, height = PHOTO[preset]
    elif preset == '自定义':
        width, height = integer(params, 'width_mm', 15, 80), integer(params, 'height_mm', 15, 110)
    else:
        raise ValueError('未知照片规格')
    dpi = integer(params, 'dpi', 150, 600)
    size = tuple(round(mm*dpi/25.4) for mm in (width, height))
    with rgb_image(path) as original:
        with original.crop(pixel_rectangle(params['region'], original.size)) as crop:
            image = ImageOps.fit(crop, size, Image.Resampling.LANCZOS)
    return image, dpi


def photo_bytes(image, target):
    for quality in range(95, 9, -5):
        data = encode(image, 'JPEG', quality)
        if not target or len(data) <= target:
            return data
    raise ValueError('指定尺寸下无法达到文件大小上限，请放宽大小或降低 DPI')


@tool('image.id_photo', '图片', '报名照与冲印排版',
      [param('size', '规格', '一寸', 'choice', ['一寸', '二寸', '自定义']),
       param('width_mm', '自定义宽（毫米）', '25', 'number'),
       param('height_mm', '自定义高（毫米）', '35', 'number'),
       param('dpi', '分辨率 DPI', '300', 'number'),
       param('target_kib', '报名照大小上限 KiB（0=不限）', '97', 'number'),
       param('region', '选区（相对比例）', '0,0,1,1', 'internal')], maximum=1,
      description='按毫米规格制作 JPEG，并生成带裁切线的 6 英寸冲印 PDF。')
def id_photo(ctx, inputs, params):
    image, dpi = photo_image(inputs[0], params)
    with image:
        target = integer(params, 'target_kib', 0, 4000)*1024
        jpeg = ctx.path('报名照.jpg')
        jpeg.write_bytes(photo_bytes(image, target))
        ctx.result_details[jpeg] = dict(original_bytes=inputs[0].stat().st_size, target_bytes=target)
        sheet = ctx.path('6英寸冲印.pdf')
        w, h = image.size
        gap = round(dpi*.13)
        with Image.new('RGB', (6*dpi, 4*dpi), 'white') as print_page:
            draw = ImageDraw.Draw(print_page)
            columns, rows = ((print_page.width-gap)//(w+gap), (print_page.height-gap)//(h+gap))
            if not columns or not rows:
                raise ValueError('照片尺寸超出 6 英寸相纸')
            left, top = (print_page.width-columns*(w+gap)+gap)//2, (print_page.height-rows*(h+gap)+gap)//2
            for row in range(rows):
                for column in range(columns):
                    x, y = left+column*(w+gap), top+row*(h+gap)
                    print_page.paste(image, (x, y))
                    draw.rectangle((x-1, y-1, x+w, y+h), outline='#b7c0ca')
            print_page.save(sheet, 'PDF', resolution=dpi)
    return [jpeg, sheet]


@tool('image.region_ocr', '图片', '选区文字识别',
      [param('language', '识别语言', 'chi_sim+eng'),
       param('region', '选区（相对比例）', '0,0,1,1', 'internal')],
      maximum=1, engines=['tesseract'], description='在图片预览中框选一块区域，用本机 OCR 识别文字。')
def region_ocr(ctx, inputs, params):
    language = str(params['language'])
    engine = ocr_engine(ctx, language)
    result = ctx.path('选区文字.txt')
    with tempfile.TemporaryDirectory(dir=ctx.root) as temp, closing(load(inputs[0])) as source:
        region = Path(temp) / 'region.png'
        with source.crop(pixel_rectangle(params['region'], source.size)) as patch:
            patch.convert('RGB').save(region)
        recognize_png(ctx, engine, region, result, language)
    if not result.read_text(encoding='utf-8', errors='replace').strip():
        raise ValueError('选区没有识别到文字')
    return [result]
