"""Offline transcription with a pinned, explicitly downloaded model."""
from contextlib import contextmanager
from hashlib import sha256
import os
from pathlib import Path
import tempfile
from urllib.request import urlopen

from .core import checked_path, choice, digest, exe, param, tool, truth
from .mediaops import ff
from .studio_media import probe

MODEL = 'ggml-tiny.bin'
MODEL_SHA = 'be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21'
MODEL_URL = 'https://github.com/astra-xr/Omnora/releases/download/v0.9.0/Whisper-Multilingual-Tiny.bin'


def model_path(ctx, allow_download):
    base = os.environ.get('LOCALAPPDATA') if os.name == 'nt' else os.environ.get('XDG_CACHE_HOME')
    base = Path(base) if base else Path.home()/'.cache'
    configured = os.environ.get('FORMABOX_MODEL_DIR')
    directory = checked_path(configured or str(base/'Omnora'/'models'), allow_missing=True)
    model = directory/MODEL
    if not configured and not model.exists():
        previous = base/'FormaBox'/'models'/MODEL
        if previous.is_file():
            previous = checked_path(str(previous))
            if digest(previous, ctx=ctx) == MODEL_SHA:
                return previous
    if model.exists():
        model = checked_path(str(model))
        if model.is_file() and digest(model, ctx=ctx) == MODEL_SHA:
            return model
        raise ValueError(f'模型校验失败，请移走该文件后重试：{model}')
    if not allow_download:
        raise ValueError('首次使用请勾选下载模型。约 75 MiB，音视频不会上传。')
    directory.mkdir(exist_ok=True, parents=True)
    checksum = sha256()
    with response_temp(directory) as temporary:
        done = 0
        with urlopen(MODEL_URL, timeout=25) as response, temporary.open('wb') as out:
            while data := response.read(1024**2):
                ctx.tick(done, 0, f'正在下载语音模型 · {done//1024**2} MiB')
                done += len(data)
                if done > 80*1024**2:
                    raise ValueError('模型大小超出限制')
                checksum.update(data)
                out.write(data)
        if checksum.hexdigest() != MODEL_SHA:
            raise ValueError('下载模型校验失败')
        checked_path(str(model), allow_missing=True)
        temporary.replace(model)
    return model


@contextmanager
def response_temp(folder):
    handle, name = tempfile.mkstemp(prefix='.whisper-', suffix='.part', dir=folder)
    os.close(handle)
    path = Path(name)
    try:
        yield path
    finally:
        path.unlink(missing_ok=True)


@tool('audio.transcribe', '音频', '本地语音转文字与字幕',
      [param('language', '语言', 'auto', 'choice', ['auto', 'zh', 'en', 'ja', 'ko']),
       param('download_model', '允许首次下载模型（约 75 MiB）', 'false', 'bool')],
      maximum=8, engines=['ffmpeg', 'whisper-cli'],
      description='在本机识别音频或视频中的语音，导出 TXT 和 SRT。仅首次下载公开模型需要联网。')
def transcribe(ctx, inputs, params):
    executable = exe('whisper-cli')
    language = choice(params, 'language', ('auto', 'zh', 'en', 'ja', 'ko'))
    model = model_path(ctx, truth(params['download_model']))
    outputs = []
    for index, source in enumerate(inputs, 1):
        duration, _ = probe(ctx, source, 'a')
        if duration > 7200:
            raise ValueError('单个媒体最多支持 2 小时')
        ctx.tick(index-1, len(inputs), f'{source.name} · 本机转写')
        with tempfile.TemporaryDirectory(prefix='speech-', dir=ctx.root) as staging:
            folder = Path(staging)
            wave = folder/'audio.wav'
            ff(ctx, source, wave, ['-map', '0:a:0', '-vn', '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le'])
            # Whisper's Windows CLI opens narrow paths. All arguments inside
            # the work directory use ASCII basenames.
            local_model = folder/'model.bin'
            try:
                os.link(model, local_model)
            except OSError:
                from .core import copy_file
                copy_file(ctx, model, local_model)
            ctx.run([executable, '-m', 'model.bin', '-f', 'audio.wav', '-l', language,
                     '-t', str(min(os.cpu_count() or 2, 8)), '-ng', '-nt', '-otxt', '-osrt', '-of', 'speech'],
                    cwd=folder, timeout=7200)
            for suffix in ('txt', 'srt'):
                result = folder/f'speech.{suffix}'
                if not result.is_file() or not result.read_text(encoding='utf-8', errors='replace').strip():
                    raise ValueError(f'{source.name}: 未识别到可输出的语音')
                target = ctx.path(f'{index:04d}-{source.stem}.{suffix}')
                result.rename(target)
                outputs.append(target)
    return outputs
