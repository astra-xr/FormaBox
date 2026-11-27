"""Stage the Windows Python and the wheels used by the worker."""
from importlib.metadata import distribution
from pathlib import Path
from shutil import copy2, copytree, ignore_patterns
import sys


RUNTIME_PACKAGES = (
    "Pillow", "pypdf", "pypdfium2", "cryptography", "cffi", "pycparser",
    "openpyxl", "et-xmlfile", "py7zr", "texttable", "pycryptodomex", "brotli",
    "psutil", "backports.zstd", "pyppmd", "pybcj", "multivolumefile", "inflate64",
)


def stage_runtime(destination: Path) -> None:
    base = Path(sys.base_prefix)
    version = f"{sys.version_info.major}{sys.version_info.minor}"
    destination.mkdir()
    for filename in ("python.exe", "python3.dll", f"python{version}.dll", "LICENSE.txt"):
        copy2(base / filename, destination / filename)

    copytree(base / "DLLs", destination / "DLLs",
             ignore=ignore_patterns("*.lib", "*.pdb", "_test*"))
    lib = destination / "Lib"
    copytree(base / "Lib", lib, ignore=ignore_patterns(
        "__pycache__", "site-packages", "test", "tests", "idlelib", "ensurepip", "venv"
    ))

    for name in RUNTIME_PACKAGES:
        package = distribution(name)
        package_root = Path(package.locate_file("")).resolve()
        for entry in package.files or ():
            source = Path(package.locate_file(entry)).resolve()
            if not source.is_relative_to(package_root) or source.suffix == ".pyc":
                continue
            relative = source.relative_to(package_root)
            target = lib / "site-packages" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            copy2(source, target)
        print(f"{package.metadata['Name']}=={package.version}")

    (destination / f"python{version}._pth").write_text(
        ".\nLib\nDLLs\nLib/site-packages\n../worker\n", encoding="ascii"
    )


if __name__ == "__main__":
    stage_runtime(Path(sys.argv[1]))
