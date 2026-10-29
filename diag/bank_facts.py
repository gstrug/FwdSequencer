# For each General MIDI program (and the drum kit), the preset name and the bytes of
# sample data its instruments use. Usage: bank_facts.py bank.sf2 > facts.json
import json, struct, sys
d = open(sys.argv[1], 'rb').read()
def find_list(kind):
    off = 12
    while off + 12 <= len(d):
        cid = d[off:off+4]; size = struct.unpack('<I', d[off+4:off+8])[0]
        if cid == b'LIST' and d[off+8:off+12] == kind: return off + 12, off + 8 + size
        off += 8 + size + (size & 1)
pd, pend = find_list(b'pdta')
chunks = {}
o = pd
while o < pend:
    cid = d[o:o+4]; sz = struct.unpack('<I', d[o+4:o+8])[0]; chunks[cid] = d[o+8:o+8+sz]; o += 8 + sz + (sz & 1)
def recs(tag, fmt, n): return [struct.unpack(fmt, chunks[tag][i:i+n]) for i in range(0, len(chunks[tag]), n)]
P = recs(b'phdr', '<20sHHH', 38) if False else [struct.unpack('<20sHHH', chunks[b'phdr'][i:i+26]) for i in range(0, len(chunks[b'phdr']), 38)]
PB = recs(b'pbag', '<HH', 4); PG = recs(b'pgen', '<Hh', 4)
I = [struct.unpack('<20sH', chunks[b'inst'][i:i+22]) for i in range(0, len(chunks[b'inst']), 22)]
IB = recs(b'ibag', '<HH', 4); IG = recs(b'igen', '<Hh', 4)
S = [struct.unpack('<20sII', chunks[b'shdr'][i:i+28]) for i in range(0, len(chunks[b'shdr']), 46)]
out = {}
for k in range(len(P) - 1):
    name, prog, bank, bag = P[k]
    if not ((bank == 0 and prog < 128) or (bank == 128 and prog == 0)): continue
    key = 128 if bank == 128 else prog
    samples = set()
    for b in range(bag, P[k+1][3]):
        for g in range(PB[b][0], PB[b+1][0]):
            if PG[g][0] == 41:
                ii = PG[g][1]
                for zb in range(I[ii][1], I[ii+1][1]):
                    for gg in range(IB[zb][0], IB[zb+1][0]):
                        if IG[gg][0] == 53: samples.add(IG[gg][1])
    out[key] = {'name': name.split(b'\0')[0].decode('latin1'), 'bytes': sum((S[s][2] - S[s][1]) * 2 for s in samples),
                'samples': sorted(samples)}
out['sampleBytes'] = {i: (S[i][2] - S[i][1]) * 2 for i in range(len(S) - 1)}
out['fileBytes'] = len(d)
print(json.dumps(out))
