"""Wire format shared by the worker CLI and its request handlers."""

import json


PROTOCOL_VERSION = 1


class InvalidRequest(ValueError):
    pass


class UnsupportedProtocol(ValueError):
    pass


class MissingDependency(RuntimeError):
    pass


class EngineFailed(RuntimeError):
    pass


def decode_request(source):
    try:
        return json.loads(source)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise InvalidRequest(str(error)) from error


def validate_request(request):
    if not isinstance(request, dict):
        raise InvalidRequest('工作请求必须为 JSON 对象')
    version = request.get('protocol_version', PROTOCOL_VERSION)
    if type(version) is not int or version != PROTOCOL_VERSION:
        raise UnsupportedProtocol(f'不支持的工作进程协议版本（当前支持 {PROTOCOL_VERSION}）')


def emit(event, **fields):
    print(json.dumps(dict(event=event, protocol_version=PROTOCOL_VERSION, **fields), ensure_ascii=False), flush=True)


def error_code(error):
    codes = (
        (UnsupportedProtocol, 'unsupported_protocol'),
        (InvalidRequest, 'invalid_request'),
        ((MissingDependency, ImportError), 'missing_dependency'),
        (EngineFailed, 'engine_failed'),
        (TimeoutError, 'timeout'),
        (FileNotFoundError, 'file_not_found'),
        (PermissionError, 'permission_denied'),
        (FileExistsError, 'file_conflict'),
        (OSError, 'io_error'),
        (ValueError, 'invalid_argument'),
    )
    return next((code for category, code in codes if isinstance(error, category)), 'task_failed')


def diagnostic_type(error):
    if isinstance(error, InvalidRequest) and error.__cause__ is not None:
        return type(error.__cause__).__name__
    if isinstance(error, (InvalidRequest, UnsupportedProtocol)):
        return 'ValueError'
    if isinstance(error, (MissingDependency, EngineFailed)):
        return 'RuntimeError'
    return type(error).__name__
