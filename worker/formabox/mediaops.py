import wave

from .core import *

VIDEO={'mp4':['-c:v','libx264','-c:a','aac'],'mkv':['-c:v','libx264','-c:a','aac'],'webm':['-c:v','libvpx-vp9','-c:a','libopus'],'mov':['-c:v','libx264','-c:a','aac'],'avi':['-c:v','mpeg4','-c:a','libmp3lame']}
AUDIO={'mp3':['-c:a','libmp3lame'],'wav':['-c:a','pcm_s16le'],'flac':['-c:a','flac'],'aac':['-c:a','aac'],'ogg':['-c:a','libvorbis'],'opus':['-c:a','libopus'],'m4a':['-c:a','aac']}

def ffmpeg_input(f):
    if not f.is_file(): raise ValueError('请选择音视频文件')
    return [exe('ffmpeg'),'-hide_banner','-loglevel','error','-nostdin','-n',
            '-abort_on','empty_output','-protocol_whitelist','file,pipe','-i',str(f)]

def ff(ctx,f,dest,args):
    ctx.run([*ffmpeg_input(f),*args,str(dest)])
    if not dest.exists() or not dest.stat().st_size: raise RuntimeError('未产生有效输出')
    return dest

def batch(ctx,inputs,ext,fn):
    out=[]
    for i,f in enumerate(inputs):
        ctx.tick(i,len(inputs),f.name); out.append(fn(f,ctx.path(f'{i+1:04d}-{f.stem}.{ext}')))
    return out

@tool('video.convert','视频','视频转换',[param('format','格式','mp4','choice',list(VIDEO)),param('quality','CRF 0–51（越低越清晰）','23','number')],engines=['ffmpeg'])
def video(ctx,inputs,p):
    ext=choice(p,'format',VIDEO); q=integer(p,'quality',0,51); args=VIDEO[ext].copy()
    args+=['-q:v',str(max(1,min(31,q)))] if ext=='avi' else ['-crf',str(q)]+(['-b:v','0'] if ext=='webm' else ['-vf','scale=trunc(iw/2)*2:trunc(ih/2)*2','-pix_fmt','yuv420p'])
    return batch(ctx,inputs,ext,lambda f,d:ff(ctx,f,d,['-map','0:v:0','-map','0:a:0?',*args]))

@tool('video.compress','视频','视频压缩 / 缩放',[param('quality','CRF 0–51','28','number'),param('height','最大高度（0=原尺寸）','720','number'),param('fps','帧率（0=不变）','0','number')],engines=['ffmpeg'])
def compress(ctx,inputs,p):
    q=integer(p,'quality',0,51); h=integer(p,'height',0,4320); fps=integer(p,'fps',0,120); args=['-map','0:v:0','-map','0:a:0?','-c:v','libx264','-crf',str(q),'-pix_fmt','yuv420p','-c:a','aac','-b:a','128k']
    if h: args+=['-vf',f"scale=-2:trunc(min(ih\\,{h})/2)*2"]
    else: args+=['-vf','scale=trunc(iw/2)*2:trunc(ih/2)*2']
    if fps: args+=['-r',str(fps)]
    return batch(ctx,inputs,'mp4',lambda f,d:ff(ctx,f,d,args))

@tool('video.trim','视频','视频剪切',[param('start','起始秒','0','number'),param('duration','持续秒','10','number'),param('copy','快速流复制（边界不保证精确）','false','bool')],engines=['ffmpeg'])
def trim(ctx,inputs,p):
    start=number(p,'start',0,1e8); duration=number(p,'duration',.01,1e8)
    codec=['-c','copy'] if truth(p['copy']) else VIDEO['mp4']+['-vf','pad=ceil(iw/2)*2:ceil(ih/2)*2','-pix_fmt','yuv420p']
    args=['-ss',str(start),'-t',str(duration),'-map','0:v:0','-map','0:a:0?',*codec]
    return batch(ctx,inputs,'mp4',lambda f,d:ff(ctx,f,d,args))

@tool('video.gif','视频','视频转 GIF',[param('start','起始秒','0','number'),param('duration','持续秒','5','number'),param('width','宽度','480','number'),param('fps','帧率','12','number')],engines=['ffmpeg'])
def gif(ctx,inputs,p):
    start=number(p,'start',0,1e8); duration=number(p,'duration',.1,120); w=integer(p,'width',16,1920); fps=integer(p,'fps',1,30)
    return batch(ctx,inputs,'gif',lambda f,d:ff(ctx,f,d,['-ss',str(start),'-t',str(duration),'-vf',f'fps={fps},scale={w}:-1:flags=lanczos','-an']))

@tool('video.snapshot','视频','视频截图',[param('time','时间（秒）','0','number')],engines=['ffmpeg'])
def snapshot(ctx,inputs,p):
    t=number(p,'time',0,1e8)
    return batch(ctx,inputs,'png',lambda f,d:ff(ctx,f,d,['-ss',str(t),'-frames:v','1','-threads','1']))


@tool('subtitle.convert', '视频', '字幕格式转换',
      [param('format', '输出格式', 'vtt', 'choice', ['srt', 'vtt'])], maximum=32,
      description='SRT 与 WebVTT 互转，保留时间、字幕正文及常见粗体、斜体、下划线。更换格式时布局和样式块会省略。')
def convert_subtitles(ctx, inputs, params):
    from .subtitles import read_subtitles, write_subtitles

    target = choice(params, 'format', ('srt', 'vtt'))
    outputs = []
    for index, source in enumerate(inputs, 1):
        ctx.tick(index - 1, len(inputs), source.name)
        document = read_subtitles(ctx, source)
        output = ctx.path(f'{index:04d}-{source.stem}-converted.{target}')
        write_subtitles(ctx, document, output, target)
        outputs.append(output)
    return outputs


@tool('subtitle.shift', '视频', '字幕时间轴平移',
      [param('offset_ms', '偏移（毫秒，负数提前）', '1000', 'number')], maximum=32,
      description='统一提前或延后全部字幕。跨过零点的条目从 0 秒开始，完全早于零点的条目移除。保留输入格式。')
def adjust_subtitle_timing(ctx, inputs, params):
    from .subtitles import read_subtitles, shift_subtitles, write_subtitles

    offset = integer(params, 'offset_ms', -86_400_000, 86_400_000)
    outputs = []
    for index, source in enumerate(inputs, 1):
        ctx.tick(index - 1, len(inputs), source.name)
        document = read_subtitles(ctx, source)
        adjusted = shift_subtitles(ctx, document, offset)
        output = ctx.path(f'{index:04d}-{source.stem}-shifted.{document.format}')
        write_subtitles(ctx, adjusted, output, document.format)
        outputs.append(output)
    return outputs


@tool('subtitle.transcript', '视频', '字幕提取纯文本',
      [param('timestamps', '保留起始时间', 'false', 'bool')], maximum=32,
      description='将 SRT 或 WebVTT 字幕正文导出为 UTF-8 TXT，可在每段开头保留起始时间。')
def subtitle_transcript(ctx, inputs, params):
    from .subtitles import read_subtitles, write_transcript

    timestamps = truth(params['timestamps'])
    outputs = []
    for index, source in enumerate(inputs, 1):
        ctx.tick(index - 1, len(inputs), source.name)
        document = read_subtitles(ctx, source)
        output = ctx.path(f'{index:04d}-{source.stem}-transcript.txt')
        write_transcript(ctx, document, output, timestamps)
        outputs.append(output)
    return outputs


@tool('audio.convert','音频','音频转换 / 视频提取音频',[param('format','格式','mp3','choice',list(AUDIO)),param('bitrate','有损码率 kbps','192','number')],engines=['ffmpeg'])
def audio(ctx,inputs,p):
    ext=choice(p,'format',AUDIO); b=integer(p,'bitrate',32,320); args=['-vn','-map','0:a:0',*AUDIO[ext]]
    if ext not in ('wav','flac'): args+=['-b:a',f'{b}k']
    return batch(ctx,inputs,ext,lambda f,d:ff(ctx,f,d,args))

@tool('audio.trim','音频','音频剪切',[param('start','起始秒','0','number'),param('duration','持续秒','10','number')],engines=['ffmpeg'])
def atrim(ctx,inputs,p):
    t=number(p,'start',0,1e8); d=number(p,'duration',.01,1e8)
    return batch(ctx,inputs,'wav',lambda f,o:ff(ctx,f,o,['-ss',str(t),'-t',str(d),'-vn','-map','0:a:0','-c:a','pcm_s16le']))

@tool('audio.volume','音频','音量调整 / 响度归一化',[param('db','增益 dB','0','number'),param('normalize','响度归一化','false','bool')],engines=['ffmpeg'])
def volume(ctx,inputs,p):
    db=number(p,'db',-60,30); filt=f'volume={db}dB'+(',loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000' if truth(p['normalize']) else '')
    return batch(ctx,inputs,'wav',lambda f,o:ff(ctx,f,o,['-vn','-map','0:a:0','-af',filt,'-c:a','pcm_s16le']))

@tool('audio.denoise','音频','音频降噪',[param('reduction','降噪强度 dB','12','number')],engines=['ffmpeg'])
def denoise(ctx,inputs,p):
    nr=number(p,'reduction',.01,97)
    return batch(ctx,inputs,'wav',lambda f,o:ff(ctx,f,o,['-vn','-map','0:a:0','-af',f'afftdn=nr={nr}','-c:a','pcm_s16le']))


AUDIO_RATE = 48_000
AUDIO_CHANNELS = 2
AUDIO_SAMPLE_BYTES = 2
MAX_AUDIO_FRAMES = 4 * 60 * 60 * AUDIO_RATE
MAX_AUDIO_PARTS = 256
PCM_ARGS = ['-xerror', '-map', '0:a:0', '-map_metadata', '-1', '-map_chapters', '-1',
            '-ar', str(AUDIO_RATE), '-ac', str(AUDIO_CHANNELS), '-c:a', 'pcm_s16le']
AUDIO_TIMELINE = f'aresample={AUDIO_RATE},asetpts=N/SR/TB'


@tool('audio.concat', '音频', '音频拼接', minimum=2, maximum=32,
      description='按输入列表顺序拼接首条音轨。可混合格式，输出 48 kHz 双声道 WAV，总时长最多 4 小时。',
      engines=['ffmpeg'])
def concat_audio(ctx, inputs, params):
    destination = ctx.path('拼接音频.wav')
    frame_bytes = AUDIO_CHANNELS * AUDIO_SAMPLE_BYTES
    remaining_frames = MAX_AUDIO_FRAMES
    with tempfile.TemporaryDirectory(dir=ctx.root) as scratch, destination.open('xb') as file:
        decoded = Path(scratch) / 'track.pcm'
        with wave.open(file, 'wb') as joined:
            joined.setparams((AUDIO_CHANNELS, AUDIO_SAMPLE_BYTES, AUDIO_RATE, 0, 'NONE', 'not compressed'))
            for index, source in enumerate(inputs):
                ctx.tick(index, len(inputs), source.name)
                # Decode past the limit by up to one second so excess audio is detected.
                cutoff = (remaining_frames + AUDIO_RATE - 1) // AUDIO_RATE + 1
                ff(ctx, source, decoded, [*PCM_ARGS, '-af', AUDIO_TIMELINE, '-t', str(cutoff), '-f', 's16le'])
                frame_count, remainder = divmod(decoded.stat().st_size, frame_bytes)
                if not frame_count or remainder:
                    raise ValueError(f'无法读取有效音频：{source.name}')
                if frame_count > remaining_frames:
                    raise ValueError('拼接音频的总时长不能超过 4 小时')
                with decoded.open('rb') as track:
                    while block := track.read(1024 * 1024):
                        ctx.check()
                        joined.writeframesraw(block)
                remaining_frames -= frame_count
                decoded.unlink()
    return [destination]


@tool('audio.split', '音频', '音频定长分段',
      [param('seconds', '每段秒数（1–600）', '60', 'number')],
      description='将每个输入的首条音轨分为 48 kHz 双声道 WAV，末段保留实际长度。每次最多 256 段，总时长最多 4 小时。',
      engines=['ffmpeg'])
def split_audio(ctx, inputs, params):
    seconds = integer(params, 'seconds', 1, 600)
    results = []
    remaining_frames = MAX_AUDIO_FRAMES
    for index, source in enumerate(inputs, 1):
        ctx.tick(index - 1, len(inputs), source.name)
        remaining_parts = MAX_AUDIO_PARTS - len(results)
        if remaining_parts == 0:
            raise ValueError('每次最多输出 256 个音频分段，请增大分段时长或分批处理')
        cutoff = min((remaining_parts + 1) * seconds,
                     (remaining_frames + AUDIO_RATE - 1) // AUDIO_RATE + 1)
        prefix = f'{index:04d}-part-'
        # FFmpeg expands percent signs in the full segment filename template.
        pattern = str(ctx.root / prefix).replace('%', '%%') + '%04d.wav'
        # Uniform 100 ms packets put every whole-second boundary on a packet edge.
        audio_filter = f'aresample={AUDIO_RATE},asetnsamples=n={AUDIO_RATE // 10}:p=0,asetpts=N/SR/TB'
        ctx.run([*ffmpeg_input(source), *PCM_ARGS, '-af', audio_filter, '-t', str(cutoff),
                 '-f', 'segment', '-segment_format', 'wav', '-segment_time', str(seconds),
                 '-segment_start_number', '1', '-reset_timestamps', '1', pattern])
        segments = sorted(ctx.root.glob(f'{prefix}*.wav'))
        if not segments:
            raise RuntimeError('未生成音频分段')
        if len(segments) > remaining_parts:
            raise ValueError('每次最多输出 256 个音频分段，请增大分段时长或分批处理')
        for segment in segments:
            ctx.check()
            with wave.open(str(segment), 'rb') as audio:
                frames = audio.getnframes()
            if not frames:
                raise RuntimeError('生成了空的音频分段')
            remaining_frames -= frames
        if remaining_frames < 0:
            raise ValueError('分段音频的总时长不能超过 4 小时')
        results.extend(segments)
    return results
