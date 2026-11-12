#!/usr/bin/env python3
"""opengl32's unix side must be built from wine plus patches/wine-opengl-winios.patch.

The wine submodule does not carry the patch. Built from the plain tree, the
wow64 thunks read a 32-bit program's TEB at its guest address (Celeste: a read
of 0x302fdc, WowTebOffset of the 32-bit TEB at 0x302000, at the first WGL call).
build/ntdll-unix/build.sh therefore compiles a patched copy. When a wine tree
is checked out (WINE_SRC, or ./wine), the patch must also still apply to it.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
build = (root / 'build/ntdll-unix/build.sh').read_text()
patch = root / 'patches/wine-opengl-winios.patch'

assert patch.is_file(), 'patches/wine-opengl-winios.patch is missing'
assert 'GL_PATCH="$REPO_ROOT/patches/wine-opengl-winios.patch"' in build
for name in ('unix_wgl.c', 'unix_thunks.c'):
    line = re.search(r'compile_unixlib "([^"]+)/' + re.escape(name) + '"', build)
    assert line, f'{name} is not compiled'
    assert line.group(1) == '$GL_SRC', f'{name} is compiled from {line.group(1)}, not the patched copy'
assert "grep -q 'ios_wow_host_ptr' \"$GL_SRC/unix_private.h\"" in build, \
    'the build no longer checks that the thunks convert guest pointers'
text = patch.read_text()
for path in ('dlls/opengl32/unix_private.h', 'dlls/opengl32/unix_thunks.c', 'dlls/opengl32/unix_wgl.c'):
    assert f'diff --git a/{path} ' in text, path
assert '+    TEB32 *teb32_ptr = ios_wow_host_ptr( teb32 );' in text

wine = Path(os.environ.get('WINE_SRC', root / 'wine'))
if (wine / 'dlls/opengl32/unix_private.h').is_file():
    with tempfile.TemporaryDirectory(prefix='madeira-gl-') as tmp:
        shutil.copytree(wine / 'dlls/opengl32', Path(tmp) / 'dlls/opengl32')
        args = ['git', 'apply', "--include=dlls/opengl32/*"]
        fresh = subprocess.run(args + ['--check', str(patch)], cwd=tmp, capture_output=True)
        done = subprocess.run(args + ['--reverse', '--check', str(patch)], cwd=tmp, capture_output=True)
        assert fresh.returncode == 0 or done.returncode == 0, \
            'patches/wine-opengl-winios.patch neither applies to nor is already in ' + str(wine) + '\n' + fresh.stderr.decode()
    print('PASS: opengl32 unix side builds from the patched copy; the patch fits', wine)
else:
    print('PASS: opengl32 unix side builds from the patched copy (no wine tree here to apply it to)')
