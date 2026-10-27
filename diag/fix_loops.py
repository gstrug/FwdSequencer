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
open(sys.argv[2], 'wb').write(data)
print(f'samples {total}, loop points moved on {fixed}')
