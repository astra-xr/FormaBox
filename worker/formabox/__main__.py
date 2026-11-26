import argparse
import importlib.util
import json
import sys
from pathlib import Path
from .core import TOOLS, execute, emit, Cancelled, find_executable
from . import imageops,pdfops,mediaops,fileops,textops,privacyops

def engine_availability():
    return {
        'Pillow': True,
        'pypdf': True,
        'pypdfium2': importlib.util.find_spec('pypdfium2') is not None,
        'ffmpeg': find_executable('ffmpeg') is not None,
        'tesseract': find_executable('tesseract') is not None,
        'LibreOffice': textops.office_engine() is not None,
    }

def error_message(error, request):
    message=str(error)
    if not isinstance(request,dict):
        return message
    steps=request.get('steps')
    items=steps if isinstance(steps,list) else [request]
    secrets=set()
    for item in items:
        if not isinstance(item,dict):
            continue
        params=item.get('params')
        if isinstance(params,dict) and params.get('password'):
            secrets.add(str(params['password']))
    for secret in sorted(secrets,key=len,reverse=True):
        message=message.replace(secret,'[已隐藏]')
    return message

def main():
    sys.stdout.reconfigure(encoding='utf-8',errors='replace')
    parser=argparse.ArgumentParser()
    sub=parser.add_subparsers(dest='command',required=True)
    catalogue=sub.add_parser('list',help='列出可配置的工具')
    catalogue.add_argument('--check-engines',action='store_true',help='附上当前环境缺少的引擎')
    sub.add_parser('doctor',help='检查本地依赖')
    sub.add_parser('check-engines', help='使用样本运行外部引擎')
    sub.add_parser('preview-pdf', help='从 stdin 读取页面工作台预览请求')
    sub.add_parser('preview-pdf-compression', help='从 stdin 读取 PDF 压缩预览请求')
    run=sub.add_parser('run',help='执行单个工具或工作流')
    run.add_argument('--request',required=True,help='JSON 请求路径，或 - 从 stdin 读取')
    args=parser.parse_args()
    if args.command=='doctor':
        print(json.dumps(engine_availability(),ensure_ascii=False))
        return 0
    if args.command in ('check-engines', 'preview-pdf', 'preview-pdf-compression'):
        try:
            if args.command == 'preview-pdf':
                from .pdfworkbench import preview_pages
                result = preview_pages(json.load(sys.stdin.buffer))
            elif args.command == 'preview-pdf-compression':
                from .pdfworkbench import preview_compression
                result = preview_compression(json.load(sys.stdin.buffer))
            else:
                from .engines import check_engines
                result = check_engines()
            print(json.dumps({'result': result}, ensure_ascii=False))
            return 0
        except Exception as error:
            print(json.dumps({'error': str(error)}, ensure_ascii=False))
            return 1
    if args.command=='list':
        specs=[spec for spec,_ in TOOLS.values()]
        if args.check_engines:
            availability=engine_availability()
            specs=[dict(spec,missing_engines=[engine for engine in spec['engines'] if not availability.get(engine)]) for spec in specs]
        print(json.dumps(specs,ensure_ascii=False))
        return 0
    req=None
    try:
        source=sys.stdin.buffer.read() if args.request=='-' else Path(args.request).read_bytes()
        req=json.loads(source.decode('utf-8-sig'))
        emit('result',**execute(req))
        return 0
    except Cancelled as error:
        emit('cancelled',message=str(error))
        return 2
    except Exception as error:
        emit('error',message=error_message(error,req),type=type(error).__name__)
        return 1
if __name__=='__main__': sys.exit(main())
