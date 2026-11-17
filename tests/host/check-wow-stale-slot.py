#!/usr/bin/env python3
"""A booting 32-bit process must not adopt another running process's guest window.

Device log 2026-11-18 (Battle.net, eight 32-bit processes): a third Chromium
renderer resolved the second renderer's live window in ios_wow_window_reserve,
booted inside it (child_peb 0x7701960000 in B=0x7700000000) and crashed in
wow64.dll at its first instruction (write to 0x480).

Static anchors: the reservation only counts an unbound slot as "already ours",
drops this thread as owner of bound slots, and the child boot clears a stale
TEB reference before reserving.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
virt = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
loader = (root / 'build/ntdll-unix/loader_ios.c').read_text()
catalog = (root / 'app/Madeira/ConfigCatalog.generated.swift').read_text()

body = virt[virt.index('static NTSTATUS ios_wow_window_reserve_once(void)\n{'):]
body = body[:body.index('\n}\n')]
assert 'if (ios_wow_slot_current())' not in body, 'a bound slot is still taken as this thread\'s window'
assert re.search(r'if \(cur && \(!cur->peb \|\| \(old && old\[0\] == \'1\'\)\)\)', body), \
    'only an unbound slot may count as already reserved'
assert 'memset( &ios_wow_windows[i].owner, 0' in body, 'bound slots keep this thread as owner'
assert 'MADEIRA_WOW_STALE_SLOT_REUSE' in body

boot = loader[loader.index('CHILD_STAGE( "guest-window-reserve" );'):]
boot = boot[:boot.index('status = ios_wow_window_reserve();')]
assert 'pthread_setspecific( ios_teb_tls_key, NULL );' in boot, 'stale TEB key not cleared before the reservation'

assert 'key: "env.MADEIRA_WOW_STALE_SLOT_REUSE"' in catalog, 'catalog does not list env.MADEIRA_WOW_STALE_SLOT_REUSE'
print('check-wow-stale-slot: OK')
