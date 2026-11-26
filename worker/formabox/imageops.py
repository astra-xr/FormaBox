from pathlib import Path
from io import BytesIO
from PIL import Image, ImageOps, ImageDraw, ImageFont
from .core import *
FORMATS={'jpg':'JPEG','jpeg':'JPEG','png':'PNG','webp':'WEBP','avif':'AVIF','bmp':'BMP','tiff':'TIFF','ico':'ICO'}

def load(path):
    if path.suffix.lower() in ('.heic','.heif'):
        try:
            from pillow_heif import register_heif_opener
            register_heif_opener()
        except ImportError: raise RuntimeError('HEIC 输入需要 pillow-heif') from None
    with Image.open(path) as im:
        if getattr(im,'n_frames',1)>1: raise ValueError('此图片含多帧，请先拆分；不静默丢弃帧')
        if im.width*im.height>80_000_000: raise ValueError('图片像素数过大')
        return ImageOps.exif_transpose(im)

def encode(im,fmt,q):
    if fmt=='JPEG':
        if 'A' in im.getbands() or 'transparency' in im.info:
            rgba=im.convert('RGBA'); base=Image.new('RGB',rgba.size,'white'); base.paste(rgba,mask=rgba.getchannel('A')); im=base
        else: im=im.convert('RGB')
    elif fmt in ('WEBP','AVIF'): im=im.convert('RGBA' if 'A' in im.getbands() or 'transparency' in im.info else 'RGB')
    elif fmt in ('PNG','ICO') and im.mode in ('CMYK','YCbCr','LAB','HSV','F'):
        im=im.convert('RGB')
    data=BytesIO(); options={'quality':q} if fmt in ('JPEG','WEBP','AVIF') else {'optimize':True} if fmt=='PNG' else {}
    im.save(data,format=fmt,**options); return data.getvalue()

def each(ctx,inputs,fn):
    out=[]
    for i,p in enumerate(inputs):
        ctx.tick(i,len(inputs),p.name); out.append(fn(p,i))
    return out

def save_png(im,path):
    if im.mode in ('CMYK','YCbCr','LAB','HSV','F'):
        im=im.convert('RGB')
    im.save(path)

def format_param(): return param('format','输出格式','jpg','choice',list(FORMATS))
def quality(): return param('quality','质量 1–100','85','number')

@tool('image.convert','图片','图片格式转换',[format_param(),quality()],engines=['Pillow'])
def convert(ctx,inputs,p):
    ext=choice(p,'format',FORMATS); q=integer(p,'quality',1,100)
    def one(f,i):
        out=ctx.path(f'{i+1:04d}-{f.stem}.{ext}'); out.write_bytes(encode(load(f),FORMATS[ext],q)); return out
    return each(ctx,inputs,one)

@tool('image.compress','图片','图片压缩',[param('format','输出格式','jpg','choice',['jpg','webp','png','avif']),quality(),param('target_kib','目标 KiB（0=仅质量）','0','number')],engines=['Pillow'])
def compress(ctx,inputs,p):
    ext=choice(p,'format',('jpg','webp','png','avif')); fmt=FORMATS[ext]; q=integer(p,'quality',1,100); target=integer(p,'target_kib',0,10**7)*1024
    def one(f,i):
        im=load(f); data=encode(im,fmt,q)
        if target and len(data)>target:
            for _ in range(30):
                ctx.check()
                if fmt!='PNG':
                    # Size is not strictly monotone; every accepted candidate is measured.
                    low,high=1,q; best=None
                    while low<=high:
                        ctx.check()
                        mid=(low+high)//2; test=encode(im,fmt,mid)
                        if len(test)<=target: best=test; low=mid+1
                        else: high=mid-1
                    if best is not None: data=best; break
                elif len(data)<=target: break
                if im.width==1 and im.height==1: break
                im=im.resize((max(1,int(im.width*.8)),max(1,int(im.height*.8))),Image.Resampling.LANCZOS); data=encode(im,fmt,q)
                if len(data)<=target: break
            if len(data)>target: raise ValueError(f'{f.name}: 无法达到指定大小')
        out = ctx.path(f'{i+1:04d}-{f.stem}.{ext}')
        out.write_bytes(data)
        ctx.result_details[out] = dict(original_bytes=f.stat().st_size, target_bytes=target)
        return out
    return each(ctx,inputs,one)

@tool('image.resize','图片','图片缩放',[param('width','最大宽度','1920','number'),param('height','最大高度','1080','number'),param('keep_ratio','保持比例','true','bool')])
def resize(ctx,inputs,p):
    w=integer(p,'width',1,20000); h=integer(p,'height',1,20000)
    if w*h>80_000_000: raise ValueError('像素数过大')
    def one(f,i):
        im=load(f)
        if truth(p['keep_ratio']): im.thumbnail((w,h),Image.Resampling.LANCZOS)
        else: im=im.resize((w,h),Image.Resampling.LANCZOS)
        out=ctx.path(f'{i+1:04d}-{f.stem}.png'); save_png(im,out); return out
    return each(ctx,inputs,one)

@tool('image.transform','图片','旋转与翻转',[param('rotate','逆时针角度','90','choice',['0','90','180','270']),param('flip','翻转方式','none','choice',['none','horizontal','vertical'])])
def transform(ctx,inputs,p):
    deg=int(choice(p,'rotate',['0','90','180','270'])); flip=choice(p,'flip',['none','horizontal','vertical'])
    def one(f,i):
        im=load(f).rotate(deg,expand=True)
        if flip=='horizontal': im=ImageOps.mirror(im)
        if flip=='vertical': im=ImageOps.flip(im)
        out=ctx.path(f'{i+1:04d}-{f.stem}.png'); save_png(im,out); return out
    return each(ctx,inputs,one)

@tool('image.crop','图片','图片裁剪',[param('left','左','0','number'),param('top','上','0','number'),param('width','宽度','100','number'),param('height','高度','100','number')])
def crop(ctx,inputs,p):
    x=integer(p,'left',0,100000); y=integer(p,'top',0,100000); w=integer(p,'width',1,20000); h=integer(p,'height',1,20000)
    def one(f,i):
        im=load(f)
        if x+w>im.width or y+h>im.height: raise ValueError('裁剪范围超出图片')
        out=ctx.path(f'{i+1:04d}-{f.stem}.png'); save_png(im.crop((x,y,x+w,y+h)),out); return out
    return each(ctx,inputs,one)

@tool('image.stitch','图片','图片拼接',[param('direction','方向','vertical','choice',['vertical','horizontal'])],minimum=2)
def stitch(ctx,inputs,p):
    ims=[]; pixels=0
    for f in inputs:
        ctx.check(); im=load(f); pixels+=im.width*im.height
        if pixels>80_000_000: raise ValueError('拼接像素过大')
        ims.append(im.convert('RGBA'))
    vert=choice(p,'direction',['vertical','horizontal'])=='vertical'
    w=max(im.width for im in ims) if vert else sum(im.width for im in ims); h=sum(im.height for im in ims) if vert else max(im.height for im in ims)
    if w*h>80_000_000: raise ValueError('拼接像素过大')
    canvas=Image.new('RGBA',(w,h),(255,255,255,0)); offset=0
    for im in ims:
        ctx.check(); canvas.alpha_composite(im,(0,offset) if vert else (offset,0)); offset+=im.height if vert else im.width
    out=ctx.path('stitched.png'); canvas.save(out); return [out]

@tool('image.grid','图片','九宫格拼图',[
    param('cell_size','单格边长（像素）','512','number'),
    param('background','背景','white','choice',['white','black','transparent'])
],minimum=2,maximum=9,description='按输入顺序从左到右排列，图片等比缩放，剩余格子保留背景。')
def grid(ctx,inputs,p):
    size=integer(p,'cell_size',32,2048)
    background=choice(p,'background',('white','black','transparent'))
    canvas=Image.new('RGBA',(size*3,size*3),(0,0,0,0) if background=='transparent' else background)
    for i,file in enumerate(inputs):
        ctx.tick(i,len(inputs),file.name)
        tile=ImageOps.contain(load(file).convert('RGBA'),(size,size),Image.Resampling.LANCZOS)
        row,col=divmod(i,3)
        canvas.alpha_composite(tile,(col*size+(size-tile.width)//2,row*size+(size-tile.height)//2))
    output=ctx.path('grid.png')
    canvas.save(output)
    return [output]

def ocr_engine(ctx, lang):
    if not re.fullmatch(r'[A-Za-z0-9_]+(?:\+[A-Za-z0-9_]+)*',lang): raise ValueError('语言代码无效')
    engine=exe('tesseract')
    languages=set(ctx.run([engine,'--list-langs'],timeout=15).splitlines())
    missing=set(lang.split('+'))-languages
    if missing: raise RuntimeError('缺少 OCR 语言包: '+', '.join(sorted(missing)))
    return engine


@tool('image.ocr','图片','图片文字识别',[param('language','Tesseract 语言','chi_sim+eng')],engines=['tesseract'])
def ocr(ctx,inputs,p):
    lang=str(p['language'])
    engine=ocr_engine(ctx, lang)
    def one(f,i):
        out=ctx.path(f'{i+1:04d}-{f.stem}.txt')
        with tempfile.TemporaryDirectory(prefix='ocr-',dir=ctx.root) as folder:
            work=Path(folder)
            save_png(load(f),work/'input.png')
            ctx.run([engine,'input.png','result','-l',lang],cwd=work)
            (work/'result.txt').rename(out)
        return out
    return each(ctx,inputs,one)

@tool('image.watermark','图片','文字水印',[param('text','水印文字','FormaBox'),param('font','字体路径（中文需指定）',''),param('size','字号','32','number')])
def watermark(ctx,inputs,p):
    size=integer(p,'size',8,512); text=str(p['text']); font=ImageFont.truetype(str(p['font']),size) if p['font'] else ImageFont.load_default(size=size)
    def one(f,i):
        im=load(f).convert('RGBA'); layer=Image.new('RGBA',im.size); d=ImageDraw.Draw(layer); d.text((max(4,im.width-8),max(4,im.height-8)),text,anchor='rb',font=font,fill=(255,255,255,180),stroke_width=1,stroke_fill=(0,0,0,150)); out=ctx.path(f'{i+1:04d}-{f.stem}.png'); Image.alpha_composite(im,layer).save(out); return out
    return each(ctx,inputs,one)
