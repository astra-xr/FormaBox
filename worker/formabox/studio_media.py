"""Bounded video encoding, timeline editing and silence analysis."""
import json
import math
import os
from pathlib import Path
import re
import tempfile

from PIL import Image, ImageDraw, ImageFont, ImageOps

from .core import choice, copy_file, exe, integer, number, param, report, tool
from .mediaops import batch, ff, ffmpeg_input


def probe(ctx, path, media):
    if not path.is_file():
        raise ValueError('请选择音视频文件')
    log = ctx.run([exe('ffmpeg'), '-hide_banner', '-loglevel', 'info', '-nostdin',
                   '-protocol_whitelist', 'file,pipe', '-i', path, '-map', f'0:{media}:0',
                   '-t', '0', '-f', 'null', '-'], timeout=30)
    match = re.search(r'^  Duration: (\d+):(\d+):(\d+(?:\.\d+)?)', log, re.MULTILINE)
    if not match:
        raise ValueError('无法读取媒体时长')
    hours, minutes, seconds = (float(piece) for piece in match.groups())
    duration = 3600*hours + 60*minutes + seconds
    if not .03 <= duration <= 8*3600:
        raise ValueError('媒体时长应为 0.03 秒至 8 小时')
    return duration, bool(re.search(r'^  Stream .*?: Audio:', log.partition('Stream mapping:')[0], re.MULTILINE))


@tool('video.target_size', '视频', '视频按目标大小压缩',
      [param('target_mib', '每段视频大小上限 MiB', '20', 'number'),
       param('height', '最大高度', '720', 'number')], maximum=8, engines=['ffmpeg'],
      description='按时长分配码率并进行两遍编码，对实际生成的 MP4 复核大小。')
def target_video(ctx, inputs, params):
    target = int(number(params, 'target_mib', .1, 4096)*1024**2)
    height = integer(params, 'height', 144, 2160)
    outputs = []
    for index, source in enumerate(inputs, 1):
        duration, audio = probe(ctx, source, 'v')
        out = ctx.path(f'{index:04d}-{source.stem}.mp4')
        original = source.stat().st_size
        if original <= target and source.suffix.lower() == '.mp4':
            copy_file(ctx, source, out)
        else:
            audio_rate = 48_000 if audio else 0
            rate = int((target - max(4096, duration*700))*8/duration) - audio_rate
            with tempfile.TemporaryDirectory(prefix='video-', dir=ctx.root) as folder:
                for attempt in range(4):
                    if rate < 20_000:
                        raise ValueError(f'{source.name}: 目标太小，请提高上限或裁短视频')
                    scale = f'scale=-2:trunc(min(ih\\,{height})/2)*2'
                    opts = ['-map', '0:v:0', '-vf', scale, '-c:v', 'libx264', '-b:v', str(rate),
                            '-preset', 'fast', '-pix_fmt', 'yuv420p', '-passlogfile', 'encode']
                    ctx.tick(index-1, len(inputs), f'{source.name} · 分析编码第 {attempt+1} 轮')
                    ctx.run([*ffmpeg_input(source), *opts, '-an', '-pass', '1', '-f', 'null', os.devnull], cwd=folder)
                    ctx.tick(index-1, len(inputs), f'{source.name} · 生成并复核大小')
                    sound = ['-map', '0:a:0?', '-c:a', 'aac', '-b:a', str(audio_rate)] if audio else ['-an']
                    ctx.run([*ffmpeg_input(source), *opts, '-pass', '2', *sound, '-map_metadata', '-1',
                             '-movflags', '+faststart', out], cwd=folder)
                    size = out.stat().st_size
                    if 0 < size <= target:
                        break
                    out.unlink()
                    rate = int(rate * min(.85, target/max(size, 1)*.86))
                else:
                    raise ValueError(f'{source.name}: 无法在指定上限内生成有效视频')
        ctx.result_details[out] = dict(original_bytes=original, target_bytes=target)
        outputs.append(out)
    return outputs


def timeline_segments(ctx, inputs, raw):
    if len(str(raw)) > 16384:
        raise ValueError('视频片段配置过长')
    clips = json.loads(raw)
    properties = [probe(ctx, p, 'v') for p in inputs]
    if clips == []:
        clips = [dict(source=index, start=0, end=duration) for index, (duration, _) in enumerate(properties)]
    if not isinstance(clips, list) or not 1 <= len(clips) <= 24:
        raise ValueError('请选择 1–24 个片段')
    result = []
    for clip in clips:
        if not isinstance(clip, dict):
            raise ValueError('片段数据无效')
        index = integer(clip, 'source', 0, len(inputs)-1)
        duration, audio = properties[index]
        start = number(clip, 'start', 0, duration)
        end = number(clip, 'end', 0, duration)
        if end-start < .04:
            raise ValueError('结束点应晚于开始点至少 0.04 秒')
        result.append((inputs[index], start, end-start, audio))
    if sum(clip[2] for clip in result) > 2*3600:
        raise ValueError('合计视频长度不得超过 2 小时')
    return result


@tool('video.timeline', '视频', '视频可视化剪切与拼接',
      [param('size', '导出尺寸', '1280x720', 'choice', ['640x360', '1280x720', '1920x1080']),
       param('clips', '片段配置', '[]', 'internal')], maximum=12, engines=['ffmpeg'],
      description='预览每个切点并调整顺序，统一为同一尺寸和帧率后导出 MP4。')
def join_video(ctx, inputs, params):
    output_size = choice(params, 'size', ('640x360', '1280x720', '1920x1080'))
    width, height = output_size.split('x')
    filters = (f'scale={width}:{height}:force_original_aspect_ratio=decrease:force_divisible_by=2,'
               f'pad={width}:{height}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30')
    segments = timeline_segments(ctx, inputs, params['clips'])
    out = ctx.path('剪辑视频.mp4')
    with tempfile.TemporaryDirectory(prefix='timeline-', dir=ctx.root) as staging:
        folder = Path(staging)
        names = []
        for index, (source, start, duration, audio) in enumerate(segments):
            ctx.tick(index, len(segments), source.name)
            name = f'segment-{index:03d}.mp4'
            names.append(name)
            silence = [] if audio else ['-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo']
            mapping = ['-map', '0:a:0'] if audio else ['-map', '1:a:0']
            ctx.run([*ffmpeg_input(source), *silence, '-ss', str(start), '-t', str(duration), '-map', '0:v:0',
                     *mapping, '-vf', filters, '-af', 'apad', '-ar', '48000', '-ac', '2',
                     '-c:v', 'libx264', '-preset', 'fast', '-pix_fmt', 'yuv420p', '-c:a', 'aac',
                     '-map_metadata', '-1', folder/name])
        playlist = folder/'clips.txt'
        playlist.write_text(''.join(f"file '{name}'\n" for name in names), encoding='ascii')
        ctx.run([exe('ffmpeg'), '-hide_banner', '-loglevel', 'error', '-nostdin', '-n',
                 '-protocol_whitelist', 'file,pipe', '-f', 'concat', '-safe', '1', '-i', playlist.name,
                 '-c', 'copy', '-movflags', '+faststart', out], cwd=folder)
    return [out]


def video_still(ctx, source, seconds, output, width=420):
    return ff(ctx, source, output, ['-ss', str(seconds), '-map', '0:v:0', '-frames:v', '1', '-threads', '1',
                                    '-vf', f'scale=min(iw\\,{width}):-1'])


@tool('video.contact_sheet', '视频', '视频缩略图总览',
      [param('frames', '抽取画面数', '12', 'number'), param('columns', '列数', '4', 'number')],
      maximum=8, engines=['ffmpeg'], description='抽取分布在视频各处的画面，与时间戳排成一张图片。')
def contact_sheet(ctx, inputs, params):
    count, columns = integer(params, 'frames', 2, 36), integer(params, 'columns', 2, 6)
    def one(source, out):
        duration, _ = probe(ctx, source, 'v')
        with tempfile.TemporaryDirectory(dir=ctx.root) as folder:
            temp = Path(folder)/'still.png'
            with Image.new('RGB', (columns*272, math.ceil(count/columns)*184), '#202b3a') as image:
                draw = ImageDraw.Draw(image)
                font = ImageFont.load_default(size=16)
                for index in range(count):
                    ctx.check()
                    time = index*max(0, duration-.08)/count
                    video_still(ctx, source, time, temp, 256)
                    with Image.open(temp) as original:
                        thumbnail = ImageOps.contain(original.convert('RGB'), (256, 145))
                    row, column = divmod(index, columns)
                    x, y = column*272+8, row*184+8
                    image.paste(thumbnail, (x+(256-thumbnail.width)//2, y+(145-thumbnail.height)//2))
                    minutes, seconds = divmod(time, 60)
                    draw.text((x, y+151), f'{int(minutes):02d}:{seconds:05.2f}', font=font, fill='white')
                    temp.unlink()
                image.save(out)
        return out
    return batch(ctx, inputs, 'png', one)


def detect_silence(ctx, source, params):
    duration, _ = probe(ctx, source, 'a')
    if duration > 7200:
        raise ValueError('静音检测支持最长 2 小时')
    threshold = number(params, 'threshold', -85, -10)
    minimum = number(params, 'minimum', .2, 60)
    with tempfile.TemporaryFile() as log:
        ctx.run([*ffmpeg_input(source), '-map', '0:a:0', '-vn',
                 '-af', f'silencedetect=n={threshold}dB:d={minimum},ametadata=mode=print:file=-',
                 '-f', 'null', os.devnull], stdout_file=log)
        log.seek(0)
        metadata = log.read().decode('utf-8', 'replace')
    spans = []
    start = None
    for key, raw in re.findall(r'^lavfi\.silence_(start|end)=(\d+(?:\.\d+)?(?:e[-+]?\d+)?)$', metadata,
                               flags=re.MULTILINE | re.IGNORECASE):
        value = float(raw)
        if key == 'start':
            start = value
        elif start is not None:
            spans.append((max(0, start), min(duration, value)))
            start = None
    if start is not None:
        spans.append((start, duration))
    return duration, [(a, b) for a, b in spans if b > a]


@tool('audio.silence', '音频', '音频静音检测与编辑',
      [param('threshold', '静音阈值 dB', '-40', 'number'), param('minimum', '最短静音秒数', '0.8', 'number'),
       param('mode', '操作', '检测报告', 'choice', ['检测报告', '删除选中', '缩短选中']),
       param('keep', '缩短后保留秒数', '0.25', 'number'),
       param('selected', '静音段选择', 'all', 'internal')], maximum=1, engines=['ffmpeg'],
      description='识别较长停顿，试听后选择删除或缩短，输出 WAV。')
def silence_edit(ctx, inputs, params):
    source = inputs[0]
    duration, spans = detect_silence(ctx, source, params)
    mode = choice(params, 'mode', ('检测报告', '删除选中', '缩短选中'))
    rows = [dict(start=round(a, 3), end=round(b, 3)) for a, b in spans]
    result = report(ctx, '静音报告.json', dict(duration=duration, spans=rows))
    if mode == '检测报告':
        return result
    raw = str(params['selected'])
    indices = list(range(len(spans))) if raw == 'all' else json.loads(raw)
    if not isinstance(indices, list) or any(type(i) is not int or not 0 <= i < len(spans) for i in indices):
        raise ValueError('静音段选择无效')
    if not indices or len(indices) > 280:
        raise ValueError('请选择 1–280 段静音')
    keep = number(params, 'keep', 0, 30) if mode == '缩短选中' else 0
    retained = []
    start = 0
    for index in sorted(set(indices)):
        a, b = spans[index]
        end = min(b, a+keep)
        if end-start >= .01:
            retained.append((start, end))
        start = b
    if duration-start >= .01:
        retained.append((start, duration))
    if not retained:
        raise ValueError('所选操作会删掉全部音频')
    filters = [f'[0:a:0]atrim=start={a:.6f}:end={b:.6f},asetpts=PTS-STARTPTS[s{i}]' for i, (a, b) in enumerate(retained)]
    filters.append(''.join(f'[s{i}]' for i in range(len(retained)))+f'concat=n={len(retained)}:v=0:a=1[out]')
    out = ctx.path('处理音频.wav')
    ff(ctx, source, out, ['-filter_complex', ';'.join(filters), '-map', '[out]', '-c:a', 'pcm_s16le'])
    return [out, *result]
