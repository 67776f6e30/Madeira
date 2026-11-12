#!/usr/bin/env python3
"""setprogname() must get a name that outlives the game.

setprogname() keeps the pointer it is given. On iOS the Wine "process" is a
thread of the app, and argv[0] is the launcher's local buffer, so the name
dangled once a game exited and the app crashed in the next getprogname()
reader (nwi_state_copy -> strdup). The name is copied into static storage.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/env_ios.c').read_text()
start = src.index('static void set_process_name( const char *name )')
body = src[start:src.index('\n}', start)]
calls = re.findall(r'setprogname\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)', body)
assert calls == ['progname'], f'setprogname is called with {calls}, not the static copy'
assert re.search(r'static char progname\[\d+\];', body), 'the copy is not static storage'
assert 'snprintf( progname, sizeof(progname), "%s", name );' in body
print('PASS: setprogname gets a static copy of the process name')
