"""PDF image compression and invisible OCR layers."""
from contextlib import closing
import math
import tempfile
from pathlib import Path

from PIL import Image
from pypdf import PdfReader, PdfWriter
from pypdf.generic import ArrayObject

from .core import copy_file, extended_path
from .imageops import ocr_engine, tesseract_command
from .pdfops import save

MAX_PDF_SIZE = 256 * 1024**2
MAX_PAGES = 300


def open_pdf(path):
    if not path.is_file() or path.suffix.lower() != '.pdf':
        raise ValueError('请选择 PDF 文件')
    if path.stat().st_size > MAX_PDF_SIZE:
        raise ValueError('此操作支持不超过 256 MiB 的 PDF')
    source = PdfReader(path)
    if source.is_encrypted:
        raise ValueError('此操作需要未加密的 PDF')
    if not 1 <= len(source.pages) <= MAX_PAGES:
        raise ValueError('PDF 需要有 1–300 页')
    return source


def resize_images(ctx, writer, scale, quality):
    seen = set()
    for page in writer.pages:
        for key in page.images.keys():
            ctx.check()
            # Skip inline images. Inspect XObject metadata before decoding pixels.
            resource = page['/Resources'] if '/Resources' in page else {}
            keys = [key] if isinstance(key, str) else key
            entry = None
            for part in keys:
                objects = resource.get('/XObject', {})
                if hasattr(objects, 'get_object'):
                    objects = objects.get_object()
                entry = objects.get(part)
                if entry is None:
                    break
                entry = entry.get_object()
                resource = entry.get('/Resources', {})
                if hasattr(resource, 'get_object'):
                    resource = resource.get_object()
            if entry is None or entry.get('/Subtype') != '/Image':
                continue
            ref = getattr(entry, 'indirect_reference', None)
            if ref is None or ref.idnum in seen:
                continue
            seen.add(ref.idnum)
            width, height = int(entry.get('/Width', 0)), int(entry.get('/Height', 0))
            color = entry.get('/ColorSpace')
            if (not isinstance(color, str) or color not in ('/DeviceRGB', '/DeviceGray') or
                    any(name in entry for name in ('/Mask', '/SMask', '/ImageMask', '/Decode', '/Alternates', '/OC')) or
                    entry.get('/SMaskInData', 0) or not 160_000 <= width * height <= 36_000_000 or
                    int(entry.get('/BitsPerComponent', 0)) != 8):
                continue
            filters = entry.get('/Filter')
            if isinstance(filters, ArrayObject):
                continue
            if filters not in ('/DCTDecode', '/FlateDecode', None):
                continue
            try:
                image = page.images[key]
                if image.image is None or image.image.mode not in ('RGB', 'L'):
                    continue
                with image.image.resize((max(1, round(width * scale)), max(1, round(height * scale))),
                                        Image.Resampling.LANCZOS) as smaller:
                    image.replace(smaller, quality=quality, dpi=(72, 72))
            except (OSError, ValueError, NotImplementedError):
                continue


def best_pdf(ctx, source_path, destination, target_bytes):
    source_path = extended_path(source_path)
    source = open_pdf(source_path)
    original_size = source_path.stat().st_size
    copy_file(ctx, source_path, destination)
    if original_size <= target_bytes:
        return original_size

    best_size = original_size
    profiles = [(1, None), (0.85, 84), (0.66, 73), (0.48, 58), (0.32, 43), (0.24, 35)]
    with tempfile.TemporaryDirectory(prefix='candidate-', dir=ctx.root) as work:
        candidate = Path(work) / 'target.pdf'
        for i, (scale, quality) in enumerate(profiles):
            ctx.tick(i, len(profiles), f'压缩测试 {i + 1}/{len(profiles)}')
            writer = PdfWriter(clone_from=source)
            if quality is not None:
                resize_images(ctx, writer, scale, quality)
            writer.compress_identical_objects(remove_identicals=True, remove_orphans=True)
            writer.write(candidate)
            size = candidate.stat().st_size
            if size < best_size:
                candidate.replace(destination)
                best_size = size
            if best_size <= target_bytes:
                break
    return best_size


def render_page(page, limit, scale=math.inf):
    width, height = page.get_size()
    if not all(math.isfinite(side) and side > 0 for side in (width, height)):
        raise ValueError('PDF 页面尺寸无效')
    return page.render(scale=min(scale, limit / max(width, height)))


def ocr_matrix(box, rotation, layer):
    left, bottom, right, top = box
    width, height = right - left, top - bottom
    lx, ly = float(layer.mediabox.width), float(layer.mediabox.height)
    x, y = width / lx, height / ly
    if rotation == 0:
        return x, 0, 0, y, left, bottom
    if rotation == 90:
        return 0, height / lx, -width / ly, 0, right, bottom
    if rotation == 180:
        return -x, 0, 0, -y, right, top
    return 0, -height / lx, width / ly, 0, left, top


def add_ocr(ctx, path, lang, output_name):
    import pypdfium2 as pdfium

    path = extended_path(path)
    source = open_pdf(path)
    existing = []
    for page in source.pages:
        ctx.check()
        existing.append(bool(page.extract_text().strip()))
    if all(existing):
        destination = ctx.path(output_name)
        copy_file(ctx, path, destination)
        return destination

    engine = ocr_engine(ctx, lang)
    writer = PdfWriter(clone_from=source)
    recognized = False
    with tempfile.TemporaryDirectory(prefix='ocr-', dir=ctx.root) as folder, closing(pdfium.PdfDocument(str(path))) as document:
        work = Path(folder)
        if len(document) != len(writer.pages):
            raise ValueError('PDF 页数校验失败')
        for index, page in enumerate(writer.pages):
            ctx.tick(index, len(writer.pages), f'{path.name} · 第 {index + 1} 页')
            if existing[index]:
                continue
            with closing(document[index]) as original:
                with closing(render_page(original, 4200, 240 / 72)) as bitmap, bitmap.to_pil() as image:
                    image.save(work / 'page.png')
                box = original.get_bbox()
                rotation = original.get_rotation()
            ctx.run(tesseract_command(engine, 'page.png', 'recognized', '-l', lang, '--dpi', '240',
                                      '-c', 'textonly_pdf=1', '-c', 'tessedit_create_pdf=1',
                                      '-c', 'tessedit_create_txt=0'), cwd=work, timeout=90)
            layer_path = work / 'recognized.pdf'
            if not layer_path.is_file():
                raise RuntimeError('Tesseract 未生成 OCR 文字层')
            layer = PdfReader(layer_path).pages[0]
            if not layer.extract_text().strip():
                continue
            page.merge_transformed_page(layer, ocr_matrix(box, rotation, layer), expand=False)
            recognized = True
    if not recognized:
        if not any(existing):
            raise ValueError('此 PDF 没有识别到文字')
        destination = ctx.path(output_name)
        copy_file(ctx, path, destination)
        return destination
    return save(writer, ctx, output_name)
