#!/usr/bin/env python3
"""Writes the MIDI loops the app carries (FwdSequencer/Resources/Loop-*.mid).

They do two jobs. Copied into Files > FWD Sequencer > MIDI Loops, they are something to
try Import MIDI with on an iPad that has no MIDI files of its own. And the example song
"Malecon" is built from the six "Malecon" files by the app's own importer, one file to
a section (Tests/FwdSequencerCoreTests/LoopExampleTests.swift builds it and checks the
song in the app still matches), so it shows exactly what Import MIDI gives.

Written here, not taken from a loop pack, so there is nobody's licence to honour.

A salsa in A minor, in the "sixteenth" way of writing it: one 4/4 bar holds one whole
2-3 clave and one chord. Everything sits exactly on sixteenths so it imports cleanly at
a step size of 1/16; the life is in the velocities, which the importer keeps note by
note (ghosted conga strokes at 34 to 38 against slaps at 104).

Run from the repository root:  python3 Tools/make_midi_loops.py
"""
import os
import struct

TPQ = 480
STEP = TPQ // 4            # a sixteenth
BAR = 16                   # sixteenths in a bar
TEMPO = 100

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "FwdSequencer", "Resources")

# General MIDI percussion
KICK, STICK, CRASH, CRASH2 = 36, 37, 49, 57
COWBELL, CLAVE = 56, 75
CONGA_MUTE, CONGA_OPEN, CONGA_LOW = 62, 63, 64
TIMBALE_HI, TIMBALE_LO = 65, 66
GUIRO_SHORT, GUIRO_LONG = 73, 74

# name: (bass root, bass fifth, piano octave pair, piano dyad, brass pair)
CHORDS = {
    "Am": (33, 40, (57, 69), (60, 64), (69, 72)),
    "Dm": (38, 45, (57, 69), (62, 65), (74, 77)),
    "E7": (40, 35, (56, 68), (62, 64), (71, 74)),
}
CYCLE = ["Am", "Dm", "E7", "Am"]


class Part:
    """One track of a file: (start, pitch, velocity, length), in sixteenths."""

    def __init__(self, name, program=None):
        self.name, self.program, self.notes = name, program, []

    def add(self, bar, step, pitch, velocity, length=1):
        pitches = pitch if isinstance(pitch, (tuple, list)) else (pitch,)
        for p in pitches:
            self.notes.append((bar * BAR + step, p, velocity, length))


def vlq(value):
    out = [value & 0x7F]
    value >>= 7
    while value:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    return bytes(reversed(out))


def chunk(events):
    """events: (tick, order, bytes). Releases sort before strikes on the same tick."""
    data, last = b"", 0
    for tick, _, payload in sorted(events, key=lambda e: (e[0], e[1])):
        data += vlq(tick - last) + payload
        last = tick
    data += vlq(0) + b"\xFF\x2F\x00"
    return b"MTrk" + struct.pack(">I", len(data)) + data


def meta(kind, payload):
    return bytes([0xFF, kind]) + vlq(len(payload)) + payload


def write(filename, title, bars, parts):
    conductor = [
        (0, 0, meta(0x03, title.encode())),
        (0, 0, meta(0x58, bytes([4, 2, 24, 8]))),
        (0, 0, meta(0x51, struct.pack(">I", round(60_000_000 / TEMPO))[1:])),
        # Holds the file to its full length, so "fit length" gives whole bars.
        (bars * BAR * STEP, 9, meta(0x06, b"End")),
    ]
    tracks = [chunk(conductor)]
    melodic = 0
    for part in parts:
        if not part.notes:
            continue
        if part.program is None:
            channel = 9
        else:
            channel = melodic
            melodic += 1
        events = [(0, 0, meta(0x03, part.name.encode()))]
        if part.program is not None:
            events.append((0, 0, bytes([0xC0 | channel, part.program])))
        for start, pitch, velocity, length in part.notes:
            events.append((start * STEP, 2, bytes([0x90 | channel, pitch, velocity])))
            events.append(((start + length) * STEP, 1, bytes([0x80 | channel, pitch, 0])))
        tracks.append(chunk(events))
    data = b"MThd" + struct.pack(">IHHH", 6, 1, len(tracks), TPQ) + b"".join(tracks)
    with open(os.path.join(OUT, filename), "wb") as f:
        f.write(data)
    print(f"{filename}: {bars} bars, {len(tracks) - 1} parts, {len(data)} bytes")


# ---------------------------------------------------------------------------- patterns

def kick(part, bar, lift=0):
    part.add(bar, 6, KICK, 100 + lift)
    part.add(bar, 14, KICK, 92 + lift)


def cascara(part, bar):
    """The timbale-shell pattern of a verse, on the side stick."""
    for step, velocity in [(0, 100), (2, 70), (4, 95), (5, 60), (7, 90),
                           (8, 95), (10, 70), (11, 92), (13, 70), (15, 88)]:
        part.add(bar, step, STICK, velocity)


def bell(part, bar):
    """The cowbell of a chorus: the low stroke on the beat, two lighter after it."""
    for beat in range(4):
        part.add(bar, beat * 4, COWBELL, 112)
        part.add(bar, beat * 4 + 2, COWBELL, 68)
        part.add(bar, beat * 4 + 3, COWBELL, 80)


def tumbao(part, bar, lift=0):
    """Congas: ghosted heel and toe strokes, a slap, and the open tones answering."""
    first = [(0, CONGA_MUTE, 38), (1, CONGA_MUTE, 34), (2, CONGA_MUTE, 104), (3, CONGA_MUTE, 36),
             (4, CONGA_MUTE, 38), (5, CONGA_MUTE, 34), (6, CONGA_OPEN, 96), (7, CONGA_OPEN, 90)]
    second = [(8, CONGA_MUTE, 38), (9, CONGA_MUTE, 34), (10, CONGA_MUTE, 104), (11, CONGA_MUTE, 36),
              (12, CONGA_MUTE, 38), (13, CONGA_LOW, 92), (14, CONGA_LOW, 98), (15, CONGA_OPEN, 92)]
    for step, pitch, velocity in first + second:
        part.add(bar, step, pitch, min(127, velocity + (lift if velocity > 60 else 0)))


def clave(part, bar, velocity=96):
    for step in (2, 4, 8, 11, 14):          # 2-3 son clave
        part.add(bar, step, CLAVE, velocity)


def guiro(part, bar):
    for beat in range(4):
        part.add(bar, beat * 4, GUIRO_LONG, 70, 2)
        part.add(bar, beat * 4 + 2, GUIRO_SHORT, 56)
        part.add(bar, beat * 4 + 3, GUIRO_SHORT, 56)


def bass_tumbao(part, bar, chord, following, lift=0, last=False):
    """The anticipated bass: the fifth, the root, and the NEXT bar's root arriving early."""
    root, fifth = CHORDS[chord][0], CHORDS[chord][1]
    part.add(bar, 3, fifth, 88 + lift, 3)
    part.add(bar, 6, root, 100 + lift, 5)
    part.add(bar, 11, fifth, 86 + lift, 3)
    part.add(bar, 14, CHORDS[following][0], 102 + lift, 2 if last else 5)


def montuno(part, bar, chord, following, lift=0):
    """Piano: octaves against a dyad, off the beat from the second half of the bar."""
    octave, dyad = CHORDS[chord][2], CHORDS[chord][3]
    part.add(bar, 0, octave, 96 + lift)
    for step in (3, 7, 11):
        part.add(bar, step, octave, 82 + lift)
    for step in (2, 5, 9, 13):
        part.add(bar, step, dyad, 74 + lift)
    part.add(bar, 15, CHORDS[following][3], 100 + lift)     # the next chord, a sixteenth early


def brass_riff(part, bar, chord, index):
    pair = CHORDS[chord][4]
    if index % 4 == 0 or index % 4 == 2:
        part.add(bar, 0, pair, 112)
        part.add(bar, 3, pair, 96)
        part.add(bar, 6, (pair[1], pair[1] + 4) if chord == "Am" else pair, 108, 4)
    elif index % 4 == 1:
        part.add(bar, 10, pair, 100)
        part.add(bar, 12, pair, 110, 3)
    else:
        for step, pitch, velocity in [(8, 69, 90), (10, 72, 98), (12, 76, 106), (14, 81, 116)]:
            part.add(bar, step, pitch, velocity, 2)


def new_parts():
    return {
        "Drums": Part("Drums"),
        "Congas": Part("Congas"),
        "Bass": Part("Bass", 32),          # Acoustic Bass
        "Piano": Part("Piano", 0),         # Acoustic Grand Piano
        "Brass": Part("Brass", 61),        # Brass Section
    }


def following(index, count):
    return CYCLE[(index + 1) % count % len(CYCLE)]


# ---------------------------------------------------------------------------- sections

def intro():
    p = new_parts()
    for bar, chord in enumerate(CYCLE):
        clave(p["Congas"], bar, 90)
        montuno(p["Piano"], bar, chord, following(bar, 4), lift=-14 if bar < 2 else -6)
        if bar >= 2:
            tumbao(p["Congas"], bar, lift=-8)
            bass_tumbao(p["Bass"], bar, chord, following(bar, 4), lift=-8, last=bar == 3)
    p["Drums"].add(3, 12, TIMBALE_LO, 96)
    p["Drums"].add(3, 14, TIMBALE_HI, 110)
    return 4, p


def verse():
    p = new_parts()
    for bar, chord in enumerate(CYCLE):
        cascara(p["Drums"], bar)
        kick(p["Drums"], bar)
        tumbao(p["Congas"], bar)
        clave(p["Congas"], bar)
        bass_tumbao(p["Bass"], bar, chord, following(bar, 4), last=bar == 3)
        montuno(p["Piano"], bar, chord, following(bar, 4))
    return 4, p


def chorus():
    p = new_parts()
    p["Drums"].add(0, 0, CRASH, 110, 4)
    for bar, chord in enumerate(CYCLE):
        bell(p["Drums"], bar)
        kick(p["Drums"], bar, lift=8)
        tumbao(p["Congas"], bar, lift=8)
        guiro(p["Congas"], bar)
        bass_tumbao(p["Bass"], bar, chord, following(bar, 4), lift=8, last=bar == 3)
        montuno(p["Piano"], bar, chord, following(bar, 4), lift=10)
        brass_riff(p["Brass"], bar, chord, bar)
    p["Drums"].add(3, 13, TIMBALE_LO, 104)
    return 4, p


def breakdown():
    p = new_parts()
    for bar, chord in enumerate(CYCLE):
        tumbao(p["Congas"], bar, lift=-4)
        clave(p["Congas"], bar)
        kick(p["Drums"], bar, lift=-10)
        bass_tumbao(p["Bass"], bar, chord, following(bar, 4), lift=-6, last=bar == 3)
        octave, dyad = CHORDS[chord][2], CHORDS[chord][3]
        p["Piano"].add(bar, 0, (octave[0],) + dyad, 70, 3)
        p["Piano"].add(bar, 11, dyad, 62, 2)
    for step, pitch, velocity in [(12, TIMBALE_LO, 84), (13, TIMBALE_LO, 70), (15, TIMBALE_HI, 96)]:
        p["Drums"].add(1, step, pitch, velocity)
    for step, velocity in enumerate([76, 84, 92, 100]):
        p["Drums"].add(3, 8 + step, TIMBALE_HI, velocity)
    for step, velocity in enumerate([100, 108, 116, 124]):
        p["Drums"].add(3, 12 + step, TIMBALE_LO, velocity)
    return 4, p


def fill():
    """One bar of E7 on the timbales, leaning into the chorus."""
    p = new_parts()
    d = p["Drums"]
    d.add(0, 0, (KICK, TIMBALE_HI), 104)
    d.add(0, 4, TIMBALE_HI, 70)
    d.add(0, 6, TIMBALE_HI, 82)
    for step, velocity in enumerate([84, 92, 100, 108]):
        d.add(0, 8 + step, TIMBALE_HI, velocity)
    for step, velocity in enumerate([100, 108, 116, 124]):
        d.add(0, 12 + step, TIMBALE_LO, velocity)
    c = p["Congas"]
    for step, pitch, velocity in [(0, CONGA_MUTE, 38), (1, CONGA_MUTE, 34), (2, CONGA_MUTE, 104),
                                  (3, CONGA_MUTE, 36), (6, CONGA_OPEN, 96), (7, CONGA_OPEN, 90)]:
        c.add(0, step, pitch, velocity)
    p["Bass"].add(0, 0, 40, 100, 3)
    p["Bass"].add(0, 6, 35, 92, 2)
    p["Bass"].add(0, 14, 33, 106, 2)
    stab = (56, 59, 62, 64)
    p["Piano"].add(0, 0, stab, 100, 2)
    p["Piano"].add(0, 3, stab, 84)
    p["Piano"].add(0, 6, stab, 96, 2)
    p["Brass"].add(0, 12, 76, 100, 2)
    p["Brass"].add(0, 14, 80, 114, 2)
    return 1, p


def ending():
    """A bar of the chorus on E7, then three hits and the last chord."""
    p = new_parts()
    bell(p["Drums"], 0)
    kick(p["Drums"], 0, lift=8)
    tumbao(p["Congas"], 0, lift=8)
    guiro(p["Congas"], 0)
    bass_tumbao(p["Bass"], 0, "E7", "Am", lift=8)
    montuno(p["Piano"], 0, "E7", "Am", lift=10)
    brass_riff(p["Brass"], 0, "E7", 2)
    chord = (57, 60, 64, 69)
    horns = (69, 72, 76)
    for step, drum, velocity in [(0, (KICK, CRASH), 112), (3, (TIMBALE_HI,), 100), (6, (KICK, TIMBALE_LO), 108)]:
        p["Drums"].add(1, step, drum, velocity)
        p["Congas"].add(1, step, CONGA_MUTE, 104)
        p["Bass"].add(1, step, 33, 104)
        p["Piano"].add(1, step, chord, 102)
        p["Brass"].add(1, step, horns, 108)
    p["Drums"].add(1, 8, (KICK, CRASH2), 122, 8)
    p["Congas"].add(1, 8, (CONGA_OPEN, CONGA_LOW), 112, 2)
    p["Bass"].add(1, 8, 33, 112, 8)
    p["Piano"].add(1, 8, chord, 112, 8)
    p["Brass"].add(1, 8, horns, 118, 8)
    return 2, p


# ---------------------------------------------------------------------------- loops

def percussion(name, build, bars=2):
    """A drums-only loop, to put under anything."""
    parts = {"Drums": Part("Drums"), "Congas": Part("Congas")}
    for bar in range(bars):
        build(parts, bar)
    return bars, parts


def main():
    order = ["Drums", "Congas", "Bass", "Piano", "Brass"]
    sections = [("1 Intro", intro), ("2 Verse", verse), ("3 Chorus", chorus),
                ("4 Breakdown", breakdown), ("5 Fill", fill), ("6 Ending", ending)]
    for label, build in sections:
        bars, parts = build()
        write(f"Loop-Malecon {label}.mid", f"Malecon {label}", bars, [parts[n] for n in order])

    def cascara_loop(parts, bar):
        cascara(parts["Drums"], bar)
        kick(parts["Drums"], bar)

    def bell_loop(parts, bar):
        bell(parts["Drums"], bar)
        kick(parts["Drums"], bar, lift=8)

    def conga_loop(parts, bar):
        tumbao(parts["Congas"], bar)
        clave(parts["Congas"], bar)

    for label, build in [("Cascara", cascara_loop), ("Cowbell", bell_loop), ("Congas and Clave", conga_loop)]:
        bars, parts = percussion(label, build)
        write(f"Loop-Latin Percussion - {label}.mid", f"Latin Percussion - {label}", bars,
              [parts["Drums"], parts["Congas"]])
    bars, parts = fill()
    write("Loop-Latin Percussion - Timbale Fill.mid", "Latin Percussion - Timbale Fill", bars,
          [parts["Drums"], parts["Congas"]])


if __name__ == "__main__":
    main()
