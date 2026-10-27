# Diagnostic: copy a SoundFont with every preset and instrument modulator removed
# (zones keep their generators). Usage: strip_mods.py in.sf2 out.sf2
import struct, sys
data = bytearray(open(sys.argv[1], 'rb').read())
def find(tag, start=12):
    off = start
    while off < len(data):
        cid = bytes(data[off:off+4]); size = struct.unpack('<I', data[off+4:off+8])[0]
        if cid in (b'RIFF', b'LIST'):
            r = find(tag, off + 12)
            if r: return r
        elif cid == tag:
            return off, size
        off += 8 + size + (size & 1)
    return None
out = bytearray()
# Rebuild pdta: zero every bag's modulator index and shrink pmod/imod to the terminal record.
for bag, mod in ((b'pbag', b'pmod'), (b'ibag', b'imod')):
    off, size = find(bag)
    for i in range(off + 8, off + 8 + size, 4):
        struct.pack_into('<H', data, i + 2, 0)
pd_off = data.find(b'pdta') - 8
pd_size = struct.unpack('<I', data[pd_off+4:pd_off+8])[0]
body = bytearray(b'pdta'); off = pd_off + 12
while off < pd_off + 8 + pd_size:
    cid = bytes(data[off:off+4]); size = struct.unpack('<I', data[off+4:off+8])[0]
    payload = data[off+8:off+8+size]
    if cid in (b'pmod', b'imod'):
        payload = bytes(10)
    body += cid + struct.pack('<I', len(payload)) + payload
    off += 8 + size
new = data[:pd_off] + b'LIST' + struct.pack('<I', len(body)) + body
struct.pack_into('<I', new, 4, len(new) - 8)
open(sys.argv[2], 'wb').write(new)
print('stripped', len(data), '->', len(new))
