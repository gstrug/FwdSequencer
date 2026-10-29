#!/usr/bin/env python3
"""Build one General MIDI SoundFont from two, choosing per program which bank each
sound comes from.

Usage: merge_banks.py gu.sf2 fluid.sf2 picks.json out.sf2
picks.json maps "0".."127" (bank 0 programs) and "128" (the drum kit, bank 128
program 0) to "gu" or "fl". The output holds exactly those 129 presets, the
instruments and modulators they use, and only the samples those reference, with
the 46 zero points the SoundFont standard wants after each sample.
"""
import json, struct, sys

def riff_lists(d):
    out = {}
    off = 12
    while off + 12 <= len(d):
        cid = d[off:off+4]; size = struct.unpack('<I', d[off+4:off+8])[0]
        if cid == b'LIST': out[d[off+8:off+12]] = (off + 12, off + 8 + size)
        off += 8 + size + (size & 1)
    return out

def sub_chunks(d, start, end):
    out = {}
    o = start
    while o + 8 <= end:
        cid = d[o:o+4]; sz = struct.unpack('<I', d[o+4:o+8])[0]
        out[cid] = d[o+8:o+8+sz]
        o += 8 + sz + (sz & 1)
    return out

class Bank:
    def __init__(self, path):
        d = open(path, 'rb').read()
        L = riff_lists(d)
        sd = sub_chunks(d, *L[b'sdta']); pd = sub_chunks(d, *L[b'pdta'])
        if b'sm24' in sd: print('note: ignoring 24-bit extension in', path)
        self.smpl = sd[b'smpl']
        rec = lambda tag, n: [pd[tag][i:i+n] for i in range(0, len(pd[tag]), n)]
        self.phdr = [struct.unpack('<20sHHHIII', r) for r in rec(b'phdr', 38)]
        self.pbag = [struct.unpack('<HH', r) for r in rec(b'pbag', 4)]
        self.pmod = rec(b'pmod', 10)
        self.pgen = [struct.unpack('<HH', r) for r in rec(b'pgen', 4)]
        self.inst = [struct.unpack('<20sH', r) for r in rec(b'inst', 22)]
        self.ibag = [struct.unpack('<HH', r) for r in rec(b'ibag', 4)]
        self.imod = rec(b'imod', 10)
        self.igen = [struct.unpack('<HH', r) for r in rec(b'igen', 4)]
        self.shdr = [struct.unpack('<20sIIIIIBbHH', r) for r in rec(b'shdr', 46)]

    def preset(self, bank, prog):
        for k in range(len(self.phdr) - 1):
            if self.phdr[k][2] == bank and self.phdr[k][1] == prog: return k
        raise SystemExit(f'missing preset bank {bank} program {prog}')

gu, fl = Bank(sys.argv[1]), Bank(sys.argv[2])
picks = json.load(open(sys.argv[3]))
banks = {'gu': gu, 'fl': fl}

phdr, pbag, pmod, pgen = [], [], [], []
inst, ibag, imod, igen = [], [], [], []
shdr, smpl = [], bytearray()
inst_map, sample_map = {}, {}      # (bank key, old index) -> new index

def add_sample(key, b, s):
    if (key, s) in sample_map: return sample_map[(key, s)]
    name, start, end, ls, le, rate, pitch, corr, link, stype = b.shdr[s]
    new = len(shdr); sample_map[(key, s)] = new
    shdr.append(None)
    base = len(smpl) // 2
    smpl.extend(b.smpl[start*2:end*2]); smpl.extend(bytes(46 * 2))
    newlink = 0
    if stype in (2, 4, 8) and link < len(b.shdr) - 1:      # right/left/linked: keep the pair
        newlink = add_sample(key, b, link)
    shdr[new] = (name, base, base + (end - start), base + (ls - start), base + (le - start),
                 rate, pitch, corr, newlink, stype)
    return new

def add_inst(key, b, i):
    if (key, i) in inst_map: return inst_map[(key, i)]
    new = len(inst); inst_map[(key, i)] = new
    inst.append((b.inst[i][0], len(ibag)))
    for zb in range(b.inst[i][1], b.inst[i+1][1]):
        ibag.append((len(igen), len(imod)))
        imod.extend(b.imod[b.ibag[zb][1]:b.ibag[zb+1][1]])
        for op, amt in b.igen[b.ibag[zb][0]:b.ibag[zb+1][0]]:
            if op == 53: amt = add_sample(key, b, amt)
            igen.append((op, amt))
    return new

for n in range(129):
    key = picks[str(n)]; b = banks[key]
    bank, prog = (128, 0) if n == 128 else (0, n)
    k = b.preset(bank, prog)
    name, p, bk, bag, lib, genre, morph = b.phdr[k]
    phdr.append((name, prog, bank, len(pbag), lib, genre, morph))
    for zb in range(bag, b.phdr[k+1][3]):
        pbag.append((len(pgen), len(pmod)))
        pmod.extend(b.pmod[b.pbag[zb][1]:b.pbag[zb+1][1]])
        for op, amt in b.pgen[b.pbag[zb][0]:b.pbag[zb+1][0]]:
            if op == 41: amt = add_inst(key, b, amt)
            pgen.append((op, amt))

# Terminal records.
phdr.append((b'EOP', 0, 0, len(pbag), 0, 0, 0)); pbag.append((len(pgen), len(pmod)))
pmod.append(bytes(10)); pgen.append((0, 0))
inst.append((b'EOI', len(ibag))); ibag.append((len(igen), len(imod)))
imod.append(bytes(10)); igen.append((0, 0))
shdr.append((b'EOS', 0, 0, 0, 0, 0, 0, 0, 0, 0))

def chunk(tag, payload):
    return tag + struct.pack('<I', len(payload)) + payload + (b'\0' if len(payload) & 1 else b'')
def lst(kind, body): return chunk(b'LIST', kind + body)
def zstr(s):
    b = s.encode('ascii') + b'\0'
    return b + (b'\0' if len(b) & 1 else b'')

info = lst(b'INFO', chunk(b'ifil', struct.pack('<HH', 2, 1)) + chunk(b'isng', zstr('EMU8000')) +
           chunk(b'INAM', zstr('FWD General MIDI')) +
           chunk(b'ICMT', zstr('For FWD Sequencer: General MIDI presets chosen per program from '
                               'GeneralUser GS v2.0.3 by S. Christian Collins and FluidR3_GM by '
                               'Frank Wen (MIT license), patched for Apple AUSampler.')))
sdta = lst(b'sdta', chunk(b'smpl', bytes(smpl)))
pdta = lst(b'pdta',
    chunk(b'phdr', b''.join(struct.pack('<20sHHHIII', *r) for r in phdr)) +
    chunk(b'pbag', b''.join(struct.pack('<HH', *r) for r in pbag)) +
    chunk(b'pmod', b''.join(pmod)) +
    chunk(b'pgen', b''.join(struct.pack('<HH', *r) for r in pgen)) +
    chunk(b'inst', b''.join(struct.pack('<20sH', *r) for r in inst)) +
    chunk(b'ibag', b''.join(struct.pack('<HH', *r) for r in ibag)) +
    chunk(b'imod', b''.join(imod)) +
    chunk(b'igen', b''.join(struct.pack('<HH', *r) for r in igen)) +
    chunk(b'shdr', b''.join(struct.pack('<20sIIIIIBbHH', *r) for r in shdr)))
body = b'sfbk' + info + sdta + pdta
open(sys.argv[4], 'wb').write(b'RIFF' + struct.pack('<I', len(body)) + body)
print(f'presets {len(phdr)-1}, instruments {len(inst)-1}, samples {len(shdr)-1}, '
      f'{(12 + len(body)) / 1e6:.1f} MB, from FluidR3 {sum(1 for v in picks.values() if v == "fl")}')
