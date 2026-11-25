from .core import *
import zipfile, stat, mimetypes

@tool('file.hash','文件','文件哈希校验',[param('algorithm','算法','sha256','choice',['sha256','sha512','sha1','md5']),param('expected','预期值（单文件，可空）','')])
def hashes(ctx,inputs,p):
    algorithm=choice(p,'algorithm',['sha256','sha512','sha1','md5']); fs=list(regular_files(inputs,ctx)); data=[]
    if not fs: raise ValueError('没有普通文件')
    if p['expected'] and len(fs)!=1: raise ValueError('预期哈希只支持单文件')
    for i,f in enumerate(fs):
        ctx.tick(i,len(fs),f.name); h=digest(f,algorithm,ctx); data.append(dict(file=output_path(f),algorithm=algorithm,hash=h,match=h.lower()==str(p['expected']).strip().lower() if p['expected'] else None))
    return report(ctx,'hashes.json',data)

@tool('file.duplicates','文件','重复文件查找（仅报告）')
def duplicates(ctx,inputs,p):
    sizes={}; groups={}
    for f in regular_files(inputs,ctx): sizes.setdefault(f.stat().st_size,[]).append(f)
    for fs in sizes.values():
        if len(fs)>1:
            for f in fs: ctx.check(); groups.setdefault(digest(f,ctx=ctx),[]).append(output_path(f))
    return report(ctx,'duplicates.json',[dict(sha256=h,files=fs) for h,fs in groups.items() if len(fs)>1])

@tool('file.rename','文件','批量重命名（复制）',[param('prefix','前缀','file-'),param('start','起始序号','1','number'),param('digits','序号位数','4','number'),param('keep_name','保留原文件名','false','bool')])
def rename(ctx,inputs,p):
    start=integer(p,'start',0,10**9); digits=integer(p,'digits',1,12); out=[]; fs=list(regular_files(inputs,ctx))
    for i,f in enumerate(fs):
        ctx.tick(i,len(fs),f.name); name=str(p['prefix'])+str(i+start).zfill(digits)+('-'+f.stem if truth(p['keep_name']) else '')+f.suffix; dest=ctx.path(name); copy_file(ctx,f,dest); out.append(dest)
    return out

@tool('file.large','文件','大文件查找',[param('limit_mib','最小 MiB','100','number')])
def large(ctx,inputs,p):
    threshold=number(p,'limit_mib',0,1e9)*1024**2; data=[]
    for f in regular_files(inputs,ctx):
        size=f.stat().st_size
        if size>=threshold: data.append(dict(file=output_path(f),size=size))
    return report(ctx,'large-files.json',sorted(data,key=lambda x:x['size'],reverse=True))

@tool('file.empty_dirs','文件','空目录查找（仅报告）',description='查找完全没有条目的目录。链接或权限错误不会被计为空目录。')
def empty_directories(ctx,inputs,p):
    directories=set()
    for path in inputs:
        if not path.is_dir():
            raise ValueError('请选择文件夹')
        for folder,_,empty in walk_tree(path,ctx):
            if empty:
                directories.add(output_path(folder))
    return report(ctx,'empty-directories.json',sorted(directories))

@tool('file.identify','文件','文件真实类型识别')
def identify(ctx,inputs,p):
    data=[]
    for f in regular_files(inputs,ctx):
        with f.open('rb') as stream: h=stream.read(64)
        kind='unknown'; ext=[]
        for sig,k,e in [(b'%PDF-','PDF',['.pdf']),(b'\x89PNG\r\n\x1a\n','PNG',['.png']),(b'\xff\xd8\xff','JPEG',['.jpg','.jpeg']),(b'GIF8','GIF',['.gif']),(b'PK\x03\x04','ZIP/container',['.zip','.docx','.xlsx','.pptx','.epub','.jar','.apk']),(b'MZ','Windows PE/EXE candidate',['.exe','.dll','.sys','.scr']),(b'\x7fELF','ELF',[])]:
            if h.startswith(sig): kind=k; ext=e; break
        if h[4:8]==b'ftyp': kind='ISO-BMFF'; ext=['.mp4','.mov','.m4a','.heic','.heif','.avif']
        if h.startswith(b'RIFF') and h[8:12]==b'WEBP': kind='WebP'; ext=['.webp']
        data.append(dict(file=output_path(f),signature=kind,extension_mismatch=bool(ext and f.suffix.lower() not in ext),extension_guess=mimetypes.guess_type(f.name)[0]))
    return report(ctx,'types.json',data)

@tool('file.split','文件','大文件分割',[param('size_mib','每部分 MiB','64','number')],maximum=1)
def split(ctx,inputs,p):
    limit=integer(p,'size_mib',1,4096)*1024**2; f=inputs[0]; parts=[]; meta=[]; whole=hashlib.sha256()
    with f.open('rb') as src:
        i=0
        while True:
            ctx.check(); b=src.read(min(limit,1024**2))
            if not b: break
            i+=1; dest=ctx.path(f'part-{i:06d}.bin'); h=hashlib.sha256(); count=0
            with dest.open('wb') as out:
                while b:
                    ctx.check(); out.write(b); h.update(b); whole.update(b); count+=len(b)
                    if count==limit: break
                    b=src.read(min(limit-count,1024**2))
            parts.append(dest); meta.append(dict(name=dest.name,size=count,sha256=h.hexdigest()))
    manifest=report(ctx,'parts.json',dict(name=f.name,parts=meta,sha256=whole.hexdigest()))[0]
    return [manifest,*parts]

@tool('file.join','文件','合并已分割文件（选择 parts.json）',maximum=1)
def join(ctx,inputs,p):
    manifest=inputs[0]; meta=json.loads(manifest.read_text(encoding='utf-8')); out=ctx.path(meta['name']); whole=hashlib.sha256()
    with out.open('wb') as dest:
        for part in meta['parts']:
            f=manifest.parent/safe_name(part['name']); h=hashlib.sha256(); size=0
            if path_is_link(f) or not f.is_file(): raise ValueError('分片不是普通文件')
            with f.open('rb') as src:
                for b in iter(lambda:src.read(1024**2),b''): ctx.check(); dest.write(b); whole.update(b); h.update(b); size+=len(b)
            if size!=part['size'] or h.hexdigest()!=part['sha256']: raise ValueError('分片校验失败')
    if whole.hexdigest()!=meta['sha256']: raise ValueError('完整文件校验失败')
    return [out]

@tool('file.zip','文件','ZIP 压缩')
def zip_files(ctx,inputs,p):
    out = ctx.path('archive.zip')
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
        def add_file(file, member):
            ctx.check()
            with file.open('rb') as src, archive.open(member.as_posix(), 'w', force_zip64=True) as dest:
                copy_content(ctx, src, dest)

        for index, source in enumerate(inputs, 1):
            if source.is_symlink():
                raise ValueError('不支持符号链接输入')
            member = Path(f'{index:04d}-{source.name}')
            base = extended_path(source)
            if base.is_file():
                add_file(base, member)
                continue

            for folder, names, empty in walk_tree(base, ctx):
                directory = member / folder.relative_to(base)
                if empty:
                    archive.mkdir(directory.as_posix())
                for name in names:
                    ctx.check()
                    file = folder / name
                    if not path_is_link(file) and file.is_file():
                        add_file(file, directory / name)

    return [out]

@tool('file.unzip','文件','安全解压 ZIP',[param('max_mib','最大解压 MiB','4096','number')])
def unzip(ctx,inputs,p):
    cap=integer(p,'max_mib',1,1048576)*1024**2; total=0; entries=0; results=[]
    for i,f in enumerate(inputs):
        root=ctx.path(f'{i+1:04d}-{f.stem}'); root.mkdir(); used={}; explicit=set()
        with zipfile.ZipFile(f) as z:
            infos=z.infolist()
            entries+=len(infos)
            if entries>100000: raise ValueError('ZIP 条目过多')
            if sum(x.file_size for x in infos)+total>cap: raise ValueError('超出解压大小限制')
            for info in infos:
                ctx.check(); name=info.filename.replace('\\','/'); parts=name.rstrip('/').split('/')
                if not parts: raise ValueError('无效 ZIP 路径')
                mode=info.external_attr>>16
                if info.external_attr & stat.FILE_ATTRIBUTE_REPARSE_POINT or stat.S_IFMT(mode) not in (0,stat.S_IFREG,stat.S_IFDIR):
                    raise ValueError('ZIP 含特殊文件')
                if stat.S_IFMT(mode) and stat.S_ISDIR(mode) != info.is_dir():
                    raise ValueError('ZIP 条目类型无效')
                for depth, part in enumerate(parts, 1):
                    safe_name(part)
                    original=tuple(parts[:depth]); key=tuple(x.casefold() for x in original)
                    directory=depth<len(parts) or info.is_dir()
                    entry=(original,directory)
                    if used.setdefault(key,entry)!=entry: raise ValueError('ZIP 路径冲突')
                if key in explicit: raise ValueError('ZIP 路径冲突')
                explicit.add(key)
                dest=root.joinpath(*parts)
                if info.is_dir(): dest.mkdir(parents=True,exist_ok=True); continue
                dest.parent.mkdir(parents=True,exist_ok=True)
                with z.open(info) as src,dest.open('xb') as out:
                    for b in iter(lambda:src.read(1024**2),b''):
                        ctx.check(); total+=len(b)
                        if total>cap: raise ValueError('超出解压大小限制')
                        out.write(b)
        results.append(root)
    return results

@tool('file.compare','文件','目录差异比较（两个文件夹）',minimum=2,maximum=2)
def compare(ctx,inputs,p):
    if not all(f.is_dir() for f in inputs): raise ValueError('需要两个文件夹')
    maps=[]
    for root in inputs: maps.append({str(f.relative_to(extended_path(root))):digest(f,ctx=ctx) for f in regular_files([root],ctx)})
    a,b=maps; return report(ctx,'directory-diff.json',dict(only_left=sorted(a.keys()-b.keys()),only_right=sorted(b.keys()-a.keys()),changed=sorted(k for k in a.keys()&b.keys() if a[k]!=b[k])))

@tool('file.classify','文件','按扩展名分类（复制）')
def classify(ctx,inputs,p):
    out=[]; count=0
    for f in regular_files(inputs,ctx):
        ctx.check(); ext=f.suffix.lower().lstrip('.') or 'no-extension'; ext=safe_name(ext); root=ctx.root/ext; root.mkdir(exist_ok=True); count+=1; dest=root/safe_name(f'{count:05d}-{f.name}'); copy_file(ctx,f,dest); out.append(dest)
    return out
