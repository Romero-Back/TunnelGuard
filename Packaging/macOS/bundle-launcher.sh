#!/bin/sh
set -eu

packaging_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
scripts="$packaging_dir/../../Scripts"
destination=$1
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/tunnelguard-launcher.XXXXXX")
trap 'rm -rf -- "$build_dir"' EXIT

install -m 644 "$scripts/tunnelguard-run.py" "$build_dir/tunnelguard_runner.py"
install -m 644 "$scripts/tunnelguard-control.py" "$build_dir/tunnelguard_control.py"
"${TUNNELGUARD_PYINSTALLER_PYTHON:?}" -m PyInstaller --noconfirm --onedir --name tunnelguard-native \
    --paths "$build_dir" --specpath "$build_dir" --workpath "$build_dir/work" --distpath "$build_dir/dist" \
    "$scripts/tunnelguard-native.py"
ditto "$build_dir/dist/tunnelguard-native" "$destination"
"$TUNNELGUARD_PYINSTALLER_PYTHON" - "$destination" <<'PY'
from importlib.metadata import distribution
from pathlib import Path
import shutil
import sys
import sysconfig

licenses = Path(sys.argv[1], "Licenses")
licenses.mkdir(exist_ok=True)
shutil.copyfile(Path(sysconfig.get_path("stdlib"), "LICENSE.txt"), licenses / "Python.txt")
builder = distribution("pyinstaller")
copying = next(entry for entry in builder.files if entry.name == "COPYING.txt" and "licenses" in entry.parts)
shutil.copyfile(builder.locate_file(copying), licenses / "PyInstaller.txt")
PY
