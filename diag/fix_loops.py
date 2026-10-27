# Make a SoundFont safe for Apple's AUSampler: every sample header gets at least 8
# sample points between its loop end and its end, as the SoundFont 2 standard asks
# (samplers interpolate a few points ahead). Loop points that run to the very end are
# moved back by the shortfall, keeping the loop's length. Usage: fix_loops.py in out
import struct, sys
data = bytearray(open(sys.argv[1], 'rb').read())
pd = data.find(b'pdta') + 4
off = pd
while True:
    cid = bytes(data[off:off+4]); size = struct.unpack('<I', data[off+4:off+8])[0]
    if cid == b'shdr': break
    off += 8 + size
fixed = 0; total = 0
for rec in range(off + 8, off + 8 + size - 46, 46):        # last record is the terminal one
    name, start, end, ls, le = struct.unpack('<20sIIII', data[rec:rec+36])
    total += 1
    need = 8
    if end - start < 64:               # too short to have loops at all
        continue
    if end - le < need or le <= ls or ls < start:
        length = max(32, min(le - ls if le > ls else 0, end - start - 2 * need))
        new_le = min(le, end - need) if le > ls else end - need
        new_ls = max(start + need, new_le - length)
        struct.pack_into('<II', data, rec + 28, new_ls, new_le)
        fixed += 1
# Sample start offsets (generators 0 and 4) crash AUSampler on some instruments:
# drop them, so every zone plays its sample from the start.
if '--no-start-offsets' in sys.argv:
    off2 = pd
    while True:
        cid = bytes(data[off2:off2+4]); size2 = struct.unpack('<I', data[off2+4:off2+8])[0]
        if cid == b'igen': break
        off2 += 8 + size2
    dropped = 0
    for rec in range(off2 + 8, off2 + 8 + size2, 4):
        op = struct.unpack('<H', data[rec:rec+2])[0]
        if op in (0, 4):
            struct.pack_into('<h', data, rec + 2, 0); dropped += 1
    print('start offsets removed:', dropped)
# Optionally drop filter generators (8 initialFilterFc, 9 initialFilterQ, 11 modEnvToFilterFc)
# everywhere, to see how much the per-voice filters cost.
if '--no-filters' in sys.argv:
    for chunk in (b'pgen', b'igen'):
        o = pd
        while True:
            cid = bytes(data[o:o+4]); sz = struct.unpack('<I', data[o+4:o+8])[0]
            if cid == chunk: break
            o += 8 + sz
        for rec in range(o + 8, o + 8 + sz, 4):
            op = struct.unpack('<H', data[rec:rec+2])[0]
            if op == 8: struct.pack_into('<h', data, rec + 2, 13500)   # fully open
            elif op in (9, 11): struct.pack_into('<h', data, rec + 2, 0)
open(sys.argv[2], 'wb').write(data)
print(f'samples {total}, loop points moved on {fixed}')
