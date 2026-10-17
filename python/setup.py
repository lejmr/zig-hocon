# The wheel holds libhocon, built for one platform, and no code of any one
# Python (ctypes): tagged py3-none-<platform>, one wheel for every Python 3.
import os

from setuptools import Distribution, setup
from setuptools.command.bdist_wheel import bdist_wheel
from setuptools.command.build_py import build_py

LIBS = ["libhocon.so", "libhocon.dylib", "hocon.dll"]

# A package without its library installs fine and fails on import.
here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "zig_hocon")
if not any(os.path.exists(os.path.join(here, lib)) for lib in LIBS):
    raise SystemExit("zig_hocon: no libhocon in python/zig_hocon/; run `zig build python` first")


class BinaryDistribution(Distribution):
    # A native library inside: platform-specific, as an extension would be.
    def has_ext_modules(self):
        return True


class PlatformWheel(bdist_wheel):
    def get_tag(self):
        return "py3", "none", super().get_tag()[2]


class CopyAlways(build_py):
    # build_py copies a file only when it is newer than the copy in build/.
    # `zig build python` gives the library the date of zig's cached build,
    # which can be older: the library of an earlier build would stay.
    def finalize_options(self):
        super().finalize_options()
        self.force = True


setup(distclass=BinaryDistribution, cmdclass={"bdist_wheel": PlatformWheel, "build_py": CopyAlways})
