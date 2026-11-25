from .core import *
import csv, codecs

@tool('text.encoding','文档','文本编码转换',[param('source','原编码','utf-8','choice',['utf-8','utf-8-sig','gbk','gb18030','utf-16']),param('target','目标编码','utf-8','choice',['utf-8','utf-8-sig','gbk','gb18030','utf-16'])])
def encoding(ctx,inputs,p):
    allowed=['utf-8','utf-8-sig','gbk','gb18030','utf-16']; src=choice(p,'source',allowed); dst=choice(p,'target',allowed); out=[]
    for i,f in enumerate(inputs):
        ctx.check(); dest=ctx.path(f'{i+1:04d}-{f.name}')
        decoder=codecs.getincrementaldecoder(src)()
        encoder=codecs.getincrementalencoder(dst)()
        with f.open('rb') as source, dest.open('xb') as target:
            while block:=source.read(1024**2):
                ctx.check()
                target.write(encoder.encode(decoder.decode(block)))
            target.write(encoder.encode(decoder.decode(b'',final=True),final=True))
        out.append(dest)
    return out

@tool('text.clean','文档','文本去重与空行清理',[param('dedup','删除重复行','true','bool'),param('blank','删除空白行','true','bool')])
def clean(ctx,inputs,p):
    out=[]
    for i,f in enumerate(inputs):
        seen=set(); dest=ctx.path(f'{i+1:04d}-{f.stem}.txt')
        with f.open(encoding='utf-8-sig') as a,dest.open('w',encoding='utf-8') as b:
            for line in a:
                ctx.check(); line=line.rstrip('\r\n')
                if truth(p['blank']) and not line.strip(): continue
                if truth(p['dedup']):
                    if line in seen: continue
                    seen.add(line)
                b.write(line+'\n')
        out.append(dest)
    return out

@tool('text.replace','文档','文本批量替换（字面匹配）',[param('find','查找',''),param('replace','替换为','')])
def replace(ctx,inputs,p):
    if not p['find']: raise ValueError('查找内容不能为空')
    out=[]
    for i,f in enumerate(inputs):
        ctx.check(); dest=ctx.path(f'{i+1:04d}-{f.name}'); dest.write_text(f.read_text(encoding='utf-8-sig').replace(str(p['find']),str(p['replace'])),encoding='utf-8'); out.append(dest)
    return out

@tool('text.diff','文档','文本差异对比',minimum=2,maximum=2)
def diff(ctx,inputs,p):
    import difflib
    a,b=inputs; dest=ctx.path('diff.txt')
    changes=difflib.unified_diff(a.read_text(encoding='utf-8-sig').splitlines(keepends=True),b.read_text(encoding='utf-8-sig').splitlines(keepends=True),fromfile=a.name,tofile=b.name)
    with dest.open('w',encoding='utf-8') as out:
        for line in changes:
            ctx.check()
            out.write(line if line.endswith('\n') else line+'\n\\ No newline at end of file\n')
    return [dest]

@tool('text.stats','文档','文本统计')
def stats(ctx,inputs,p):
    data=[]
    for f in inputs:
        ctx.check(); t=f.read_text(encoding='utf-8-sig'); data.append(dict(file=str(f),characters=len(t),non_whitespace=sum(not c.isspace() for c in t),whitespace_separated_tokens=len(t.split()),lines=len(t.splitlines())))
    return report(ctx,'statistics.json',data)

@tool('data.json','文档','JSON 格式化 / 压缩',[param('compact','压缩','false','bool')])
def jsonfmt(ctx,inputs,p):
    out=[]
    for i,f in enumerate(inputs):
        ctx.check(); obj=json.loads(f.read_text(encoding='utf-8-sig'),parse_constant=lambda s: (_ for _ in ()).throw(ValueError('非标准 JSON: '+s))); dest=ctx.path(f'{i+1:04d}-{f.stem}.json'); dest.write_text(json.dumps(obj,ensure_ascii=False,allow_nan=False,separators=(',',':') if truth(p['compact']) else None,indent=None if truth(p['compact']) else 2),encoding='utf-8'); out.append(dest)
    return out

@tool('data.csv_json','文档','CSV 转 JSON')
def csvjson(ctx,inputs,p):
    out=[]
    for i,f in enumerate(inputs):
        ctx.check(); dest=ctx.path(f'{i+1:04d}-{f.stem}.json')
        with f.open(encoding='utf-8-sig',newline='') as a:
            r=csv.DictReader(a); rows=[]
            if not r.fieldnames or not all(name.strip() for name in r.fieldnames) or len(set(r.fieldnames))!=len(r.fieldnames): raise ValueError('CSV 表头为空或重复')
            for row in r:
                ctx.check()
                if None in row or None in row.values(): raise ValueError('CSV 行字段数量不一致')
                rows.append(row)
        dest.write_text(json.dumps(rows,ensure_ascii=False,indent=2),encoding='utf-8'); out.append(dest)
    return out

@tool('data.json_csv','文档','JSON 转 CSV',[param('spreadsheet_safe','电子表格公式保护','true','bool')],
      description='输入为对象数组。空值写为空字段，数组和对象作为 JSON 文本写入单元格。')
def jsoncsv(ctx,inputs,p):
    protect=truth(p['spreadsheet_safe'])
    def cell(value):
        if value is None:
            return ''
        if isinstance(value,str):
            if protect and (value.startswith(('\r','\n','\t')) or value.lstrip().startswith(('=','+','-','@','＝','＋','－','＠'))):
                return "'"+value
            return value
        return json.dumps(value,ensure_ascii=False,allow_nan=False,separators=(',',':'))

    outputs=[]
    for index,file in enumerate(inputs):
        ctx.tick(index,len(inputs),file.name)
        rows=json.loads(file.read_text(encoding='utf-8-sig'))
        if not isinstance(rows,list) or not all(isinstance(row,dict) for row in rows):
            raise ValueError('JSON 顶层需要是对象数组')
        keys=list(dict.fromkeys(key for row in rows for key in row))
        headers=[cell(key) for key in keys]
        if not headers or not all(key.strip() for key in headers) or len(set(headers))!=len(keys):
            raise ValueError('字段名称不能为空或冲突')
        output=ctx.path(f'{index+1:04d}-{file.stem}.csv')
        with output.open('x',encoding='utf-8-sig',newline='') as stream:
            writer=csv.writer(stream)
            writer.writerow(headers)
            for row in rows:
                ctx.check()
                writer.writerow(cell(row.get(key)) for key in keys)
        outputs.append(output)
    return outputs

def office_engine():
    configured=os.environ.get('FORMABOX_SOFFICE')
    if configured:
        candidate=Path(configured)
        if candidate.is_absolute() and candidate.is_file() and (os.name!='nt' or candidate.suffix.lower() in ('.exe','.com')):
            return str(candidate)
        return None
    if os.name=='nt':
        for name in ('ProgramFiles','ProgramFiles(x86)'):
            base=os.environ.get(name)
            if base:
                for binary in ('soffice.com','soffice.exe'):
                    candidate=Path(base)/'LibreOffice'/'program'/binary
                    if candidate.is_file(): return str(candidate)
    return find_executable('soffice') or find_executable('libreoffice')

@tool('doc.pdf','文档','Office 转 PDF',engines=['LibreOffice'])
def office(ctx,inputs,p):
    engine=office_engine()
    if not engine: raise RuntimeError('未找到 LibreOffice')
    if not all(f.suffix.lower() in ('.docx','.doc','.xlsx','.xls','.pptx','.ppt','.odt','.ods','.odp','.rtf') for f in inputs): raise ValueError('不支持该文档格式')
    out=[]
    for i,f in enumerate(inputs):
        ctx.tick(i,len(inputs),f.name)
        with tempfile.TemporaryDirectory(prefix='formabox-lo-') as td:
            root=Path(td); profile=(root/'profile').as_uri(); target=root/'out'; target.mkdir()
            ctx.run([engine,'-env:UserInstallation='+profile,'--headless','--convert-to','pdf','--outdir',str(target),str(f)],timeout=300)
            result=target/(f.stem+'.pdf')
            if not result.exists() or not result.stat().st_size: raise RuntimeError('LibreOffice 未生成 PDF')
            dest=ctx.path(f'{i+1:04d}-{f.stem}.pdf'); copy_file(ctx,result,dest); out.append(dest)
    return out
