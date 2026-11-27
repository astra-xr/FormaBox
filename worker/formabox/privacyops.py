from .core import *
from cryptography.hazmat.primitives.ciphers import Cipher,algorithms,modes
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
from cryptography.exceptions import InvalidTag
from PIL import Image
MAGIC=b'FBXENC\x01'
def key(password,salt): return Scrypt(salt=salt,length=32,n=2**15,r=8,p=1).derive(password.encode('utf-8'))

@tool('privacy.encrypt','隐私','文件加密 AES-256-GCM',[param('password','密码（至少 12 字符）','','password')])
def encrypt(ctx,inputs,p):
    pw=str(p['password'])
    if len(pw)<12: raise ValueError('密码至少 12 字符')
    out=[]
    for i,f in enumerate(inputs):
        ctx.check(); salt=os.urandom(16); nonce=os.urandom(12); header=MAGIC+salt+nonce; cipher=Cipher(algorithms.AES(key(pw,salt)),modes.GCM(nonce)).encryptor(); cipher.authenticate_additional_data(header); dest=ctx.path(f'{i+1:04d}-{f.name}.fbx')
        with f.open('rb') as a,dest.open('wb') as b:
            b.write(header)
            for block in iter(lambda:a.read(1024**2),b''): ctx.check(); b.write(cipher.update(block))
            b.write(cipher.finalize()); b.write(cipher.tag)
        out.append(dest)
    return out

@tool('privacy.decrypt','隐私','文件解密 Omnora',[param('password','密码','','password')])
def decrypt(ctx,inputs,p):
    pw=str(p['password']); out=[]; hlen=len(MAGIC)+28
    for i,f in enumerate(inputs):
        ctx.check(); size=f.stat().st_size
        if size<hlen+16: raise ValueError('文件格式无效')
        with f.open('rb') as a:
            header=a.read(hlen)
            if not header.startswith(MAGIC): raise ValueError('不是万象加密文件')
            salt=header[len(MAGIC):len(MAGIC)+16]; nonce=header[-12:]; a.seek(-16,2); tag=a.read(16); a.seek(hlen)
            cipher=Cipher(algorithms.AES(key(pw,salt)),modes.GCM(nonce,tag)).decryptor(); cipher.authenticate_additional_data(header); dest=ctx.path(f'{i+1:04d}-{f.stem}'); remaining=size-hlen-16
            with tempfile.TemporaryFile(dir=ctx.root) as b:
                while remaining:
                    ctx.check(); block=a.read(min(remaining,1024**2))
                    if not block: raise ValueError('文件被截断')
                    remaining-=len(block); b.write(cipher.update(block))
                try: b.write(cipher.finalize())
                except InvalidTag: raise ValueError('密码错误或文件被篡改') from None
                ctx.check(); b.seek(0)
                with dest.open('xb') as verified:
                    copy_content(ctx,b,verified)
        out.append(dest)
    return out

@tool('privacy.image_clean','隐私','图片元数据清理（无元数据 PNG）')
def image_clean(ctx,inputs,p):
    from .imageops import load
    out=[]
    for i,f in enumerate(inputs):
        ctx.check(); im=load(f).convert('RGBA'); clean=Image.new('RGBA',im.size); clean.paste(im); dest=ctx.path(f'{i+1:04d}-{f.stem}.png'); clean.save(dest); out.append(dest)
    return out

@tool('privacy.image_info','隐私','图片 EXIF 查看（报告）')
def info(ctx,inputs,p):
    from PIL.ExifTags import TAGS,GPSTAGS
    data=[]
    for f in inputs:
        ctx.check()
        with Image.open(f) as im:
            ex=im.getexif(); values={TAGS.get(k,str(k)):str(v)[:4096] for k,v in ex.items()}
            if 34853 in ex:
                values['GPSInfo']={GPSTAGS.get(k,str(k)):str(v) for k,v in ex.get_ifd(34853).items()}
            data.append(dict(file=str(f),size=im.size,format=im.format,exif=values,metadata_keys=list(im.info.keys())))
    return report(ctx,'metadata.json',data)

@tool('privacy.image_redact','隐私','图片矩形遮盖（重新编码）',[param('x','左','0','number'),param('y','上','0','number'),param('width','宽','100','number'),param('height','高','100','number')])
def redact(ctx,inputs,p):
    from .imageops import load
    x=integer(p,'x',0,100000); y=integer(p,'y',0,100000); w=integer(p,'width',1,100000); h=integer(p,'height',1,100000); out=[]
    for i,f in enumerate(inputs):
        ctx.check(); im=load(f).convert('RGBA')
        if x+w>im.width or y+h>im.height: raise ValueError('遮盖区域超出图片')
        clean=Image.new('RGBA',im.size); clean.paste(im); clean.paste((0,0,0,255),(x,y,x+w,y+h)); dest=ctx.path(f'{i+1:04d}-{f.stem}.png'); clean.save(dest); out.append(dest)
    return out
