from __future__ import annotations
import hashlib, json, os, re, shutil, stat, subprocess, tempfile, time, uuid
from pathlib import Path
from dataclasses import dataclass, field

TOOLS = {}
class Cancelled(Exception): pass

def param(key, label, default='', kind='text', choices=None):
    return dict(key=key,label=label,default=default,kind=kind,choices=choices or [])

def tool(id, category, label, params=(), minimum=1, maximum=0, description='', engines=()):
    def wrap(fn):
        TOOLS[id] = (dict(id=id,category=category,label=label,params=list(params),minimum=minimum,maximum=maximum,description=description,engines=list(engines)),fn)
        return fn
    return wrap

def emit(event, **fields):
    print(json.dumps(dict(event=event,**fields), ensure_ascii=False),flush=True)

def integer(p,k,lo,hi):
    try: v=int(p[k])
    except (ValueError,TypeError,KeyError,OverflowError): raise ValueError(f'{k}: 需要整数') from None
    if isinstance(p[k], bool) or (isinstance(p[k], float) and p[k] != v):
        raise ValueError(f'{k}: 需要整数')
    if not lo<=v<=hi: raise ValueError(f'{k}: 范围 {lo}–{hi}')
    return v

def number(p,k,lo,hi):
    try: v=float(p[k])
    except (ValueError,TypeError,KeyError): raise ValueError(f'{k}: 需要数字') from None
    if not lo<=v<=hi: raise ValueError(f'{k}: 范围 {lo}–{hi}')
    return v

def choice(p,k,allowed):
    v=str(p[k]).lower()
    if v not in allowed: raise ValueError(f'{k}: 不支持 {v}')
    return v

def truth(v): return str(v).lower() in ('1','true','yes','on')

def safe_name(s):
    if not isinstance(s, str) or not s or any(c in s for c in '/\\:*?"<>|') or any(ord(c)<32 for c in s) or s.endswith(('.', ' ')):
        raise ValueError(f'不安全的文件名: {s!r}')
    device = s.partition('.')[0].rstrip(' ')
    if re.fullmatch(r'(?i)(con|prn|aux|nul|conin\$|conout\$|com[1-9¹²³]|lpt[1-9¹²³])', device):
        raise ValueError(f'不安全的文件名: {s!r}')
    return s

def path_is_link(path):
    info = path.lstat()
    return stat.S_ISLNK(info.st_mode) or bool(
        getattr(info, 'st_file_attributes', 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT
    )

def extended_path(path):
    if os.name!='nt':
        return path
    name=str(path)
    if name.startswith('\\\\?\\'):
        return path
    if name.startswith('\\\\'):
        return Path('\\\\?\\UNC\\'+name[2:])
    return Path('\\\\?\\'+name)

def display_path(path):
    if os.name!='nt':
        return path
    name=str(path)
    if name.upper().startswith('\\\\?\\UNC\\'):
        return Path('\\\\'+name[8:])
    if name.startswith('\\\\?\\') and len(name)>5 and name[5]==':':
        return Path(name[4:])
    return path

def output_path(path):
    plain=display_path(path)
    return str(plain if len(str(plain))<248 else path)

def checked_path(value, *, allow_missing=False):
    if not isinstance(value, str) or not value.strip():
        raise ValueError('需要有效的文件或目录路径')
    path = Path(value).expanduser()
    if path.drive and not path.is_absolute():
        raise ValueError(f'路径需要明确指定位置: {value}')
    path = path.absolute()
    if os.name=='nt':
        if path.drive.upper().startswith(('\\\\.\\','\\\\?\\GLOBALROOT')):
            raise ValueError('不支持 Windows 设备路径')
        if any(':' in part for part in path.parts[1:]):
            raise ValueError('不支持 Windows 备用数据流路径')
    absolute=Path(os.path.abspath(path))
    for candidate in dict.fromkeys((path,absolute)):
        for component in (*reversed(candidate.parents),candidate):
            try:
                linked=path_is_link(extended_path(component) if len(str(component))>=248 else component)
            except FileNotFoundError:
                if not allow_missing:
                    raise
                break
            if linked:
                raise ValueError(f'不支持链接或重解析点: {component}')
    return (extended_path(absolute) if len(str(absolute))>=248 else absolute).resolve()

BUNDLED_EXECUTABLES = {
    'ffmpeg': 'ffmpeg/ffmpeg.exe',
    'tesseract': 'tesseract/tesseract.exe',
    'soffice': 'libreoffice/program/soffice.com',
}


def bundled_engine(name):
    relative = BUNDLED_EXECUTABLES.get(name)
    if relative is None or os.name != 'nt':
        return None
    candidate = Path(__file__).resolve().parents[2] / 'engines' / relative
    return str(candidate) if candidate.is_file() else None


def find_executable(name):
    variable = {'ffmpeg': 'FORMABOX_FFMPEG', 'tesseract': 'FORMABOX_TESSERACT'}.get(name)
    configured = os.environ.get(variable) if variable else None
    if configured:
        candidate = Path(configured)
        if candidate.is_absolute() and candidate.is_file() and (os.name != 'nt' or candidate.suffix.lower() == '.exe'):
            return str(candidate)
        return None
    if bundled := bundled_engine(name):
        return bundled
    if os.name!='nt':
        return shutil.which(name)
    for directory in os.get_exec_path():
        root=Path(directory)
        if root.is_absolute():
            for suffix in ('.exe','.com'):
                candidate=root/(name+suffix)
                if candidate.is_file(): return str(candidate)
    return None

def exe(name):
    path=find_executable(name)
    if not path: raise RuntimeError(f'缺少外部工具 {name}，请查看安装说明')
    return path

@dataclass
class Context:
    root: Path
    cancel: Path | None = None
    progress: object = emit
    result_details: dict = field(default_factory=dict)
    def check(self):
        if self.cancel and self.cancel.exists(): raise Cancelled('任务已取消')
    def tick(self, current, total, message=''):
        self.check(); self.progress('progress',current=current,total=total,message=message)
    def path(self,name):
        p=self.root/safe_name(name)
        if p.exists(): raise FileExistsError(f'输出名称冲突: {name}')
        return p
    def run(self,args,timeout=3600,cwd=None,*,stdin_file=None,stdout_file=None):
        self.check()
        with tempfile.TemporaryFile() as out:
            kwargs=dict(stdin=stdin_file if stdin_file is not None else subprocess.DEVNULL,
                        stdout=stdout_file if stdout_file is not None else out,
                        stderr=out if stdout_file is not None else subprocess.STDOUT, shell=False, cwd=cwd)
            if os.name=='nt': kwargs['creationflags']=subprocess.CREATE_NO_WINDOW
            proc=subprocess.Popen([str(a) for a in args],**kwargs)
            started=time.monotonic()
            try:
                while True:
                    if os.fstat(out.fileno()).st_size>16*1024**2: raise RuntimeError('外部工具日志超出限制')
                    if stdout_file is not None and os.fstat(stdout_file.fileno()).st_size > 64*1024**2:
                        raise RuntimeError('外部工具输出超出 64 MiB')
                    if proc.poll() is not None:
                        break
                    self.check()
                    if time.monotonic()-started>timeout: raise TimeoutError('外部工具运行超时')
                    time.sleep(.1)
            finally:
                if proc.poll() is None: proc.kill(); proc.wait()
            out.seek(0,2); end=out.tell(); out.seek(max(0,end-8192)); msg=out.read().decode('utf-8','replace')
            if proc.returncode: raise RuntimeError(f'外部工具失败 ({proc.returncode}): {msg}')
            return msg

def digest(path, algorithm='sha256', ctx=None):
    h=hashlib.new(algorithm)
    with path.open('rb') as f:
        for data in iter(lambda:f.read(1024*1024),b''):
            if ctx: ctx.check()
            h.update(data)
    return h.hexdigest()

def walk_tree(path,ctx=None):
    def raise_walk_error(error):
        raise error

    for root,directories,names in os.walk(extended_path(path),onerror=raise_walk_error):
        if ctx:
            ctx.check()
        folder=Path(root)
        empty=not directories and not names
        directories[:]=sorted(name for name in directories if not path_is_link(folder/name))
        yield folder,sorted(names),empty

def regular_files(paths,ctx=None):
    def children(path):
        if path.is_file():
            yield extended_path(path)
            return
        for folder,names,_ in walk_tree(path,ctx):
            yield from (folder/name for name in names)

    seen = set()
    for path in paths:
        for file in children(path):
            if ctx:
                ctx.check()
            if path_is_link(file) or not file.is_file():
                continue
            key = os.path.normcase(str(display_path(file)))
            if key not in seen:
                seen.add(key)
                yield file

def copy_content(ctx, source, destination):
    while block := source.read(1024**2):
        ctx.check()
        destination.write(block)

def copy_file(ctx, source, destination):
    with source.open('rb') as original, destination.open('xb') as copied:
        copy_content(ctx, original, copied)
    if os.name=='nt':
        times=source.stat()
        os.utime(destination,ns=(times.st_atime_ns,times.st_mtime_ns))
    else:
        shutil.copystat(source,destination)

def report(ctx,name,data):
    path=ctx.path(name); path.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8'); return [path]

def invoke(id,inputs,params,ctx):
    if not isinstance(id, str) or id not in TOOLS: raise ValueError(f'未知工具: {id}')
    spec,fn=TOOLS[id]
    if len(inputs)<spec['minimum'] or (spec['maximum'] and len(inputs)>spec['maximum']): raise ValueError('输入文件数量不符合要求')
    for p in inputs:
        if path_is_link(p) or not (p.is_file() or p.is_dir()):
            raise ValueError(f'需要普通文件或目录: {p}')
    if not isinstance(params, dict):
        raise ValueError('工具参数必须为对象')
    defaults={p['key']:p['default'] for p in spec['params']}
    unknown=set(params)-set(defaults)
    if unknown: raise ValueError('未知参数: '+','.join(sorted(unknown)))
    defaults.update(params)
    ctx.check(); results=fn(ctx,inputs,defaults); ctx.check()
    if not results:
        raise ValueError('没有可处理的文件')
    for p in results:
        if not p.is_relative_to(ctx.root) or path_is_link(p) or not (p.is_file() or p.is_dir()):
            raise RuntimeError('无效输出')
    return results

def execute(req,progress=emit):
    from . import imageops,pdfops,mediaops,fileops,textops,privacyops # register
    if not isinstance(req, dict) or not isinstance(req.get('inputs'), list) or not req['inputs']:
        raise ValueError('请选择输入文件或目录')
    if ('steps' in req) == ('tool' in req):
        raise ValueError('请指定单个工具或工作流')
    steps = req.get('steps')
    if 'steps' in req and (not isinstance(steps, list) or not 1 <= len(steps) <= 32 or
                           not all(isinstance(step, dict) for step in steps)):
        raise ValueError('工作流需要 1–32 个有效步骤')
    cancel_value = req.get('cancel')
    if cancel_value is not None and not isinstance(cancel_value, str):
        raise ValueError('取消标记需要有效的文件路径')
    cancel = Path(cancel_value).absolute() if cancel_value else None
    inputs=[checked_path(x) for x in req['inputs']]
    output=extended_path(checked_path(req.get('output'),allow_missing=True))
    job=uuid.uuid4().hex[:12]; final=output/f'FormaBox-{job}'
    if any(p.is_dir() and display_path(output).is_relative_to(display_path(p)) for p in inputs): raise ValueError('输出目录不能位于输入文件夹内部')
    output.mkdir(parents=True,exist_ok=True)
    staging=Path(tempfile.mkdtemp(prefix='.formabox-',dir=output))
    try:
        if steps is not None:
            def step_progress(event, current, total, message):
                if total > 0:
                    current = index + current / total
                    total = len(steps)
                progress(event, current=current, total=total, message=message)

            results = inputs
            for index, step in enumerate(steps):
                root = staging / f'{index + 1:02d}'
                root.mkdir()
                ctx = Context(root, cancel, step_progress)
                ctx.tick(0, 1, f'工作流 {index + 1}/{len(steps)}')
                results = invoke(step.get('tool'), results, step.get('params', {}), ctx)
        else:
            ctx=Context(staging,cancel,progress)
            results=invoke(req['tool'],inputs,req.get('params',{}),ctx)
        relative=[str(p.relative_to(staging)) for p in results]
        details = [ctx.result_details.get(path, {}) for path in results]
        if cancel and cancel.exists(): raise Cancelled('任务已取消')
        if final.exists(): raise FileExistsError(str(final))
        staging.rename(final)
        result = dict(directory=output_path(final),files=[output_path(final/p) for p in relative])
        if any(details):
            result['details'] = details
        return result
    finally:
        if staging.exists(): shutil.rmtree(staging,ignore_errors=True)
