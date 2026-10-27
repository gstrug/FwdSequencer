#!/usr/bin/env python3
"""Make GeneralUser GS safe for Apple's sampler (AVAudioUnitSampler / AUSampler).

The bundled FwdSequencer/Resources/GeneralUser-GS.sf2 is GeneralUser GS v2.0.3
(github.com/mrbumpy409/GeneralUser-GS) passed through this script. Unchanged, some of
its instruments crash Apple's sampler while it plays (found 2026-10-27 by rendering
every instrument offline on a Mac): on the iPad that silenced tracks for stretches.

Two fixes, both inaudible in practice:
1. Loop points. The SoundFont standard wants at least 8 sample points after a loop's
   end; 181 of the 920 samples have their loop end on the very last point, and the
   sampler reads past it (the acoustic pianos crashed on a single note). Those loops
   are moved back by the shortfall, keeping their length.
2. Sample start offsets (generators 0 and 4, 595 of them, e.g. the strings) crash it
   too; they are set to 0, so each zone plays its sample from the start.

Usage: prepare_soundfont.py GeneralUser-GS.sf2 FwdSequencer/Resources/GeneralUser-GS.sf2
Result for v2.0.3: sha256 15bb8f571cbd8b1fdc4065b24f6a4facda016f88afe86b1eaee7bdb1f906e508
"""
import struct
import sys


def chunk(data, start, tag):
    off = start
    while True:
        cid = bytes(data[off:off + 4])
        size = struct.unpack('<I', data[off + 4:off + 8])[0]
        if cid == tag:
            return off, size
        off += 8 + size + (size & 1)


data = bytearray(open(sys.argv[1], 'rb').read())
pdta = data.find(b'pdta') + 4

off, size = chunk(data, pdta, b'shdr')
moved = 0
for rec in range(off + 8, off + 8 + size - 46, 46):          # the last record is the terminator
    _, start, end, ls, le = struct.unpack('<20sIIII', data[rec:rec + 36])
    if end - start < 64:
        continue
    if end - le < 8 or le <= ls or ls < start:
        length = max(32, min(le - ls if le > ls else 0, end - start - 16))
        new_le = min(le, end - 8) if le > ls else end - 8
        new_ls = max(start + 8, new_le - length)
        struct.pack_into('<II', data, rec + 28, new_ls, new_le)
        moved += 1

off, size = chunk(data, pdta, b'igen')
cleared = 0
for rec in range(off + 8, off + 8 + size, 4):
    if struct.unpack('<H', data[rec:rec + 2])[0] in (0, 4):
        struct.pack_into('<h', data, rec + 2, 0)
        cleared += 1

open(sys.argv[2], 'wb').write(data)
print(f'loop points moved on {moved} samples, {cleared} start offsets cleared')
