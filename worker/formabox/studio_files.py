"""Safe archives and per-file checkpoints for folder jobs."""
from contextlib import contextmanager
import gzip
import hashlib
from itertools import islice
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile
import tempfile
import uuid
import zipfile

from .core import (Context, checked_path, copy_content, display_path, extended_path, integer, invoke,
                   output_path, param, path_is_link, regular_files, safe_name, tool, truth, walk_tree)

LIMIT = 5000


def safe_members(members):
    explicit, used = set(), {}
    for count, (name, size, is_dir, item) in enumerate(members, 1):
        if count > LIMIT:
            raise ValueError(f'归档最多支持 {LIMIT} 个条目')
        name = name.replace('\\', '/').removesuffix('/')
        if name.startswith('./'):
            name = name[2:]
        if name in ('', '.') and is_dir:
            continue
        parts = name.split('/')
        for depth, part in enumerate(parts, 1):
            safe_name(part)
            original = tuple(parts[:depth])
            key = tuple(p.casefold() for p in original)
            entry = (original, depth < len(parts) or is_dir)
            if used.setdefault(key, entry) != entry:
                raise ValueError('归档内的文件或目录路径冲突')
        if key in explicit or size < 0:
            raise ValueError('归档内有重复或无效条目')
        explicit.add(key)
        yield name, size, is_dir, item


def archive_format(path):
    value = path.name.lower()
    if value.endswith('.tar.gz') or value.endswith('.tgz'):
        return 'tgz'
    return path.suffix.lower().lstrip('.')


@contextmanager
def read_archive(path, cap):
    kind = archive_format(path)
    if kind == 'zip':
        import stat
        with zipfile.ZipFile(path) as archive:
            def entries():
                for item in archive.infolist():
                    mode = stat.S_IFMT(item.external_attr >> 16)
                    if item.external_attr & stat.FILE_ATTRIBUTE_REPARSE_POINT or mode not in (0, stat.S_IFREG, stat.S_IFDIR):
                        raise ValueError('归档含链接或特殊文件')
                    yield item.filename, item.file_size, item.is_dir(), item
            yield kind, archive, list(safe_members(entries()))
    elif kind in ('tar', 'tgz'):
        with tarfile.open(path, 'r:*') as archive:
            def entries():
                for item in archive:
                    if not (item.isfile() or item.isdir()) or item.issparse():
                        raise ValueError('归档含链接、稀疏文件或特殊条目')
                    yield item.name, item.size, item.isdir(), item
            yield kind, archive, list(safe_members(entries()))
    elif kind == '7z':
        import py7zr
        with py7zr.SevenZipFile(path, 'r', max_extract_size=cap) as archive:
            def entries():
                for item in archive.list():
                    if not (item.is_file or item.is_directory) or item.is_symlink:
                        raise ValueError('归档含链接或特殊文件')
                    yield item.filename, item.uncompressed or 0, item.is_directory, item
            yield kind, archive, list(safe_members(entries()))
    elif kind == 'gz':
        filename = safe_name(path.name[:-3])
        with gzip.open(path, 'rb') as archive:
            yield kind, archive, [(filename, 0, False, None)]
    else:
        raise ValueError('请选择 7z、TAR、TAR.GZ、GZ 或 ZIP 归档')


def archive_rows(path, limit):
    with read_archive(path, limit) as (_, _, members):
        return [dict(name=name, bytes=size, directory=is_dir) for name, size, is_dir, _ in members]


def extract_archive(ctx, path, destination, selected, cap):
    with read_archive(path, cap) as (kind, archive, members):
        files = {name: (size, item) for name, size, directory, item in members if not directory}
        if selected == 'all':
            wanted = files
        else:
            names = json.loads(selected)
            if not isinstance(names, list) or any(not isinstance(n, str) or n not in files for n in names):
                raise ValueError('所选归档成员无效')
            wanted = {name: files[name] for name in names}
        if not wanted or sum(size for size, _ in wanted.values()) > cap:
            raise ValueError('没有要提取的文件，或超过解压大小限制')
        total = 0

        def create(name):
            file = destination.joinpath(*name.split('/'))
            file.parent.mkdir(parents=True, exist_ok=True)
            file.touch(exist_ok=False)
            return file

        def account(size):
            nonlocal total
            ctx.check()
            total += size
            if total > cap:
                raise ValueError('超出解压大小限制')

        if kind == '7z':
            from py7zr.io import Py7zIO, WriterFactory
            aliases = {str(Path(name)): name for name in wanted}
            class MemberSink(Py7zIO):
                def __init__(self, name):
                    self.file = create(name)
                    self.offset = 0
                def write(self, data):
                    account(len(data))
                    with self.file.open('r+b') as file:
                        file.seek(self.offset)
                        count = file.write(data)
                    self.offset += count
                    return count
                def read(self, size=-1):
                    with self.file.open('rb') as file:
                        file.seek(self.offset)
                        data = file.read(-1 if size is None else size)
                    self.offset += len(data)
                    return data
                def seek(self, offset, whence=0):
                    self.offset = offset + (self.offset if whence == 1 else self.size() if whence == 2 else 0)
                    return self.offset
                def flush(self):
                    pass
                def size(self):
                    return self.file.stat().st_size
            class Members(WriterFactory):
                def create(self, filename):
                    name = aliases.get(str(Path(filename)))
                    if name is None:
                        raise ValueError('归档返回了未选中的路径')
                    return MemberSink(name)
            archive.extract(targets=[item.filename for _, item in wanted.values()], factory=Members())
        else:
            for name, (_, member) in wanted.items():
                source = archive if kind == 'gz' else archive.open(member) if kind == 'zip' else archive.extractfile(member)
                with source, create(name).open('r+b') as target:
                    while data := source.read(1024**2):
                        account(len(data))
                        target.write(data)
        for name, (size, _) in wanted.items():
            file = destination.joinpath(*name.split('/'))
            if not file.is_file() or (kind != 'gz' and file.stat().st_size != size):
                raise ValueError('归档成员大小校验失败')


@tool('file.archive', '文件', '归档浏览、打包与选取解压',
      [param('operation', '操作', '提取', 'choice', ['提取', '浏览', '创建 7z', '创建 TAR', '创建 TAR.GZ', '创建 GZ']),
       param('max_mib', '提取大小上限 MiB', '2048', 'number'),
       param('selected', '归档成员', 'all', 'internal')], maximum=1, engines=['py7zr'],
      description='预览 7z、TAR、TAR.GZ、GZ 或 ZIP，选择成员后安全解压。')
def archive_tool(ctx, inputs, params):
    import py7zr

    source = inputs[0]
    cap = integer(params, 'max_mib', 1, 8192)*1024**2
    operation = str(params['operation'])
    if operation == '浏览':
        from .core import report
        return report(ctx, '归档文件清单.json', archive_rows(source, cap))
    if operation == '提取':
        dest = ctx.path('归档内容')
        dest.mkdir()
        extract_archive(ctx, source, dest, str(params['selected']), cap)
        return [dest]
    if operation == '创建 GZ':
        if not source.is_file():
            raise ValueError('GZ 只打包单个文件，打包目录请选择 TAR.GZ')
        dest = ctx.path(safe_name(source.name)+'.gz')
        with source.open('rb') as file, gzip.open(dest, 'wb') as packed:
            copy_content(ctx, file, packed)
        return [dest]
    suffix = {'创建 7z': '7z', '创建 TAR': 'tar', '创建 TAR.GZ': 'tar.gz'}.get(operation)
    if not suffix:
        raise ValueError('未知归档操作')
    dest = ctx.path(f'归档.{suffix}')
    paths = list(islice(regular_files([source], ctx), LIMIT + 1))
    if not 1 <= len(paths) <= LIMIT:
        raise ValueError('归档文件数量超出限制')
    root = extended_path(source if source.is_dir() else source.parent)
    rows = list(safe_members((f.relative_to(root).as_posix(), f.stat().st_size, False, f) for f in paths))
    with (py7zr.SevenZipFile(dest, 'w') if suffix == '7z'
          else tarfile.open(dest, 'w:gz' if suffix == 'tar.gz' else 'w')) as archive:
        for index, (name, _, _, path) in enumerate(rows):
            ctx.tick(index, len(rows), name)
            if suffix == '7z':
                archive.write(path, arcname=name)
            else:
                archive.add(path, arcname=name, recursive=False)
    return [dest]


BATCH = {
    '转换为 JPEG': ('image.convert', {'format': 'jpg'}, {'.png', '.jpg', '.jpeg', '.webp', '.bmp', '.tif', '.tiff', '.avif'}),
    '图片压到 100 KiB': ('image.compress', {'format': 'jpg', 'target_kib': '100'}, {'.png', '.jpg', '.jpeg', '.webp', '.bmp', '.tif', '.tiff', '.avif'}),
    'Office 转 PDF': ('doc.pdf', {}, {'.doc', '.docx', '.odt', '.xls', '.xlsx', '.ppt', '.pptx', '.rtf'}),
    '视频转换为 MP4': ('video.convert', {'format': 'mp4'}, {'.avi', '.mp4', '.mkv', '.mov', '.webm', '.m4v'}),
    '音频转换为 MP3': ('audio.convert', {'format': 'mp3'}, {'.wav', '.flac', '.ogg', '.aac', '.opus', '.mp3', '.m4a'}),
}


def batch_plan(ctx, inputs, params):
    root = extended_path(inputs[0])
    if not root.is_dir():
        raise ValueError('请选择一个文件夹')
    operation = str(params['operation'])
    if operation not in BATCH:
        raise ValueError('未知批处理操作')
    _, _, allowed = BATCH[operation]
    suffixes = {'.'+s.strip().lower().lstrip('.') for s in str(params['suffixes']).split(',') if s.strip()}
    if suffixes and not suffixes <= allowed:
        raise ValueError('后缀与处理规则不匹配')
    suffixes = suffixes or allowed
    records = []
    for folder, names, _ in walk_tree(root, ctx):
        for name in names:
            candidate = folder/name
            if candidate.suffix.lower() not in suffixes or path_is_link(candidate) or not candidate.is_file():
                continue
            relative = candidate.relative_to(root)
            for part in relative.parts:
                safe_name(part)
            info = candidate.stat()
            records.append((relative.as_posix(), info.st_size, info.st_mtime_ns))
            if len(records) > LIMIT:
                raise ValueError(f'批处理最多支持 {LIMIT} 个文件')
        if not truth(params['recursive']):
            break
    if not records:
        raise ValueError('文件夹没有符合规则的文件')
    return root, records


@contextmanager
def batch_lock(path):
    checked_path(str(path), allow_missing=True)
    with path.open('a+b') as lock:
        lock.seek(0)
        try:
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise ValueError('该批处理任务正在运行') from error
        yield


@tool('folder.batch', '文件', '文件夹批处理与续跑',
      [param('operation', '处理规则', '转换为 JPEG', 'choice', list(BATCH)),
       param('suffixes', '仅处理这些后缀（逗号分隔，空=全部适用）', ''),
       param('recursive', '包含子目录', 'true', 'bool'),
       param('preserve', '保留子目录结构', 'true', 'bool'),
       param('fingerprint', '已预览文件清单', '', 'internal'),
       param('session', '续跑任务编号', '', 'internal')], maximum=1,
      description='预览匹配的文件并按规则处理，每个文件独立提交。重启后可以续跑。')
def folder_batch(ctx, inputs, params):
    raise ValueError('请将文件夹批处理作为独立任务运行')


def run_folder_batch(ctx, inputs, params):
    from .core import TOOLS

    defaults = {p['key']: p['default'] for p in TOOLS['folder.batch'][0]['params']}
    if len(inputs) != 1 or not isinstance(params, dict) or set(params)-defaults.keys():
        raise ValueError('文件夹批处理参数无效')
    options = defaults | params
    root, records = batch_plan(ctx, inputs, options)
    from .studio_preview import batch_fingerprint
    fingerprint = str(options.get('fingerprint', ''))
    if fingerprint and fingerprint != batch_fingerprint(records):
        raise ValueError('文件夹内容已变化，请重新预览')
    session = str(options.pop('session')) or uuid.uuid4().hex
    if not re.fullmatch('[0-9a-f]{32}', session):
        raise ValueError('续跑任务编号无效')
    spec, arguments, _ = BATCH[str(options['operation'])]
    directory = extended_path(checked_path(str(ctx.root/f'FormaBox-Batch-{session}'), allow_missing=True))
    directory.mkdir(exist_ok=True)
    with batch_lock(directory/'.lock'):
        marker = directory/'任务配置.json'
        signature = dict(input=output_path(root), options=options)
        if marker.exists():
            checked_path(str(marker))
            if json.loads(marker.read_text(encoding='utf-8')) != signature:
                raise ValueError('续跑任务的目录或处理规则已修改')
        else:
            if any(file.name != '.lock' for file in directory.iterdir()):
                raise ValueError('已有同名输出目录')
            temporary = directory/f'.config-{uuid.uuid4().hex}.tmp'
            temporary.write_text(json.dumps(signature, ensure_ascii=False), encoding='utf-8')
            temporary.replace(marker)
        results = extended_path(checked_path(str(directory/'处理结果'), allow_missing=True))
        results.mkdir(exist_ok=True)
        done = resumed = 0
        errors = []
        for index, (name, size, modified) in enumerate(records):
            ctx.tick(index, len(records), name)
            relative = PurePosixPath(name)
            parent = results.joinpath(*relative.parts[:-1]) if truth(options['preserve']) else results
            key = hashlib.sha256(name.encode('utf-8')).hexdigest()[:16]
            final = parent/f'{relative.stem[:90]}-{key}'
            checked_path(str(parent), allow_missing=True)
            parent.mkdir(exist_ok=True, parents=True)
            stamp = dict(name=name, size=size, modified=modified)
            if final.exists():
                checked_path(str(final/'处理记录.json'))
                saved = json.loads((final/'处理记录.json').read_text(encoding='utf-8'))
                if saved == stamp and any(p.name != '处理记录.json' and not path_is_link(p) and p.is_file()
                                          for p in final.iterdir()):
                    resumed += 1
                else:
                    errors.append(dict(file=name, error='文件已变化，请新建批处理任务'))
                continue
            staging = Path(tempfile.mkdtemp(prefix='.staging-', dir=directory))
            try:
                file = checked_path(str(root.joinpath(*relative.parts)))
                invoke(spec, [file], arguments, Context(staging, ctx.cancel, lambda *_, **fields: None))
                changed = file.stat()
                if (changed.st_size, changed.st_mtime_ns) != (size, modified):
                    raise ValueError('处理时源文件已变化')
                (staging/'处理记录.json').write_text(json.dumps(stamp, ensure_ascii=False), encoding='utf-8')
                ctx.check()
                staging.rename(final)
                done += 1
            except (OSError, ValueError, RuntimeError) as error:
                errors.append(dict(file=name, error=str(error)[-400:]))
            finally:
                if staging.exists():
                    shutil.rmtree(staging, ignore_errors=True)
        summary = directory/'批处理报告.json'
        checked_path(str(summary), allow_missing=True)
        temporary = directory/f'.report-{uuid.uuid4().hex}.tmp'
        temporary.write_text(json.dumps(dict(completed=done, resumed=resumed, failures=errors),
                                         ensure_ascii=False, indent=2), encoding='utf-8')
        temporary.replace(summary)
        if errors:
            raise ValueError(f'{len(errors)} 个文件未完成。可续跑，报告位于 {display_path(summary)}')
        return dict(directory=output_path(directory), files=[output_path(results), output_path(summary)])
