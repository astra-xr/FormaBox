"""Apply page marks and margins in the PDF's displayed orientation."""

from io import BytesIO
import math
import os
from pathlib import Path
import unicodedata

from PIL import Image, ImageDraw, ImageFont
from pypdf import PageObject, PdfReader, PdfWriter, Transformation
from pypdf.generic import DecodedStreamObject, DictionaryObject, FloatObject, NameObject, RectangleObject

from .core import extended_path
from .pdfops import pages, save
from .pdfprocessing import open_pdf

POINTS_PER_MM = 72 / 25.4


def edit_documents(ctx, inputs, page_range, suffix, edit, *, min_version=None):
    outputs = []
    for file_index, path in enumerate(inputs, 1):
        ctx.tick(file_index - 1, len(inputs), path.name)
        source = open_pdf(extended_path(path))
        selected = sorted(set(pages(page_range, len(source.pages))))
        writer = PdfWriter(clone_from=source)
        if min_version and writer.pdf_header < min_version:
            writer.pdf_header = min_version
        for index, page_index in enumerate(selected):
            ctx.check()
            try:
                edit(writer.pages[page_index], index)
            except ValueError as error:
                raise ValueError(f'{path.name} · 第 {page_index + 1} 页：{error}') from error
        outputs.append(save(writer, ctx, f'{file_index:04d}-{path.stem}-{suffix}.pdf'))
    return outputs


def page_view(page):
    media, crop = page.mediabox, page.cropbox
    left, bottom = max(float(media.left), float(crop.left)), max(float(media.bottom), float(crop.bottom))
    right, top = min(float(media.right), float(crop.right)), min(float(media.top), float(crop.top))
    unit = float(page.user_unit)
    rotation = page.rotation % 360
    if (not all(math.isfinite(value) for value in (left, bottom, right, top, unit)) or
            right <= left or top <= bottom or unit <= 0 or rotation not in (0, 90, 180, 270)):
        raise ValueError('页面尺寸或旋转角度无效')
    if rotation == 90:
        return top - bottom, right - left, unit, Transformation((0, 1, -1, 0, right, bottom))
    if rotation == 180:
        return right - left, top - bottom, unit, Transformation((-1, 0, 0, -1, right, top))
    if rotation == 270:
        return top - bottom, right - left, unit, Transformation((0, -1, 1, 0, left, top))
    return right - left, top - bottom, unit, Transformation((1, 0, 0, 1, left, bottom))


def crop_page(page, margins):
    width, height, unit, transform = page_view(page)
    top, right, bottom, left = (value * POINTS_PER_MM / unit for value in margins)
    if right + left >= width or top + bottom >= height:
        raise ValueError('裁切边距超出页面尺寸')
    x1, y1 = transform.apply_on((left, bottom))
    x2, y2 = transform.apply_on((width - right, height - top))
    page.cropbox = RectangleObject((min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2)))


def merge_stamp(page, layer, position, margin_mm):
    width, height, unit, view = page_view(page)
    stamp_width = float(layer.mediabox.width) / unit
    stamp_height = float(layer.mediabox.height) / unit
    margin = margin_mm * POINTS_PER_MM / unit
    if stamp_width + 2 * margin > width or stamp_height + 2 * margin > height:
        raise ValueError('文字或留边过大，请减小字号、边距或缩短文字')
    x = (width - stamp_width) / 2
    y = (height - stamp_height) / 2
    if position.startswith('左'):
        x = margin
    elif position.startswith('右'):
        x = width - stamp_width - margin
    if position.startswith(('顶部', '左上', '右上')):
        y = height - stamp_height - margin
    elif position.startswith(('底部', '左下', '右下')):
        y = margin
    a, b, c, d, _, _ = view.ctm
    tx, ty = view.apply_on((x, y))
    page.merge_transformed_page(layer, (a / unit, b / unit, c / unit, d / unit, tx, ty))


def number_layer(number, size):
    # Courier's standard PDF metrics give each digit a width of 0.6 em.
    label = str(number)
    layer = PageObject.create_blank_page(width=size * (0.6 * len(label) + 0.4), height=size)
    layer[NameObject('/Resources')] = DictionaryObject({
        NameObject('/Font'): DictionaryObject({
            NameObject('/FormaboxNumber'): DictionaryObject({
                NameObject('/Type'): NameObject('/Font'),
                NameObject('/Subtype'): NameObject('/Type1'),
                NameObject('/BaseFont'): NameObject('/Courier'),
            }),
        }),
    })
    contents = DecodedStreamObject()
    contents.set_data(f'BT /FormaboxNumber {size} Tf 0 g {size / 5} {size / 5} Td ({label}) Tj ET\n'.encode('ascii'))
    layer[NameObject('/Contents')] = contents
    return layer


def watermark_font(text, pixels):
    fonts = [ImageFont.load_default(pixels)]
    if any(not character.isascii() for character in text) and os.name == 'nt':
        directory = Path(os.environ.get('WINDIR', r'C:\Windows')) / 'Fonts'
        for name in ('msyh.ttc', 'simsun.ttc'):
            try:
                fonts.append(ImageFont.truetype(str(directory / name), pixels))
            except OSError:
                continue
    for font in fonts:
        missing = bytes(font.getmask('\u0378'))
        if all(character.isspace() or bytes(font.getmask(character)) != missing for character in set(text)):
            return font
    raise ValueError('可用字体缺少水印里的字符，请更换文字')


def watermark_layer(value, size, opacity):
    text = value.strip() if isinstance(value, str) else ''
    if not 1 <= len(text) <= 80 or any(unicodedata.category(ch) in ('Cc', 'Cs', 'Zl', 'Zp') for ch in text):
        raise ValueError('水印需要 1–80 个字符，并且只支持一行')
    scale = 3
    font = watermark_font(text, size * scale)
    left, top, right, bottom = font.getbbox(text)
    width, height = right - left, bottom - top
    if width <= 0 or height <= 0 or (width + 2) * (height + 2) > 8_000_000:
        raise ValueError('水印尺寸无效，请减小字号或缩短文字')
    with Image.new('RGBA', (width + 2, height + 2)) as image:
        ImageDraw.Draw(image).text((1 - left, 1 - top), text, font=font,
                                   fill=(32, 32, 32, 255))
        if not image.getbbox():
            raise ValueError('水印没有可见文字')
        data = BytesIO()
        image.save(data, 'PDF', resolution=72 * scale)
    data.seek(0)
    layer = PdfReader(data).pages[0]
    layer['/Resources'][NameObject('/ExtGState')] = DictionaryObject({
        NameObject('/FormaBoxOpacity'): DictionaryObject({
            NameObject('/ca'): FloatObject(opacity / 100),
        }),
    })
    contents = DecodedStreamObject()
    contents.set_data(b'q /FormaBoxOpacity gs\n' + layer.get_contents().get_data() + b'\nQ\n')
    layer[NameObject('/Contents')] = contents
    return layer
