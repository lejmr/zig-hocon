"""Packs one wheel of zig_hocon: the Python files of python/zig_hocon/, the
library zig built for one platform, and the metadata of python/pyproject.toml.
`zig build wheels` runs it once per platform; nothing here needs pip.

    python3 tools/wheel.py <out.whl> <version> <tag>[.<tag>…] <library> <name in the package>

The wheel is `py3-none-<platform>`: ctypes loads the library, so it holds no
code of any one Python. Every file has the same date, so the same inputs make
the same wheel byte for byte.
"""

import base64
import hashlib
import os
import sys
import tomllib
import zipfile

out, version, platform, library, lib_name = sys.argv[1:]
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
python = os.path.join(root, "python")

with open(os.path.join(python, "pyproject.toml"), "rb") as f:
    project = tomllib.load(f)["project"]
# build.zig.zon has the version; pip install python/ takes pyproject's.
if project["version"] != version:
    sys.exit(f"wheel: python/pyproject.toml has version {project['version']}, build.zig.zon {version}")
# pip reads the semver 0.2.0-rc.1 in a wheel's name as a build tag, and
# refuses it; PEP 440 spells it 0.2.0rc1, which build.zig.zon does not take.
if "-" in version:
    sys.exit(f"wheel: {version} is a pre-release, which has no wheel name pip takes")

name = project["name"].replace("-", "_")
dist_info = f"{name}-{version}.dist-info"

with open(os.path.join(python, "README.md")) as f:
    readme = f.read()
metadata = [
    "Metadata-Version: 2.4",
    f"Name: {project['name']}",
    f"Version: {version}",
    f"Summary: {project['description']}",
    f"License-Expression: {project['license']}",
    "License-File: LICENSE",
    f"Requires-Python: {project['requires-python']}",
    *[f"Classifier: {c}" for c in project["classifiers"]],
    *[f"Project-URL: {k}, {v}" for k, v in project["urls"].items()],
    "Description-Content-Type: text/markdown",
    "",
    readme,
]
# A compressed tag, `manylinux_2_17_x86_64.manylinux2014_x86_64`, is a line for each.
wheel = ["Wheel-Version: 1.0", "Generator: zig-hocon tools/wheel.py", "Root-Is-Purelib: false"]
wheel += [f"Tag: py3-none-{tag}" for tag in platform.split(".")]

files = []  # (path in the wheel, bytes, executable)
package = os.path.join(python, name)
for file in sorted(os.listdir(package)):
    if file.endswith(".py") and not file.startswith("."):  # not an editor's .#lock.py
        with open(os.path.join(package, file), "rb") as f:
            files.append((f"{name}/{file}", f.read(), False))
with open(library, "rb") as f:
    files.append((f"{name}/{lib_name}", f.read(), True))
with open(os.path.join(root, "LICENSE"), "rb") as f:
    files.append((f"{dist_info}/licenses/LICENSE", f.read(), False))
files.append((f"{dist_info}/METADATA", "\n".join(metadata).encode(), False))
files.append((f"{dist_info}/WHEEL", ("\n".join(wheel) + "\n").encode(), False))


def record_line(path, data):
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
    return f"{path},sha256={digest},{len(data)}"


record = [record_line(path, data) for path, data, _ in files] + [f"{dist_info}/RECORD,,"]
files.append((f"{dist_info}/RECORD", ("\n".join(record) + "\n").encode(), False))

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as whl:
    for path, data, executable in files:
        info = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
        info.external_attr = (0o755 if executable else 0o644) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        whl.writestr(info, data)
