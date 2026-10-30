#!/usr/bin/env python3
"""Writes FWD Sequencer's templates and example songs as .json song documents.

    python3 Tools/make_examples.py            # writes FwdSequencer/Resources/*.json

The music is written here as notes in time (a small text notation, below) and turned
into the step language: a note or chord is a Play step, its length Holds after it, a
gap a Pause. The generative parts are written straight in steps (Fwd, Back, Random,
probability…), since that is what they demonstrate.

Notation, one token per note, chord or rest:
    F#5:4        F#5 for 4 steps
    D3+A3+C#4:2  a chord for 2 steps
    r:2          a rest of 2 steps
    …@90         velocity 90 (else the line's default)
    …~0.5        articulation: sounds for half its length (else the line's default)
Drum grids: one string per drum, one character per step: X loud, x normal, o soft,
- ghost, . nothing.

Ids are derived from names, so regenerating gives the same files (the app gives each
new song fresh ids when it creates it).
"""
import json, os, re, uuid, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "FwdSequencer", "Resources")

NAMESPACE = uuid.UUID("6f1c2a52-3b7e-4f0a-9d1e-46574401aa00")
def uid(*parts):
    return str(uuid.uuid5(NAMESPACE, "/".join(str(p) for p in parts))).upper()

DIVISIONS = {  # name in the file, sequencer ticks (24 per quarter)
    "1/1": ("Whole", 96), "1/2": ("Half", 48), "1/4": ("Quarter", 24),
    "1/4T": ("Quarter Triplet", 16), "1/8": ("Eighth", 12), "1/8T": ("Eighth Triplet", 8),
    "1/16": ("Sixteenth", 6), "1/16T": ("Sixteenth Triplet", 4),
}
DRUMS = 128  # GeneralMIDI.drumKit
NOTE_INDEX = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}

def pitch(name):
    m = re.fullmatch(r"([A-G])([#b]?)(-?\d)", name)
    if not m:
        raise ValueError(f"bad note {name}")
    p = NOTE_INDEX[m.group(1)] + {"#": 1, "b": -1, "": 0}[m.group(2)]
    return p + (int(m.group(3)) + 1) * 12

# ---------------------------------------------------------------- notes in time

class Line:
    """Notes in time for one track in one section, in steps of its division."""
    def __init__(self, vel=90, gate=0.9):
        self.events = []   # (start, length, [pitches], velocity, gate)
        self.t = 0
        self.vel, self.gate = vel, gate

    def add(self, text, vel=None, gate=None, transpose=0):
        for token in text.split():
            m = re.fullmatch(r"([^:]+):(\d+)(?:@(\d+))?(?:~([\d.]+))?", token)
            if not m:
                raise ValueError(f"bad token {token}")
            what, length = m.group(1), int(m.group(2))
            v = int(m.group(3)) if m.group(3) else (vel or self.vel)
            g = float(m.group(4)) if m.group(4) else (gate or self.gate)
            if what != "r":
                notes = [pitch(n) + transpose for n in what.split("+")]
                self.events.append((self.t, length, notes, v, g))
            self.t += length
        return self

    def at(self, start, length, notes, vel=None, gate=None):
        self.events.append((start, length, [pitch(n) if isinstance(n, str) else n for n in notes],
                            vel or self.vel, gate or self.gate))
        self.t = max(self.t, start + length)
        return self

    def drums(self, grid, levels=None, gate=0.5):
        """{drum note: 'x..x'} → events, one step each, struck together."""
        levels = levels or {"X": 118, "x": 96, "o": 66, "-": 42}
        length = max(len(g) for g in grid.values())
        hits = {}
        for note, pattern in grid.items():
            for i, ch in enumerate(pattern):
                if ch in levels:
                    hits.setdefault(i, []).append((note, levels[ch]))
        for i in sorted(hits):
            for note, v in hits[i]:
                self.events.append((i, 1, [note], v, gate))
        self.t = max(self.t, length)
        return self

def steps_from_events(events, total):
    """Notes in time → (pool, steps). Notes starting together form one chord; a new
    onset ends what was sounding; each note keeps its length through the step gate."""
    groups = {}
    for start, length, notes, v, g in events:
        if start >= total:
            continue
        group = groups.setdefault(start, {"len": length, "gate": g, "notes": {}})
        group["len"] = max(group["len"], length)
        group["gate"] = max(group["gate"], g)
        for n in notes:
            group["notes"][n] = max(group["notes"].get(n, 0), v)
    keys = sorted({(n, v) for gr in groups.values() for n, v in gr["notes"].items()})
    position = {k: i + 1 for i, k in enumerate(keys)}
    pool = [{"midiNote": n, "velocity": v, "gateLength": 1.0} for n, v in keys]
    steps = []
    onsets = sorted(groups)
    t = 0
    while t < total:
        if t in groups:
            gr = groups[t]
            nxt = next((o for o in onsets if o > t), total)
            length = max(1, min(gr["len"], nxt - t))
            positions = sorted(position[(n, v)] for n, v in gr["notes"].items())
            step = {"type": "Play", "n": positions[0], "gate": round(min(1.0, max(0.05, gr["gate"])), 3)}
            if len(positions) > 1:
                step["chordPositions"] = positions
            steps.append(step)
            if length > 1:
                steps.append({"type": "Hold", "n": length - 1})
            t += length
        else:
            nxt = next((o for o in onsets if o > t), total)
            steps.append({"type": "Pause", "n": nxt - t})
            t = nxt
    return pool, steps

# ---------------------------------------------------------------- steps directly

def S(kind, n=1, chord=None, gate=1.0, prob=1.0, ratchets=1):
    step = {"type": {"fwd": "Fwd", "back": "Back", "rep": "Repeat", "play": "Play",
                     "random": "Random", "hold": "Hold", "pause": "Pause"}[kind],
            "n": n, "gate": gate, "probability": prob, "ratchets": ratchets}
    if chord:
        step["chordPositions"] = chord
    return step

def pool_of(names, vel=80, gate=1.0):
    out = []
    for name in names:
        if isinstance(name, tuple):
            out.append({"midiNote": pitch(name[0]), "velocity": name[1], "gateLength": gate})
        else:
            out.append({"midiNote": pitch(name), "velocity": vel, "gateLength": gate})
    return out

# ---------------------------------------------------------------- song building

class SongBuilder:
    def __init__(self, name, tempo, ts=(4, 4), seed=0x46574410):
        self.name, self.tempo, self.ts, self.seed = name, tempo, ts, seed
        self.tracks, self.sections = [], []
        self.extra = {}

    def track(self, key, name, sound, volume=0.8, pan=0.0, **feel):
        t = {"id": uid(self.name, "track", key), "name": name,
             "mixer": {"volume": volume, "pan": pan, "isMuted": False, "isSoloed": False}}
        if sound:
            t["builtInSound"] = sound
        for k, v in feel.items():
            t[{"spread": "chordSpread", "jitter": "timingJitter"}.get(k, k)] = v
        t["_key"] = key
        self.tracks.append(t)
        return key

    def bar_ticks(self):
        return self.ts[0] * 96 // self.ts[1]

    def section(self, key, name, bars, parts):
        """parts: {track key: (division, Line) | (division, pool, steps) | None}"""
        sec = {"id": uid(self.name, "section", key), "name": name, "numberOfBars": bars,
               "variations": [], "parts": [], "_key": key}
        for t in self.tracks:
            spec = parts.get(t["_key"])
            part = {"trackID": t["id"], "notePool": [], "steps": [], "tempoDivision": "Quarter",
                    "key": 0, "scale": "Chromatic"}
            if spec is not None:
                division = spec[0]
                name_, ticks = DIVISIONS[division]
                total = bars * self.bar_ticks() // ticks
                assert bars * self.bar_ticks() % ticks == 0, (name, t["name"])
                part["tempoDivision"] = name_
                if isinstance(spec[1], Line):
                    line = spec[1]
                    length = spec[2] if len(spec) > 2 else total
                    assert total % length == 0, (name, t["name"], total, length)
                    pool, steps = steps_from_events(line.events, length)
                else:
                    pool, steps = spec[1], spec[2]
                    if len(spec) > 3:
                        part["key"], part["scale"] = spec[3]
                for i, n in enumerate(pool):
                    n["id"] = uid(self.name, key, t["_key"], "note", i)
                for i, s in enumerate(steps):
                    s.setdefault("chordPositions", [])
                    s.setdefault("gate", 1.0)
                    s.setdefault("probability", 1.0)
                    s.setdefault("ratchets", 1)
                    s["id"] = uid(self.name, key, t["_key"], "step", i)
                part["notePool"], part["steps"] = pool, steps
            sec["parts"].append(part)
        self.sections.append(sec)
        return key

    def song_part(self, key, name, section_keys):
        parts = self.extra.setdefault("songParts", [])
        ids = [s["id"] for k in section_keys for s in self.sections if s["_key"] == k]
        parts.append({"id": uid(self.name, "part", key), "name": name, "sectionIDs": ids})
        return ("part", key)

    def arrange(self, slots):
        arrangement = []
        for i, slot in enumerate(slots):
            entry = {"id": uid(self.name, "slot", i)}
            if isinstance(slot, tuple):
                entry["partID"] = uid(self.name, "part", slot[1])
            else:
                entry["sectionID"] = next(s["id"] for s in self.sections if s["_key"] == slot)
            arrangement.append(entry)
        self.extra["arrangement"] = arrangement
        self.extra["playsArrangement"] = True

    def build(self, **flags):
        tracks = [{k: v for k, v in t.items() if not k.startswith("_")} for t in self.tracks]
        sections = [{k: v for k, v in s.items() if not k.startswith("_")} for s in self.sections]
        song = {"formatVersion": 2, "id": uid(self.name, "song"), "name": self.name,
                "tempo": float(self.tempo),
                "timeSignature": {"numerator": self.ts[0], "denominator": self.ts[1]},
                "masterVolume": 1.0, "tracks": tracks, "sections": sections,
                "randomSeed": self.seed}
        song.update(self.extra)
        song.update(flags)
        return song

def voiced(chords, rhythm, bars_per_chord=1, vel=80, gate=0.6, steps_per_bar=16, accents=None):
    """Comping: each bar's chord struck on the rhythm's steps, each hit held to the next."""
    line = Line(vel=vel, gate=gate)
    for b, chord in enumerate(chords):
        hits = rhythm[b % len(rhythm)]
        for i, h in enumerate(hits):
            end = hits[i + 1] if i + 1 < len(hits) else steps_per_bar
            v = vel + (accents[i] if accents and i < len(accents) else 0)
            line.at(b * steps_per_bar + h, end - h, chord, vel=v, gate=gate)
    line.t = len(chords) * steps_per_bar
    return line

def ch(text):
    return text.split()

# ================================================================= TEMPLATES

def instrument_host():
    s = SongBuilder("Instrument Host", 100, seed=0x46574420)
    for key, name, sound, vol, pan in [("piano", "Piano", 0, 0.8, 0.0),
                                       ("ep", "Electric Piano", 4, 0.75, -0.1),
                                       ("strings", "Strings", 48, 0.65, 0.1),
                                       ("bass", "Bass", 33, 0.8, 0.0)]:
        s.track(key, name, sound, vol, pan)
    # No steps anywhere: every track is an instrument for a keyboard.
    s.section("live", "Live", 4, {})
    return s.build(loops=True, showsPlayKeyboard=True)

def sequencer():
    s = SongBuilder("Sequencer", 110, seed=0x46574421)
    s.track("drums", "Drums", DRUMS, 0.85)
    s.track("bass", "Bass", 38, 0.8)
    s.track("chords", "Chords", 4, 0.62, -0.2)
    s.track("lead", "Lead", 80, 0.5, 0.2)
    am = (9, "Minor")
    drum_pool = [{"midiNote": 36, "velocity": 105, "gateLength": 0.5},
                 {"midiNote": 38, "velocity": 100, "gateLength": 0.5},
                 {"midiNote": 42, "velocity": 80, "gateLength": 0.5},
                 {"midiNote": 42, "velocity": 50, "gateLength": 0.5}]
    drums = [S("play", chord=[1, 3]), S("play", 4), S("play", 3), S("play", 4),
             S("play", chord=[2, 3]), S("play", 4), S("play", 3), S("play", 4),
             S("play", chord=[1, 3]), S("play", 4), S("play", chord=[1, 3]), S("play", 4),
             S("play", chord=[2, 3]), S("play", 4), S("play", 3), S("play", 4)]
    drums = [dict(d, gate=0.5) for d in drums]
    s.section("a", "A", 4, {
        "drums": ("1/16", drum_pool, drums),
        "bass": ("1/8", pool_of(ch("A2 C3 D3 E3 G3"), 100, 0.8),
                 [S("play", 1), S("rep"), S("fwd", gate=0.6), S("pause"),
                  S("play", 1), S("fwd", 2), S("back"), S("pause")], am),
        "chords": ("1/4", pool_of(ch("A3 C4 E4 G4 B4 D5"), 70),
                   [S("play", chord=[1, 2, 3], gate=0.9), S("hold", 3),
                    S("fwd", gate=0.9), S("hold", 3)], am),
        "lead": ("1/8", pool_of(ch("A4 C5 D5 E5 G5 A5"), 85, 0.8),
                 [S("random"), S("hold"), S("fwd"), S("pause"),
                  S("random", prob=0.6), S("back"), S("rep"), S("pause")], am),
    })
    s.section("b", "B", 4, {
        "drums": ("1/16", [dict(n) for n in drum_pool],
                  [dict(d) for d in drums[:12]] + [dict(S("play", 2), gate=0.5, ratchets=2),
                                                    dict(S("play", 2), gate=0.5),
                                                    dict(S("play", 2), gate=0.5, ratchets=2),
                                                    dict(S("play", 4), gate=0.5)]),
        "bass": ("1/8", pool_of(ch("F2 G2 A2 C3 E3"), 100, 0.8),
                 [S("play", 1), S("rep"), S("fwd", gate=0.6), S("pause"),
                  S("play", 2), S("rep"), S("fwd", gate=0.6), S("pause")], am),
        "chords": ("1/4", pool_of(ch("F3 A3 C4 E4 G4 B4"), 70),
                   [S("play", chord=[1, 2, 3], gate=0.9), S("hold", 3),
                    S("fwd", gate=0.9), S("hold", 3)], am),
        "lead": ("1/8", pool_of(ch("A4 C5 D5 E5 G5 A5"), 85, 0.8),
                 [S("random"), S("fwd"), S("fwd"), S("hold"),
                  S("random", prob=0.6), S("back", 2), S("hold", 2)], am),
    })
    return s.build(loops=True)

# ================================================================= NIGHT MARKET
# Deep house in F minor, eight pads. Template "Pattern Pads", and a demo.

def night_market():
    s = SongBuilder("Night Market", 122, seed=0x46574430)
    s.track("drums", "Drums", DRUMS, 0.85, 0.0, swing=18, variation=8)
    s.track("bass", "Sub Bass", 38, 0.78, 0.0, swing=18)
    s.track("keys", "Keys", 4, 0.58, -0.22, swing=18, variation=6)
    s.track("pad", "Pad", 89, 0.45, 0.15)
    s.track("hook", "Hook", 11, 0.6, 0.25, swing=18, jitter=3)

    roots = ["F2", "Db2", "Eb2", "C2"]
    keys_chords = [ch("Ab3 C4 Eb4 G4"), ch("Ab3 C4 Eb4 F4"), ch("G3 Bb3 C4 F4"), ch("G3 Bb3 Eb4 G4")]
    # Open fifths under the keys' rootless voicings, so nothing rubs a semitone.
    pad_chords = [ch("F2 C3 F3 C4"), ch("Db2 Ab2 Db3 Ab3"), ch("Eb2 Bb2 Eb3 Bb3"), ch("C2 G2 C3 G3")]
    stab = [[2, 7, 10, 14]]

    def bass(variant=0, vel=100):
        line = Line(vel=vel, gate=0.8)
        for b, r in enumerate(roots):
            root = pitch(r)
            third = root + (3 if b in (0, 3) else 4)
            pat = [(0, 3, root, 0), (3, 1, root, -30), (6, 2, root + 12, -10),
                   (10, 2, root, -5), (13, 2, root + 7, -20)]
            if variant:
                pat = [(0, 2, root, 0), (2, 1, root + 12, -35), (4, 2, root, -15), (6, 2, root + 12, -10),
                       (10, 2, root, -5), (12, 1, root + 7, -25), (13, 2, third + 12 if b % 2 else third, -15)]
            for st, ln, n, dv in pat:
                line.at(b * 16 + st, ln, [n], vel=vel + dv)
        line.t = 64
        return line

    def keys(vel=82):
        return voiced(keys_chords, stab, vel=vel, gate=0.45, accents=[8, 0, 4, 0])

    def pad(vel=60):
        line = Line(vel=vel, gate=1.0)
        for b, c in enumerate(pad_chords):
            line.at(b, 1, c, vel=vel)
        line.t = 4
        return line

    def hook(vel=88):
        return Line(vel=vel, gate=0.85).add(
            "C5:2 r:1 Eb5:2 r:1 F5:3 r:1 Eb5:2 C5:4 "
            "Ab4:3 C5:3 Eb5:4 r:2 C5:4 "
            "Bb4:3 C5:3 Eb5:2 F5:4 Eb5:4 "
            "G4:3 Bb4:3 C5:6 r:4")

    groove = {36: "x...x...x...x...", 39: "....x.......x...", 46: "..o...o...o...o.",
              42: "-..--..--..--..-"}
    groove_b = {**groove, 51: "o.o.o.o.o.o.o.o."}

    def drums(grid, bars=1, levels=None):
        return Line().drums(grid, levels)

    s.section("intro", "Intro", 4, {
        "drums": ("1/16", Line().drums({42: "-.--" * 16, 70: "..o...o...o...o." * 3 + "..o...o...o.x.x."}), 64),
        "pad": ("1/1", pad(52)),
        "keys": ("1/16", Line().add("r:48") .at(48, 2, keys_chords[3], vel=60, gate=0.4)
                 .at(55, 2, keys_chords[3], vel=55, gate=0.4).at(58, 2, keys_chords[3], vel=62, gate=0.4)
                 .at(62, 2, keys_chords[3], vel=66, gate=0.4)),
    })
    s.section("grooveA", "Groove A", 4, {
        "drums": ("1/16", drums(groove), 16),
        "bass": ("1/16", bass()),
        "keys": ("1/16", keys()),
        "pad": ("1/1", pad(50)),
    })
    s.section("grooveB", "Groove B", 4, {
        "drums": ("1/16", drums(groove_b), 16),
        "bass": ("1/16", bass(variant=1)),
        "keys": ("1/16", keys(86)),
        "pad": ("1/1", pad(46)),
        "hook": ("1/16", hook()),
    })
    s.section("fill", "Fill", 1, {
        "drums": ("1/16", Line().drums({36: "x.......x.......", 38: "........-oox-ox.",
                                        50: "............x...", 48: ".............x..",
                                        45: "..............x.", 43: "...............x",
                                        42: "-.-.-.-........."})),
        "bass": ("1/16", Line(vel=100).add("C2:3 r:3 C3:2 r:2 C2:2 Bb1:2 G1:2")),
        "keys": ("1/16", Line(gate=0.4).at(2, 2, keys_chords[3], vel=84).at(7, 2, keys_chords[3], vel=80)),
        "pad": ("1/1", Line().at(0, 1, pad_chords[3], vel=50)),
    })
    s.section("break", "Break", 4, {
        "drums": ("1/16", Line().drums({70: "..o...o...o...o."}), 16),
        "bass": ("1/1", Line(vel=78, gate=1.0).add("F1:1 Db2:1 Eb2:1 C2:1")),
        "pad": ("1/1", pad(64)),
        "hook": ("1/16", hook(68)),
    })
    build_snare = ("x.......x......." + "x...x...x...x..." + "x.x.x.x.x.x.x.x." + "xxxxxxxxxxxxxxxx")
    build = Line()
    for i, c in enumerate(build_snare):
        if c == "x":
            build.at(i, 1, [38], vel=48 + i * 66 // 64, gate=0.5)
    for b in range(4):
        build.at(b * 16, 1, [36], vel=100, gate=0.5)
        for q in (4, 8, 12):
            build.at(b * 16 + q, 1, [36], vel=100, gate=0.5)
    build.at(63, 1, [49], vel=40, gate=0.5)
    build.t = 64
    rise = Line(gate=0.4)
    for i in range(32):
        chord = [pitch("Db2"), pitch("Ab2")] if i < 16 else [pitch("Eb2"), pitch("Bb2")]
        rise.at(i * 2, 2, chord, vel=70 + i)
    rise.t = 64
    s.section("build", "Build", 4, {
        "drums": ("1/16", build),
        "bass": ("1/16", rise),
        "keys": ("1/16", Line(gate=0.35).add(" ".join(
            f"{'Ab3+C4+F4' if i < 16 else 'Bb3+Eb4+G4'}:2@{60 + i * 2}" for i in range(32)))),
        "pad": ("1/2", Line(gate=1.0).at(0, 4, ch("F3 Ab3 C4 Eb4"), vel=50).at(4, 4, ch("G3 Bb3 Eb4 F4"), vel=68)),
    })
    drop_drums = Line().drums({36: "x...x...x...x...", 39: "....x.......x...", 46: "..x...x...x...x.",
                               42: "-..--..--..--..-", 51: "o.o.o.o.o.o.o.o.", 49: "X..............."})
    drop_drums2 = Line().drums(groove_b)
    for e in drop_drums2.events:
        drop_drums.events.append((e[0] + 16, *e[1:]))
    drop_drums.t = 32
    s.section("drop", "Drop", 4, {
        "drums": ("1/16", drop_drums, 32),
        "bass": ("1/16", bass(variant=1, vel=108)),
        "keys": ("1/16", keys(94)),
        "pad": ("1/1", pad(56)),
        "hook": ("1/16", hook(104)),
    })
    outro = Line()
    fade = Line().drums({36: "x...x...x...x...", 46: "..o...o...o...o.", 42: "-..--..--..--..-"})
    for b in range(4):
        for st, ln, n, v, g in fade.events:
            outro.events.append((b * 16 + st, ln, n, max(30, v - b * 18), g))
    outro.events.append((60, 1, [49], 60, 0.5))
    outro.t = 64
    s.section("outro", "Outro", 4, {
        "drums": ("1/16", outro),
        # Home to F minor in the last bar, under the keys' final chord.
        "pad": ("1/1", Line(gate=1.0).at(0, 1, pad_chords[0], vel=48).at(1, 1, pad_chords[1], vel=46)
                .at(2, 1, pad_chords[2], vel=44).at(3, 1, pad_chords[0], vel=42)),
        "keys": ("1/16", Line(gate=0.5).at(2, 2, keys_chords[0], vel=70).at(18, 2, keys_chords[1], vel=62)
                 .at(34, 2, keys_chords[2], vel=54).at(50, 14, keys_chords[0], vel=48, gate=1.0)),
    })
    return s.build(loops=True, opensInTriggerMode=True)

# ================================================================= CORNER CAFÉ
# Bossa nova in D. A head on flute, then two choruses for you on the Play keyboard.

def corner_cafe():
    s = SongBuilder("Corner Café", 132, seed=0x46574431)
    s.track("guitar", "Nylon Guitar", 24, 0.72, -0.25, spread=16, variation=10, jitter=4)
    s.track("bass", "Upright Bass", 32, 0.82, 0.05, variation=6)
    s.track("perc", "Brushes & Shaker", DRUMS, 0.62, 0.15, variation=14, jitter=4)
    s.track("flute", "Flute", 73, 0.66, 0.2, jitter=6, variation=6)

    V = {
        "Dmaj7": (ch("D3 A3 C#4 F#4"), "D2", "A2"), "D7": (ch("D3 A3 C4 F#4"), "D2", "A2"),
        "Em7": (ch("E3 B3 D4 G4"), "E2", "B2"), "A7": (ch("G3 A3 C#4 E4"), "A2", "E2"), "D6": (ch("D3 A3 B3 F#4"), "D2", "A2"),
        "F#m7": (ch("F#3 A3 C#4 E4"), "F#2", "C#3"), "B7": (ch("A3 C4 D#4 F#4"), "B2", "F#2"),
        "Gmaj7": (ch("G3 B3 D4 F#4"), "G2", "D3"), "Gm6": (ch("G3 Bb3 D4 E4"), "G2", "D3"),
    }
    a_bars = ["Dmaj7", "Dmaj7", "Em7", "A7", "F#m7", "B7", "Em7", "A7"]
    # D6 where the flute sits on D: a major 7th under it would rub.
    b_bars = ["D6", "D7", "Gmaj7", "Gm6", "F#m7", "B7", ("Em7", "A7"), "D6"]
    intro_bars = ["Em7", "A7", "Em7", "A7"]

    rhythm = [[0, 3, 6, 10, 13], [2, 6, 9, 12]]   # the two-bar batida, in 16ths

    def guitar(bars, vel=70):
        line = Line(vel=vel, gate=0.55)
        for b, chord in enumerate(bars):
            hits = rhythm[b % 2]
            for i, h in enumerate(hits):
                end = hits[i + 1] if i + 1 < len(hits) else 16
                name = chord if isinstance(chord, str) else (chord[0] if h < 8 else chord[1])
                line.at(b * 16 + h, end - h, V[name][0], vel=vel + (8 if i == 0 else 0))
        line.t = len(bars) * 16
        return line

    def bass(bars, vel=88):
        line = Line(vel=vel, gate=0.85)
        for b, chord in enumerate(bars):
            if isinstance(chord, tuple):
                (r1, f1), (r2, f2) = V[chord[0]][1:], V[chord[1]][1:]
                pat = [(0, 6, r1), (6, 2, f1), (8, 6, r2), (14, 2, f2)]
            else:
                r, f = V[chord][1:]
                pat = [(0, 6, r), (6, 2, r), (8, 6, f), (14, 2, f)]
            for st, ln, n in pat:
                line.at(b * 16 + st, ln, [n], vel=vel - (14 if ln == 2 else 0))
        line.t = len(bars) * 16
        return line

    perc_grid = {37: "x..x..x.........", 36: "o......-o......-", 69: "-o-o-o-o-o-o-o-o"}
    perc_grid2 = {37: "....x.....x.....", 36: "o......-o......-", 69: "-o-o-o-o-o-o-o-o"}

    def perc(bars=2, levels=None):
        line = Line()
        a = Line().drums(perc_grid, levels)
        b = Line().drums(perc_grid2, levels)
        for e in a.events:
            line.events.append(e)
        for e in b.events:
            line.events.append((e[0] + 16, *e[1:]))
        line.t = 32
        return line

    head_a = Line(vel=84, gate=0.92).add(
        "r:1 A4:1 F#5:4@90 E5:2 "
        "C#5:6 r:2 "
        "r:1 B4:1 G5:4@90 F#5:2 "
        "E5:6 r:2 "
        "r:1 C#5:1 A5:4@94 F#5:2 "
        "D#5:6 r:2 "
        "r:1 E5:1 G5:2 B5:2@92 A5:2 "
        "G5:4 E5:2 C#5:2")
    head_b = Line(vel=84, gate=0.92).add(
        "D5:4 F#5:2 A5:2@92 "
        "C5:6 r:2 "
        "B4:2 D5:2 F#5:4@90 "
        "E5:4 Bb4:2 D5:2 "
        "C#5:4 E5:2 A5:2@94 "
        "A5:4 F#5:2 D#5:2 "
        "E5:4 C#5:4 "
        "D5:6 r:2")
    s.section("intro", "Intro", 4, {
        "guitar": ("1/16", guitar(intro_bars, 66)),
        "bass": ("1/16", bass(intro_bars, 80)),
        "perc": ("1/16", Line().drums({69: "-o-o-o-o-o-o-o-o"}), 16),
    })
    s.section("headA", "Head A", 8, {
        "guitar": ("1/16", guitar(a_bars)), "bass": ("1/16", bass(a_bars)),
        "perc": ("1/16", perc(), 32), "flute": ("1/8", head_a),
    })
    s.section("headB", "Head B", 8, {
        "guitar": ("1/16", guitar(b_bars)), "bass": ("1/16", bass(b_bars)),
        "perc": ("1/16", perc(), 32), "flute": ("1/8", head_b),
    })
    s.section("soloA", "Solo A", 8, {
        "guitar": ("1/16", guitar(a_bars, 74)), "bass": ("1/16", bass(a_bars, 92)),
        "perc": ("1/16", perc(), 32),
    })
    s.section("soloB", "Solo B", 8, {
        "guitar": ("1/16", guitar(b_bars, 74)), "bass": ("1/16", bass(b_bars, 92)),
        "perc": ("1/16", perc(), 32),
    })
    ending = ["Em7", "A7", "Dmaj7", "Dmaj7"]
    end_guitar = guitar(ending[:2], 68)
    end_guitar.at(32, 32, V["Dmaj7"][0], vel=62, gate=1.0)
    end_guitar.t = 64
    s.section("ending", "Ending", 4, {
        "guitar": ("1/16", end_guitar),
        "bass": ("1/16", bass(ending[:2], 84).at(32, 32, ["D2"], vel=80, gate=1.0)),
        "perc": ("1/16", Line().drums({37: "x..x..x.........""....x.....x....." "x...............",
                                       69: "-o-o-o-o-o-o-o-o" * 2})),
        "flute": ("1/8", Line(vel=78, gate=0.95).add("B4:4 D5:4 C#5:4 E5:4 F#5:16")),
    })
    head = s.song_part("head", "Head", ["headA", "headB"])
    solo = s.song_part("solo", "Your Solo", ["soloA", "soloB"])
    s.arrange(["intro", head, solo, solo, head, "ending"])
    song = s.build(loops=False, showsPlayKeyboard=True)
    song["performance"] = {"id": uid("Corner Café", "performance"), "name": "Your Solo",
                           "mixer": {"volume": 0.72, "pan": 0.0, "isMuted": False, "isSoloed": False},
                           "builtInSound": 11}
    return song

# ================================================================= LIGHTHOUSE
# A ballad in D that grows from one piano to the full ensemble and back.

def lighthouse():
    s = SongBuilder("Lighthouse", 70, seed=0x46574432)
    s.track("piano", "Piano", 0, 0.8, -0.1, variation=8)
    s.track("oboe", "Oboe", 68, 0.62, 0.2, jitter=6)
    s.track("horn", "Horn", 60, 0.68, -0.15, jitter=5)
    s.track("strings", "Strings", 48, 0.6, 0.15)
    s.track("cello", "Cello", 42, 0.7, -0.05)
    s.track("timp", "Timpani", 47, 0.7, 0.0)

    PV = {  # piano broken-chord voicings, low to high
        "D": "D2 A2 D3 F#3 A3", "D/F#": "F#2 D3 A3 D4 F#4", "G": "G2 D3 G3 B3 D4",
        "A": "A2 E3 A3 C#4 E4", "Asus4": "A2 E3 A3 D4 E4", "Bm": "B2 F#3 B3 D4 F#4",
        "Bm7": "B2 F#3 A3 D4 F#4", "Gmaj7": "G2 D3 F#3 B3 D4", "Em7": "E2 B2 E3 G3 D4",
        "F#m7": "F#2 C#3 E3 A3 C#4",
    }
    SV = {  # strings
        "D": "F#3 A3 D4 F#4", "D/F#": "F#3 A3 D4 F#4", "G": "G3 B3 D4 G4", "A": "E3 A3 C#4 E4",
        "Asus4": "E3 A3 D4 E4", "Bm": "F#3 B3 D4 F#4", "Bm7": "F#3 A3 D4 F#4",
        "Em7": "G3 B3 D4 E4", "F#m7": "F#3 A3 C#4 E4", "Gmaj7": "F#3 B3 D4 G4",
    }
    CB = {"D": "D2", "D/F#": "F#2", "G": "G2", "A": "A2", "Asus4": "A2", "Bm": "B2", "Bm7": "B2",
          "Gmaj7": "G2", "Em7": "E2", "F#m7": "F#2"}

    def piano(bars, vel, ramp=0, last_hold=False):
        line = Line(vel=vel, gate=1.0)
        order = [0, 1, 2, 3, 4, 3, 2, 1]
        for b, chord in enumerate(bars):
            v = ch(PV[chord])
            bv = vel + ramp * b
            if last_hold and b == len(bars) - 1:
                line.at(b * 8, 8, v, vel=bv)
                continue
            for i, idx in enumerate(order):
                line.at(b * 8 + i, 1, [v[idx]], vel=bv + (8 if i == 0 else 0) - (4 if i % 2 else 0))
        line.t = len(bars) * 8
        return line

    def strings(bars, vel, ramp=0):
        line = Line(vel=vel, gate=1.0)
        for b, chord in enumerate(bars):
            line.at(b, 1, ch(SV[chord]), vel=vel + ramp * b)
        line.t = len(bars)
        return line

    def cello(bars, vel):
        line = Line(vel=vel, gate=1.0)
        for b, chord in enumerate(bars):
            line.at(b, 1, [CB[chord]], vel=vel)
        line.t = len(bars)
        return line

    intro = ["D", "Bm7", "Gmaj7", "Asus4"]
    verse_a = ["D", "D/F#", "G", "A"]
    verse_b = ["Bm", "G", "Em7", "A"]
    chorus_a = ["G", "D/F#", "Em7", "D"]
    chorus_b = ["G", "A", "Bm7", "A"]
    bridge = ["Em7", "F#m7", "G", "A"]
    outro = ["D", "Bm7", "G", "D"]

    oboe_a = "r:2 F#4:2 A4:2 B4:2 A4:4 F#4:2 E4:2 G4:2 B4:2 D5:4 C#5:6 r:2"
    oboe_b = "B4:2 D5:2 F#5:4 E5:2 D5:2 B4:4 G4:2 A4:2 B4:2 D5:2 E5:4 C#5:4"
    horn_a = "B4:6 A4:2 A4:4 F#4:2 D4:2 G4:6 F#4:2 F#4:4 E4:2 D4:2"
    horn_b = "B4:4 D5:4 C#5:4 E5:4 D5:6 B4:2 C#5:4 A4:4"

    s.section("intro", "Intro", 4, {"piano": ("1/8", piano(intro, 46))})
    s.section("verseA", "Verse a", 4, {
        "piano": ("1/8", piano(verse_a, 54)), "oboe": ("1/8", Line(vel=72, gate=0.95).add(oboe_a)),
        "cello": ("1/1", cello(verse_a, 58)),
    })
    s.section("verseB", "Verse b", 4, {
        "piano": ("1/8", piano(verse_b, 56)), "oboe": ("1/8", Line(vel=76, gate=0.95).add(oboe_b)),
        "cello": ("1/1", cello(verse_b, 60)),
    })
    s.section("chorusA", "Chorus a", 4, {
        "piano": ("1/8", piano(chorus_a, 64)), "horn": ("1/8", Line(vel=80, gate=0.95).add(horn_a)),
        "strings": ("1/1", strings(chorus_a, 62)), "cello": ("1/1", cello(chorus_a, 70)),
    })
    s.section("chorusB", "Chorus b", 4, {
        "piano": ("1/8", piano(chorus_b, 66)), "horn": ("1/8", Line(vel=84, gate=0.95).add(horn_b)),
        "strings": ("1/1", strings(chorus_b, 66)), "cello": ("1/1", cello(chorus_b, 72)),
    })
    timp_roll = Line(gate=1.0)
    for q in range(8):   # the last two bars: a roll on A that swells
        timp_roll.at(8 + q, 1, ["A2"], vel=50 + q * 9)
    timp_roll.t = 16
    timp_steps = steps_from_events(timp_roll.events, 16)
    for st in timp_steps[1]:
        if st["type"] == "Play":
            st["ratchets"] = 4
    s.section("bridge", "Bridge", 4, {
        "piano": ("1/8", piano(bridge, 60, ramp=8)),
        "strings": ("1/2", Line(gate=1.0).add(" ".join(
            f"{'+'.join(ch(SV[c]))}:1@{56 + (i * 2 + h) * 7}" for i, c in enumerate(bridge) for h in range(2)))),
        "cello": ("1/2", Line(gate=1.0).add(" ".join(
            f"{CB[c]}:1@{60 + (i * 2 + h) * 6}" for i, c in enumerate(bridge) for h in range(2)))),
        "timp": ("1/4", timp_steps[0], timp_steps[1]),
    })
    s.section("bigA", "Final Chorus a", 4, {
        "piano": ("1/8", piano(chorus_a, 84)),
        "horn": ("1/8", Line(vel=100, gate=0.95).add(horn_a)),
        "oboe": ("1/8", Line(vel=82, gate=0.95).add(horn_a, transpose=12)),
        "strings": ("1/1", strings(chorus_a, 92)),
        "cello": ("1/1", cello(chorus_a, 92)),
        "timp": ("1/4", Line(vel=100, gate=1.0).add("D2:4@108 r:4 E2:4 D2:4@96")),
    })
    s.section("bigB", "Final Chorus b", 4, {
        "piano": ("1/8", piano(chorus_b, 88)),
        "horn": ("1/8", Line(vel=104, gate=0.95).add(horn_b)),
        "oboe": ("1/8", Line(vel=86, gate=0.95).add(horn_b, transpose=12)),
        "strings": ("1/1", strings(chorus_b, 96)),
        "cello": ("1/1", cello(chorus_b, 96)),
        "timp": ("1/4", Line(vel=100, gate=1.0).add("G2:4@100 A2:4@96 B2:4@92 A2:2@90 A2:1@100 A2:1@112")),
    })
    s.section("outro", "Outro", 4, {
        "piano": ("1/8", piano(outro, 50, ramp=-3, last_hold=True)),
        "strings": ("1/1", strings(outro, 48, ramp=-4)),
        "cello": ("1/1", cello(outro, 52)),
        "oboe": ("1/8", Line(vel=66, gate=0.95).add("r:8 F#5:6 E5:2 D5:16")),
    })
    verse = s.song_part("verse", "Verse", ["verseA", "verseB"])
    chorus = s.song_part("chorus", "Chorus", ["chorusA", "chorusB"])
    final = s.song_part("final", "Final Chorus", ["bigA", "bigB"])
    s.arrange(["intro", verse, chorus, verse, chorus, "bridge", final, "outro"])
    return s.build(loops=False)

# ================================================================= SUNDAY STRUT
# Funk in E: swing, accent, variation, push and pull and chord roll at work.

def sunday_strut():
    s = SongBuilder("Sunday Strut", 98, seed=0x46574433)
    feel = dict(swing=24, accent=12, variation=12, jitter=4)
    s.track("drums", "Drums", DRUMS, 0.85, 0.0, **feel)
    s.track("bass", "Bass", 33, 0.82, 0.0, swing=24, variation=10, jitter=3)
    s.track("clav", "Clavinet", 7, 0.56, -0.3, swing=24, accent=10, variation=12)
    s.track("rhodes", "Rhodes", 4, 0.55, 0.25, spread=30, variation=8)
    s.track("horns", "Horns", 61, 0.62, 0.1, swing=24, jitter=5, variation=8)

    groove = {36: "x......x..x.....", 38: "....X.-..-..X..-", 42: "xoxoxoxoxoxoxo.o", 46: "..............o."}
    groove2 = {36: "x......x..x..x..", 38: "....X.-..-..X.-o", 42: "xoxoxoxoxoxoxo.o", 46: "..............x."}

    def two_bars(a, b):
        line = Line().drums(a)
        for e in Line().drums(b).events:
            line.events.append((e[0] + 16, *e[1:]))
        line.t = 32
        return line

    bass_riff = Line(vel=100, gate=0.75).add(
        "E2:3@108 E2:1@55 E3:1@96 r:1 D3:2@90 B2:2@92 r:1 G2:1@80 A2:2@88 B2:2@85 "
        "E2:3@108 E2:1@55 E3:1@96 r:1 D3:1@86 E3:1@98~0.4 B2:2@90 D3:2@88 E3:1@94 D3:1@82 B2:1@84 G2:1@78")
    clav_chord = ch("G#3 D4 F#4")
    clav = Line(gate=0.32)
    for i, h in enumerate([2, 3, 5, 7, 10, 12, 13, 15]):
        clav.at(h, 1, clav_chord, vel=92 if i % 2 == 0 else 70)
    for i, h in enumerate([0, 2, 3, 6, 8, 10, 11, 14]):
        clav.at(16 + h, 1, clav_chord, vel=88 if i % 2 == 0 else 68)
    clav.t = 32
    rhodes = Line(gate=0.9).at(0, 6, ch("G#3 D4 F#4 B4"), vel=72).at(10, 6, ch("G#3 D4 F#4 B4"), vel=64)
    rhodes.t = 32
    horn_riff = Line(vel=96, gate=0.6).add(
        "r:10 B4:1@88 D5:1@92 E5:2@110 r:2 "
        "r:2 G5:1@104 E5:2@96 r:1 D5:1@86 E5:1@108~0.4 r:8")

    s.section("intro", "Intro", 2, {"drums": ("1/16", two_bars(groove, groove2))})
    s.section("groove", "Groove", 8, {
        "drums": ("1/16", two_bars(groove, groove2), 32), "bass": ("1/16", bass_riff, 32),
        "clav": ("1/16", clav, 32), "rhodes": ("1/16", rhodes, 32),
    })
    s.section("horns", "Horns In", 8, {
        "drums": ("1/16", two_bars(groove, groove2), 32), "bass": ("1/16", bass_riff, 32),
        "clav": ("1/16", clav, 32), "rhodes": ("1/16", rhodes, 32), "horns": ("1/16", horn_riff, 32),
    })
    bridge_chords = [("A9", "A2", ch("C#4 G4 B4")), ("A9", "A2", ch("C#4 G4 B4")),
                     ("C9", "C3", ch("E4 Bb4 D5")), ("B7#9", "B2", ch("D#4 A4 D5"))]
    bb, bc, br = Line(vel=100, gate=0.75), Line(gate=0.32), Line(gate=0.95)
    for b, (_, root, chord) in enumerate(bridge_chords):
        r = pitch(root)
        for st, ln, n, v in [(0, 3, r, 106), (3, 1, r, 55), (4, 1, r + 12, 94), (6, 2, r + 10, 86),
                             (8, 2, r + 7, 90), (11, 1, r, 70), (12, 2, r + 12, 92), (14, 2, r + 10, 84)]:
            bb.at(b * 16 + st, ln, [n], vel=v)
        for i, h in enumerate([2, 3, 6, 8, 10, 13]):
            bc.at(b * 16 + h, 1, chord, vel=88 if i % 2 == 0 else 66)
        br.at(b * 16, 8, [pitch(root) + 12] + [pitch(n) for n in chord], vel=76)
    bb.t = bc.t = br.t = 64
    bh = Line(vel=100, gate=0.55).add(
        "C#5:2@104 r:14 C#5:2@100 r:6 E5:1@96 G5:2@108 r:5 "
        "E5:2@104 r:6 G5:1@96 Bb5:2@110 r:5 "
        "B4:1@80 C#5:1@84 D5:1@88 D#5:1@92 E5:1@96 F#5:1@100 G5:1@104 A5:1@108 B5:4@116 r:4")
    s.section("bridge", "Bridge", 4, {
        "drums": ("1/16", two_bars(groove2, {36: "x.....x...x.x...", 38: "....X.....X.XXXX",
                                             42: "xoxoxoxoxoxo....", 49: "X..............."}), 32),
        "bass": ("1/16", bb), "clav": ("1/16", bc), "rhodes": ("1/16", br), "horns": ("1/16", bh),
    })
    s.section("breakdown", "Breakdown", 4, {
        "drums": ("1/16", Line().drums({36: "x......x..x.....", 38: "....x.......x...", 42: "x.o.x.o.x.o.x.o."}), 16),
        "bass": ("1/16", Line(vel=96, gate=0.7).add(
            "E2:2@104 r:1 E2:1@50 G2:1@84 G#2:1@90 A2:2@94 r:2 B2:1@88 D3:1@92 E3:2@100 D3:1@80 B2:1@76 "
            "E2:2@104 r:2 E3:1@96 r:1 D3:2@88 r:2 B2:1@84 A2:1@80 G2:1@78 E2:3@100 "
            "E2:2@104 r:1 E2:1@50 G2:1@84 G#2:1@90 A2:2@94 r:2 B2:1@88 D3:1@92 E3:2@100 D3:1@80 B2:1@76 "
            "E3:1@100 D3:1@90 B2:1@86 A2:1@82 G2:1@80 E2:1@76 D2:1@74 E2:9@104")),
        "rhodes": ("1/1", Line(vel=58, gate=1.0).at(0, 2, ch("G#3 D4 F#4 B4")).at(2, 2, ch("A3 D4 G4 B4"), vel=54)),
    })
    s.section("out", "Out", 8, {
        "drums": ("1/16", two_bars(groove, groove2), 32), "bass": ("1/16", bass_riff, 32),
        "clav": ("1/16", clav, 32), "rhodes": ("1/16", rhodes, 32), "horns": ("1/16", horn_riff, 32),
    })
    hit = {"drums": ("1/16", Line().drums({36: "X...............", 49: "X...............", 38: "X..............."})),
           "bass": ("1/16", Line(gate=1.0).at(0, 12, ["E2"], vel=110)),
           "clav": ("1/16", Line(gate=0.4).at(0, 2, clav_chord, vel=100)),
           "rhodes": ("1/16", Line(gate=1.0).at(0, 16, ch("G#3 D4 F#4 B4"), vel=84)),
           "horns": ("1/16", Line(gate=1.0).at(0, 12, ch("G#4 D5 F#5"), vel=112))}
    s.section("end", "Final Hit", 1, hit)
    return s.build(loops=False)

# ================================================================= GLASSHOUSE
# Generative ambient in D Lydian. Random, Back, Repeat, probability and loops of
# different lengths, so it keeps changing. Leave it running.

def glasshouse():
    s = SongBuilder("Glasshouse", 66, seed=0x46574434)
    s.track("celesta", "Celesta", 8, 0.62, 0.2, variation=10, jitter=8)
    s.track("harp", "Harp", 46, 0.55, -0.25, variation=12, jitter=6)
    s.track("pad", "Halo Pad", 94, 0.5, 0.0)
    s.track("drone", "Low Strings", 42, 0.55, -0.05)
    s.track("bells", "Vibraphone", 11, 0.5, 0.3, jitter=10)
    lydian = (2, "Lydian")

    def celesta(notes, vels, gentle=False):
        pool = [{"midiNote": pitch(n), "velocity": v, "gateLength": 0.85} for n, v in zip(notes, vels)]
        steps = [S("random", prob=0.85), S("hold"), S("fwd", prob=0.7), S("fwd", 2),
                 S("pause", 2), S("back"), S("rep", prob=0.6), S("random", prob=0.5),
                 S("hold", 2), S("back", 2, prob=0.7), S("pause")]
        if gentle:
            steps = [S("random", prob=0.7), S("hold", 2), S("fwd", prob=0.5), S("pause", 3),
                     S("back", prob=0.6), S("hold"), S("random", prob=0.4), S("pause", 4)]
        return pool, steps

    def harp(notes, vel=70, busy=False):
        pool = pool_of(notes, vel, 0.9)
        steps = [S("play", 1), S("fwd"), S("fwd"), S("fwd", prob=0.75), S("fwd"),
                 S("back", prob=0.6), S("fwd", 2), S("pause", 3)]
        if busy:
            steps = [S("play", 1), S("fwd"), S("fwd"), S("fwd"), S("fwd", prob=0.85), S("back"),
                     S("fwd", 2), S("rep", prob=0.5), S("back", 3), S("pause")]
        return pool, steps

    def pad(chords, bars_each, vel=58):
        line = Line(vel=vel, gate=1.0)
        for i, c in enumerate(chords):
            line.at(i * bars_each, bars_each, ch(c), vel=vel)
        line.t = len(chords) * bars_each
        return line

    def bells(notes, vel=62):
        return (pool_of(notes, vel, 1.0),
                [S("pause", 3), S("random", prob=0.55), S("hold", 2), S("random", prob=0.35), S("hold")])

    D_LYD = ["D4", "E4", "F#4", "G#4", "A4", "B4", "C#5", "D5", "E5", "F#5"]
    s.section("dawn", "Dawn", 8, {
        "celesta": ("1/8", *celesta(D_LYD, [52, 48, 56, 50, 54, 48, 58, 52, 50, 56], gentle=True), lydian),
        "pad": ("1/1", pad(["D3 A3 E4 F#4", "D3 G#3 B3 E4"], 4, 50)),
        "drone": ("1/2", pool_of(["D2", "D3"], 54, 1.0), [S("play", 1), S("hold", 3), S("play", 2), S("hold", 3)], lydian),
    })
    s.section("bloom", "Bloom", 8, {
        "celesta": ("1/8", *celesta(D_LYD, [62, 56, 66, 58, 64, 56, 70, 62, 58, 66]), lydian),
        "harp": ("1/16", *harp(["D3", "A3", "E4", "F#4", "A4", "B4", "D5"], 62), lydian),
        "pad": ("1/1", pad(["D3 A3 E4 F#4", "D3 G#3 B3 E4"] * 2, 2, 56)),
        "drone": ("1/2", pool_of(["D2", "D3"], 60, 1.0), [S("play", 1), S("hold", 3), S("play", 2), S("hold", 3)], lydian),
        "bells": ("1/4", *bells(["A4", "C#5", "E5", "F#5", "G#5"]), lydian),
    })
    s.section("canopy", "Canopy", 8, {
        "celesta": ("1/8", *celesta(["F#4", "G#4", "A4", "B4", "C#5", "D5", "E5", "F#5", "A5", "B5"],
                                     [70, 62, 74, 66, 80, 68, 76, 72, 66, 70]), lydian),
        "harp": ("1/16", *harp(["B2", "F#3", "A3", "C#4", "E4", "F#4", "A4", "C#5"], 72, busy=True), lydian),
        "pad": ("1/1", pad(["B2 F#3 A3 C#4 D4", "A2 E3 G#3 C#4", "F#2 C#3 E3 A3", "D3 G#3 B3 E4"], 2, 62)),
        "drone": ("1/2", pool_of(["B1", "A1", "F#1", "D2"], 62, 1.0),
                  [S("play", 1), S("hold", 3), S("fwd"), S("hold", 3)], lydian),
        "bells": ("1/4", *bells(["F#5", "A5", "C#6", "E5", "B5"], 66), lydian),
    })
    s.section("dusk", "Dusk", 8, {
        "celesta": ("1/8", *celesta(D_LYD, [50, 46, 54, 48, 52, 46, 56, 50, 48, 52], gentle=True), lydian),
        "harp": ("1/16", pool_of(["D3", "A3", "C#4", "E4", "F#4", "A4"], 54, 0.9),
                 [S("play", 1), S("fwd"), S("fwd"), S("fwd", prob=0.6), S("pause", 12)], lydian),
        "pad": ("1/1", pad(["D3 A3 C#4 F#4"], 8, 52)),
        "drone": ("1/1", pool_of(["D2"], 52, 1.0), [S("play", 1), S("hold", 7)], lydian),
        "bells": ("1/4", pool_of(["A4", "E5", "F#5"], 54, 1.0),
                  [S("pause", 6), S("random", prob=0.4), S("hold", 5)], lydian),
    })
    return s.build(loops=True)

# ================================================================= write

SONGS = {
    "Template-InstrumentHost": instrument_host,
    "Template-Sequencer": sequencer,
    "Example-NightMarket": night_market,
    "Example-CornerCafe": corner_cafe,
    "Example-Lighthouse": lighthouse,
    "Example-SundayStrut": sunday_strut,
    "Example-Glasshouse": glasshouse,
}

if __name__ == "__main__":
    for name, make in SONGS.items():
        song = make()
        path = os.path.join(OUT, name + ".json")
        with open(path, "w") as f:
            json.dump(song, f, indent=1, ensure_ascii=False)
        notes = sum(len(p["steps"]) for s in song["sections"] for p in s["parts"])
        print(f"{name}: {len(song['tracks'])} tracks, {len(song['sections'])} sections, {notes} steps")
