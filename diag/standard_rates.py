# Diagnostic: give every sample at a non-standard rate a standard one (32000, 44100 or
# 48000, whichever is nearest), compensating with the header's pitch correction so the
# sample plays at the same pitch. Usage: standard_rates.py in.sf2 out.sf2
import math, struct, sys
data = bytearray(open(sys.argv[1], 'rb').read())
pd = data.find(b'pdta') + 4
o = pd
while True:
    cid = bytes(data[o:o+4]); sz = struct.unpack('<I', data[o+4:o+8])[0]
    if cid == b'shdr': break
    o += 8 + sz
changed = 0
for rec in range(o + 8, o + 8 + sz - 46, 46):
    rate = struct.unpack('<I', data[rec+36:rec+40])[0]
    if rate in (11025, 22050, 32000, 44100, 48000) or rate == 0: continue
    target = min((32000, 44100, 48000), key=lambda r: abs(r - rate))
    # Same playback speed: rate / target in pitch, made up by the correction (cents).
    cents = 1200 * math.log2(rate / target)
    corr = struct.unpack('<b', data[rec+41:rec+42])[0] + round(cents)
    if not -128 <= corr <= 127: continue
    struct.pack_into('<I', data, rec + 36, target)
    struct.pack_into('<b', data, rec + 41, corr)
    changed += 1
open(sys.argv[2], 'wb').write(data)
print('standard rates on', changed, 'samples')
