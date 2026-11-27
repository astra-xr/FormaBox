"""Read and write local SRT and WebVTT subtitle files."""

from dataclasses import dataclass, replace
from html import escape, unescape
import re

from .core import extended_path

MAX_FILE_BYTES = 8 * 1024**2
MAX_TIMESTAMP = 3_600_000_000_000 - 1
FULL_TIME = re.compile(r'([0-9]{2,6}):([0-5][0-9]):([0-5][0-9])([,.])([0-9]{3})')
SHORT_VTT_TIME = re.compile(r'([0-5][0-9]):([0-5][0-9])[.]([0-9]{3})')
TIMING = re.compile(r'(\S+)[ \t]+-->[ \t]+(\S+)(?:[ \t]+([^\n]+))?')
INLINE_TIME = re.compile(r'<([0-9]{2,6}:[0-9:.]{6,13})>')
KNOWN_MARKUP = re.compile(
    r'</?(?:b|i|u|s|ruby|rt|font|v|lang|c)(?=[ .\t>])[^<>\n]*>|<[0-9]{2,6}:[0-9:.]{6,13}>',
    re.IGNORECASE,
)
COMMON_TAGS = {'<b>', '</b>', '<i>', '</i>', '<u>', '</u>'}
HTML_ENTITY = re.compile(r'&(?:#[0-9]{1,8}|#x[0-9a-f]{1,8}|[a-z][a-z0-9]{1,31});', re.IGNORECASE)


@dataclass(frozen=True)
class Cue:
    start: int
    end: int
    text: str
    identifier: str = ''
    settings: str = ''


@dataclass(frozen=True)
class Subtitles:
    format: str
    header: tuple[str, ...]
    blocks: tuple[Cue | tuple[str, ...], ...]


def parse_time(value, format):
    match = FULL_TIME.fullmatch(value)
    if match and match[4] == (',' if format == 'srt' else '.'):
        hours, minutes, seconds, _, milliseconds = match.groups()
        return (int(hours) * 3600 + int(minutes) * 60 + int(seconds)) * 1000 + int(milliseconds)
    short = SHORT_VTT_TIME.fullmatch(value) if format == 'vtt' else None
    if short:
        minutes, seconds, milliseconds = map(int, short.groups())
        return (minutes * 60 + seconds) * 1000 + milliseconds
    raise ValueError(f'无效时间码 {value[:50]!r}')


def format_time(value, format):
    seconds, milliseconds = divmod(value, 1000)
    hours, remainder = divmod(seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    separator = ',' if format == 'srt' else '.'
    return f'{hours:02d}:{minutes:02d}:{seconds:02d}{separator}{milliseconds:03d}'


def text_blocks(text):
    block = []
    start = 0
    for line_number, line in enumerate(text.split('\n'), 1):
        if line.strip(' \t'):
            if not block:
                start = line_number
            block.append(line)
        elif block:
            yield start, tuple(block)
            block.clear()
    if block:
        yield start, tuple(block)


def parse_cue(lines, format):
    timing_index = 0 if '-->' in lines[0] else 1
    if len(lines) <= timing_index:
        raise ValueError('缺少起止时间')
    identifier = lines[0] if timing_index else ''
    if format == 'srt' and identifier and not re.fullmatch(r'[0-9]+', identifier.strip()):
        raise ValueError('SRT 字幕编号应为整数')
    match = TIMING.fullmatch(lines[timing_index].strip(' \t'))
    if not match:
        raise ValueError('起止时间应以 --> 分隔')
    start, end = (parse_time(value, format) for value in match.groups()[:2])
    if end <= start:
        raise ValueError('结束时间须晚于开始时间')
    if format == 'srt' and len(lines) <= timing_index + 1:
        raise ValueError('缺少字幕正文')
    return Cue(start, end, '\n'.join(lines[timing_index + 1:]), identifier, match[3] or '')


def read_subtitles(ctx, path):
    format = path.suffix.lower().removeprefix('.')
    if format not in ('srt', 'vtt') or not path.is_file():
        raise ValueError('请选择 SRT 或 WebVTT 字幕文件')
    with extended_path(path).open('rb') as stream:
        data = stream.read(MAX_FILE_BYTES + 1)
    if len(data) > MAX_FILE_BYTES:
        raise ValueError(f'{path.name}：字幕文件不能超过 8 MiB')
    encoding = 'utf-16' if data.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig'
    try:
        text = data.decode(encoding).replace('\r\n', '\n').replace('\r', '\n')
    except UnicodeDecodeError:
        raise ValueError(f'{path.name}：请选择 UTF-8 或带 BOM 的 UTF-16 字幕') from None
    if '\x00' in text:
        raise ValueError(f'{path.name}：字幕包含无效空字符')
    blocks = text_blocks(text)
    header = ()
    if format == 'vtt':
        first_line, header = next(blocks, (0, ()))
        if first_line != 1 or not re.fullmatch(r'WEBVTT(?:[ \t][^\n]*)?', header[0]) or any('-->' in line for line in header):
            raise ValueError(f'{path.name}：WebVTT 需要 WEBVTT 文件头，文件头后须有空行')
    output = []
    previous_start = -1
    for line, block in blocks:
        ctx.check()
        first = block[0].strip(' \t')
        if format == 'vtt' and (first in ('NOTE', 'STYLE', 'REGION') or first.startswith(('NOTE ', 'NOTE\t'))):
            output.append(block)
            continue
        try:
            cue = parse_cue(block, format)
            if format == 'vtt' and cue.start < previous_start:
                raise ValueError('WebVTT 字幕应按开始时间排列')
        except ValueError as error:
            raise ValueError(f'{path.name} · 第 {line} 行：{error}') from error
        previous_start = cue.start
        output.append(cue)
    if previous_start < 0:
        raise ValueError(f'{path.name}：未找到字幕条目')
    return Subtitles(format, header, tuple(output))


def convert_text(text, target):
    def encode(fragment):
        plain = HTML_ENTITY.sub(lambda match: unescape(match[0]), fragment)
        plain = plain.replace('\r\n', '\n').replace('\r', '\n')
        return escape(plain, quote=False) if target == 'vtt' else plain

    parts = []
    start = 0
    for match in KNOWN_MARKUP.finditer(text):
        parts.append(encode(text[start:match.start()]))
        tag = match[0].lower()
        if target != 'txt' and tag in COMMON_TAGS:
            parts.append(tag)
        start = match.end()
    parts.append(encode(text[start:]))
    return ''.join(parts)


def write_subtitles(ctx, document, destination, target):
    same_format = document.format == target
    header = document.header if same_format else ('WEBVTT',) if target == 'vtt' else ()
    blocks = document.blocks if same_format else [block for block in document.blocks if isinstance(block, Cue)]
    if target == 'vtt' and not same_format:
        blocks.sort(key=lambda cue: cue.start)
    with destination.open('x', encoding='utf-8', newline='\n') as stream:
        if header:
            stream.write('\n'.join(header) + '\n\n')
        index = 0
        for block in blocks:
            ctx.check()
            if not isinstance(block, Cue):
                stream.write('\n'.join(block) + '\n\n')
                continue
            text = block.text if same_format else convert_text(block.text, target)
            if target == 'srt' and not text.strip():
                continue
            index += 1
            if target == 'srt':
                stream.write(f'{index}\n')
            elif same_format and block.identifier:
                stream.write(block.identifier + '\n')
            stream.write(f'{format_time(block.start, target)} --> {format_time(block.end, target)}')
            if same_format and block.settings:
                stream.write(' ' + block.settings)
            # A blank line delimits cues, so avoid creating one by stripping markup.
            for line in text.split('\n'):
                if line.strip(' \t'):
                    stream.write('\n' + line)
            stream.write('\n\n')
    if not index:
        raise ValueError('没有可输出的字幕条目')


def shift_subtitles(ctx, document, offset):
    blocks = []
    retained = 0
    for block in document.blocks:
        ctx.check()
        if not isinstance(block, Cue):
            blocks.append(block)
            continue
        end = block.end + offset
        if end <= 0:
            continue
        if end > MAX_TIMESTAMP:
            raise ValueError('平移后时间码超出范围')
        start = max(0, block.start + offset)
        text = block.text
        if document.format == 'vtt':
            previous = block.start

            def shift_tag(match):
                nonlocal previous
                value = parse_time(match[1], 'vtt')
                if not previous < value < block.end:
                    raise ValueError('字幕内部时间码必须按顺序位于条目起止时间内')
                previous = value
                return '<' + format_time(value + offset, 'vtt') + '>' if value + offset > start else ''

            text = INLINE_TIME.sub(shift_tag, text)
        blocks.append(replace(block, start=start, end=end, text=text))
        retained += 1
    if not retained:
        raise ValueError('平移后所有字幕都早于 0 秒')
    return replace(document, blocks=tuple(blocks))


def write_transcript(ctx, document, destination, timestamps):
    count = 0
    with destination.open('x', encoding='utf-8', newline='\n') as stream:
        for block in document.blocks:
            ctx.check()
            if not isinstance(block, Cue):
                continue
            text = convert_text(block.text, 'txt').strip()
            if text:
                prefix = f'[{format_time(block.start, "vtt")}]\n' if timestamps else ''
                stream.write(('\n' if count else '') + prefix + text + '\n')
                count += 1
    if not count:
        raise ValueError('字幕没有可提取的文字')
