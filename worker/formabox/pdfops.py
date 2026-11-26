from .core import *
from pypdf import PdfReader,PdfWriter

def reader(f,password=''):
    r=PdfReader(f)
    if r.is_encrypted and not r.decrypt(password): raise ValueError(f'{f.name}: 需要正确密码')
    return r

def save(w,ctx,name):
    out=ctx.path(name); w.write(out); return out

def pages(s,n):
    if not str(s).strip(): return list(range(n))
    out=[]
    for seg in str(s).split(','):
        m=re.fullmatch(r'\s*(\d+)\s*(?:-\s*(\d+)\s*)?',seg)
        if not m: raise ValueError('页码格式应为 1,3-5')
        a=int(m[1]); b=int(m[2] or a)
        if not 1<=a<=b<=n: raise ValueError('页码超出范围')
        out.extend(range(a-1,b))
    return out

@tool('pdf.merge','PDF','PDF 合并',minimum=2,engines=['pypdf'])
def merge(ctx,inputs,p):
    w=PdfWriter()
    for i,f in enumerate(inputs):
        ctx.tick(i,len(inputs),f.name); w.append(reader(f))
    return [save(w,ctx,'merged.pdf')]

@tool('pdf.split','PDF','PDF 按页拆分',[param('pages','页码范围（空=全部）','')],maximum=1)
def split(ctx,inputs,p):
    r=reader(inputs[0]); out=[]
    for i,j in enumerate(pages(p['pages'],len(r.pages))):
        ctx.check(); w=PdfWriter(); w.add_page(r.pages[j]); out.append(save(w,ctx,f'{i+1:04d}-page-{j+1}.pdf'))
    return out

@tool('pdf.split_groups','PDF','PDF 按组拆分',[param('groups','页码组，用 | 分隔','1-2|3')],maximum=1,
      description='如 1-3|5,4 会输出两份 PDF，第二份按第 5 页、第 4 页的顺序排列。')
def split_groups(ctx,inputs,p):
    source=reader(inputs[0])
    groups=str(p['groups']).split('|')
    if any(not group.strip() for group in groups):
        raise ValueError('每组都需要指定页码')
    selected=[pages(group,len(source.pages)) for group in groups]
    outputs=[]
    for i,group in enumerate(selected):
        ctx.tick(i,len(groups),f'第 {i+1} 组')
        writer=PdfWriter()
        for page in group:
            ctx.check(); writer.add_page(source.pages[page])
        outputs.append(save(writer,ctx,f'group-{i+1:04d}.pdf'))
    return outputs

@tool('pdf.select','PDF','PDF 页面选择与排序',[param('pages','保留页及顺序','1'),param('rotate','顺时针旋转','0','choice',['0','90','180','270'])],maximum=1)
def select(ctx,inputs,p):
    r=reader(inputs[0]); w=PdfWriter(); deg=int(choice(p,'rotate',['0','90','180','270']))
    for j in pages(p['pages'],len(r.pages)):
        ctx.check(); page=w.add_page(r.pages[j]); page.rotate(deg)
    return [save(w,ctx,'selected.pdf')]

@tool('pdf.compress','PDF','PDF 无损流压缩',description='重新压缩内容流；不保证缩小，不降低图片质量。')
def compress(ctx,inputs,p):
    out=[]
    for i,f in enumerate(inputs):
        ctx.tick(i,len(inputs),f.name); w=PdfWriter(clone_from=reader(f))
        for page in w.pages: ctx.check(); page.compress_content_streams()
        w.compress_identical_objects(remove_identicals=True,remove_orphans=True)
        out.append(save(w,ctx,f'{i+1:04d}-{f.stem}.pdf'))
    return out

@tool('pdf.encrypt','PDF','PDF AES-256 加密',[param('password','打开密码','','password')])
def encrypt(ctx,inputs,p):
    if not p['password']: raise ValueError('密码不能为空')
    out=[]
    for i,f in enumerate(inputs):
        ctx.check(); w=PdfWriter(clone_from=reader(f)); w.encrypt(str(p['password']),algorithm='AES-256'); out.append(save(w,ctx,f'{i+1:04d}-{f.stem}-locked.pdf'))
    return out

@tool('pdf.decrypt','PDF','PDF 已知密码解密',[param('password','原密码','','password')])
def decrypt(ctx,inputs,p):
    out=[]
    for i,f in enumerate(inputs):
        ctx.check(); w=PdfWriter(clone_from=reader(f,str(p['password']))); out.append(save(w,ctx,f'{i+1:04d}-{f.stem}-unlocked.pdf'))
    return out

@tool('pdf.text','PDF','PDF 提取文本')
def text(ctx,inputs,p):
    out=[]
    for i,f in enumerate(inputs):
        r=reader(f); dest=ctx.path(f'{i+1:04d}-{f.stem}.txt')
        with dest.open('w',encoding='utf-8') as stream:
            for j,page in enumerate(r.pages): ctx.check(); stream.write(f'\n--- Page {j+1} ---\n'+(page.extract_text() or ''))
        out.append(dest)
    return out

@tool('pdf.render','PDF','PDF 转 PNG',[param('dpi','DPI','144','number'),param('pages','页码范围（空=全部）','')],engines=['pypdfium2'])
def render(ctx,inputs,p):
    try:
        import pypdfium2 as pdfium
    except ImportError:
        raise RuntimeError('PDF 渲染需要 pypdfium2') from None
    scale=integer(p,'dpi',36,300)/72; out=[]
    for i,f in enumerate(inputs):
        doc=pdfium.PdfDocument(str(f))
        try:
            for k,j in enumerate(pages(p['pages'],len(doc))):
                ctx.check(); page=doc[j]
                try:
                    w,h=page.get_size()
                    if w*h*scale**2>80_000_000: raise ValueError('页面渲染像素过大')
                    bmp=page.render(scale=scale)
                    try:
                        path=ctx.path(f'{i+1:04d}-{f.stem}-{k+1:04d}.png'); bmp.to_pil().save(path); out.append(path)
                    finally: bmp.close()
                finally: page.close()
        finally: doc.close()
    return out

@tool('pdf.from_images','PDF','图片转 PDF')
def from_images(ctx,inputs,p):
    from .imageops import load
    ims=[]
    for f in inputs: ctx.check(); ims.append(load(f).convert('RGB'))
    dest=ctx.path('images.pdf'); ims[0].save(dest,save_all=True,append_images=ims[1:]); return [dest]


@tool('pdf.compose', 'PDF', 'PDF 页面工作台', [param('pages', '页面顺序（JSON）', '[]')],
      maximum=32, engines=['pypdf', 'pypdfium2', 'Pillow'],
      description='预览、排序、旋转和组合 PDF 与图片页面。')
def compose(ctx, inputs, params):
    from .pdfworkbench import write_pages

    return [write_pages(ctx, inputs, params['pages'])]


@tool('pdf.compress_target', 'PDF', 'PDF 按大小压缩',
      [param('target_kib', '目标大小（KiB）', '4882', 'number')],
      engines=['pypdf', 'Pillow'],
      description='优先压缩嵌入图片，保留 PDF 文字和矢量内容。未达目标会显示实际大小。')
def compress_target(ctx, inputs, params):
    from .pdfprocessing import best_pdf

    limit = integer(params, 'target_kib', 1, 262144) * 1024
    outputs = []
    for index, path in enumerate(inputs, 1):
        destination = ctx.path(f'{index:04d}-{path.stem}-compressed.pdf')
        size = best_pdf(ctx, path, destination, limit)
        if size > limit:
            raise ValueError(f'{path.name}：试压后为 {size / 1024:.1f} KiB，未达到 {limit / 1024:.0f} KiB。'
                             '可在 PDF 页面工作台预览并保存试压结果。')
        outputs.append(destination)
    return outputs


@tool('pdf.ocr', 'PDF', '扫描 PDF 转可搜索 PDF',
      [param('language', 'Tesseract 语言', 'chi_sim+eng')],
      engines=['pypdfium2', 'tesseract'],
      description='保留原页外观，为没有可提取文字的页面添加可搜索的文字层。')
def searchable_pdf(ctx, inputs, params):
    from .pdfprocessing import add_ocr

    return [add_ocr(ctx, path, str(params['language']), f'{index:04d}-{path.stem}-searchable.pdf')
            for index, path in enumerate(inputs, 1)]
