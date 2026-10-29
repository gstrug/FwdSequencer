# Diagnostic: for the acoustic pianos (bank 0, programs 0, 1, 3), park every preset zone
# whose velocity range does not include velocity 96 on key 0, so only one velocity layer
# can sound for the test's notes. Usage: one_layer.py in.sf2 out.sf2
import struct, sys
data = bytearray(open(sys.argv[1], 'rb').read())
pd = data.find(b'pdta') + 4
def ch(tag):
    o = pd
    while True:
        cid = bytes(data[o:o+4]); sz = struct.unpack('<I', data[o+4:o+8])[0]
        if cid == tag: return o + 8, sz
        o += 8 + sz
po, ps = ch(b'phdr'); bo, bs = ch(b'pbag'); go, gs = ch(b'pgen')
P = [struct.unpack('<20sHHH', data[po+i:po+i+26]) for i in range(0, ps, 38)]
PB = [struct.unpack('<HH', data[bo+i:bo+i+4]) for i in range(0, bs, 4)]
parked = 0; layers = {}
for k in range(len(P) - 1):
    if P[k][2] != 0 or P[k][1] not in (0, 1, 3): continue
    for b in range(P[k][3], P[k+1][3]):
        gens = {}
        for g in range(PB[b][0], PB[b+1][0]):
            op, amt = struct.unpack('<HH', data[go+g*4:go+g*4+4]); gens[op] = (g, amt)
        if 44 in gens:
            lo, hi = gens[44][1] & 0xFF, gens[44][1] >> 8
            layers.setdefault(P[k][1], set()).add((lo, hi))
            if not lo <= 96 <= hi and 43 in gens:
                struct.pack_into('<H', data, go + gens[43][0]*4 + 2, 0)   # keyRange 0-0
                parked += 1
print('velocity layers per piano', {k: sorted(v) for k, v in layers.items()}, 'zones parked', parked)
open(sys.argv[2], 'wb').write(data)
