# Make a SoundFont safe for Apple's AUSampler: every sample header gets at least 8
# sample points between its loop end and its end, as the SoundFont 2 standard asks
# (samplers interpolate a few points ahead). Loop points that run to the very end are
# moved back by the shortfall, keeping the loop's length. Usage: fix_loops.py in out
import struct, sys
data = bytearray(open(sys.argv[1], 'rb').read())
def find_list(data, kind):
    # Walk the RIFF chunks: the bytes 'pdta' can also occur inside the sample data.
    off = 12
    while off + 12 <= len(data):
        cid = bytes(data[off:off+4]); size = struct.unpack('<I', data[off+4:off+8])[0]
        if cid == b'LIST' and bytes(data[off+8:off+12]) == kind:
            return off + 12
        off += 8 + size + (size & 1)
    raise SystemExit('no LIST ' + kind.decode())
pd = find_list(data, b'pdta')
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
# Cap the release of the acoustic pianos (bank 0, programs 0-3) at CAP timecents in
# their instrument zones: GeneralUser GS rings them up to ~8 s after key-up.
cap_arg = [a for a in sys.argv if a.startswith('--piano-release=')]
if cap_arg:
    CAP = int(cap_arg[0].split('=')[1])
    def ch(tag):
        o = pd
        while True:
            cid = bytes(data[o:o+4]); sz = struct.unpack('<I', data[o+4:o+8])[0]
            if cid == tag: return o + 8, sz
            o += 8 + sz
    po, ps = ch(b'phdr'); bo, bs = ch(b'pbag'); go, gs = ch(b'pgen'); io, is_ = ch(b'inst'); ibo, ibs = ch(b'ibag'); igo, igs = ch(b'igen')
    P = [struct.unpack('<20sHHH', data[po+i:po+i+26]) for i in range(0, ps, 38)]
    PB = [struct.unpack('<HH', data[bo+i:bo+i+4]) for i in range(0, bs, 4)]
    PG = [struct.unpack('<Hh', data[go+i:go+i+4]) for i in range(0, gs, 4)]
    I = [struct.unpack('<20sH', data[io+i:io+i+22]) for i in range(0, is_, 22)]
    IB = [struct.unpack('<HH', data[ibo+i:ibo+i+4]) for i in range(0, ibs, 4)]
    insts = set()
    for k in range(len(P) - 1):
        if P[k][2] == 0 and P[k][1] in (0, 1, 2, 3):
            for b in range(P[k][3], P[k+1][3]):
                for g in range(PB[b][0], PB[b+1][0]):
                    if PG[g][0] == 41: insts.add(PG[g][1])
    capped = 0
    for ii in insts:
        for zb in range(I[ii][1], I[ii+1][1]):
            for g in range(IB[zb][0], IB[zb+1][0]):
                rec = igo + g * 4
                op, amt = struct.unpack('<Hh', data[rec:rec+4])
                if op == 38 and amt > CAP:
                    struct.pack_into('<h', data, rec + 2, CAP); capped += 1
    print('piano instruments', len(insts), 'release capped on', capped, 'zones at', CAP)
open(sys.argv[2], 'wb').write(data)
print(f'samples {total}, loop points moved on {fixed}')
