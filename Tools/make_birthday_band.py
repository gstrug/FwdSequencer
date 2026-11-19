#!/usr/bin/env python3
"""Adds the bass and drums to the Happy Birthday example (Graham, 2026-11-19).

    python3 Tools/make_birthday_band.py

The piano (Right Hand, Left Hand) in Resources/Example-HappyBirthdayJazz.json was
transcribed by hand and is left exactly as it is. This script (re)writes only the
Bass and Drums tracks and their parts, so it can be rerun after editing the music
below. Same notation as make_examples.py. The grid is the song's: eighth triplets,
nine steps to a 3/4 bar, a beat every three steps.

Harmony, from the piano: pickup on beat 3 | C6 . D7/F# | G9 | G7 | C | Em Am . |
F Fmaj7 Fm6 | C/E D7 G7 | C.
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_examples import Line, steps_from_events, uid, DRUMS

PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    "FwdSequencer", "Resources", "Example-HappyBirthdayJazz.json")
SONG = "Happy Birthday in C (Jazz)"
BASS_SOUND = 32   # GM Acoustic Bass

# A walking jazz-waltz bass: a note a beat, roots on the downbeat, and a triplet
# "skip" (the last triplet of beat 3) leading chromatically into the next bar.
BASS = {
    "Pickup":   "r:6 G2:3@80",
    "Bars 1-2": "C2:3@94 E2:3@80 F#2:3@84   G2:3@92 F2:3@78 D2:3@80",
    "Bars 3-4": "G1:3@92 B1:3@80 D2:3@82    C2:3@94 E2:3@80 D2:2@80 D#2:1@68",
    "Bars 5-6": "E2:3@92 A1:3@84 C2:3@78    F2:3@92 C2:3@80 D2:2@82 D#2:1@68",
    "Bars 7-8": "E2:3@90 D2:3@84 G1:3@84    C2:9@94~1.0",
}

# Jazz waltz on ride and pedal hi-hat: ride on 1, 2, 3 with a triplet skip; hi-hat
# foot on 2 and 3; the bass drum only feathered on 1; side stick now and then.
KICK, STICK, PEDAL_HAT, RIDE = 36, 37, 44, 51
LEVELS = {"X": 86, "x": 72, "o": 58, "-": 40}
BAR_A = {RIDE: "x..o.-o..", PEDAL_HAT: "...o..o..", KICK: "-........"}
BAR_B = {RIDE: "x..o..o.-", PEDAL_HAT: "...o..o..", KICK: "-........", STICK: "......o.."}
def bars(*grids):
    return {d: "".join(g.get(d, ".........") for g in grids) for d in (RIDE, PEDAL_HAT, KICK, STICK)}
DRUM_GRIDS = {
    "Pickup":   {RIDE: "......o.o", PEDAL_HAT: "...-..-.."},
    "Bars 1-2": bars(BAR_A, BAR_B),
    "Bars 3-4": bars(BAR_A, BAR_B),
    "Bars 5-6": bars(BAR_A, BAR_B),
    # A side-stick triplet into the last bar, then one ride and bass drum to end on.
    "Bars 7-8": bars(BAR_A, {RIDE: "X........", KICK: "o........"})
                | {STICK: "......-xo" + "........."},
}

def part_for(track_id, section, line, steps_total, key):
    pool, steps = steps_from_events(line.events, steps_total)
    for i, n in enumerate(pool):
        n["id"] = uid(SONG, section["name"], key, "note", i)
    for i, s in enumerate(steps):
        s.setdefault("chordPositions", [])
        s.setdefault("gate", 1.0)
        s.setdefault("probability", 1.0)
        s.setdefault("ratchets", 1)
        s["id"] = uid(SONG, section["name"], key, "step", i)
    return {"trackID": track_id, "notePool": pool, "steps": steps,
            "tempoDivision": "Eighth Triplet", "key": 0, "scale": "Chromatic"}

def main():
    with open(PATH) as f:
        song = json.load(f)
    bass_id, drums_id = uid(SONG, "track", "bass"), uid(SONG, "track", "drums")
    song["tracks"] = [t for t in song["tracks"] if t["id"] not in (bass_id, drums_id)]
    song["tracks"] += [
        {"id": bass_id, "name": "Bass", "builtInSound": BASS_SOUND,
         "mixer": {"volume": 0.72, "pan": 0.0, "isMuted": False, "isSoloed": False}},
        {"id": drums_id, "name": "Drums", "builtInSound": DRUMS,
         "mixer": {"volume": 0.6, "pan": 0.05, "isMuted": False, "isSoloed": False}},
    ]
    for section in song["sections"]:
        name = section["name"]
        total = section["numberOfBars"] * 9
        section["parts"] = [p for p in section["parts"] if p["trackID"] not in (bass_id, drums_id)]
        bass = Line(vel=84, gate=0.9).add(BASS[name])
        assert bass.t == total, (name, bass.t, total)
        drums = Line().drums(DRUM_GRIDS[name], levels=LEVELS, gate=0.5)
        assert max(len(g) for g in DRUM_GRIDS[name].values()) == total, name
        section["parts"].append(part_for(bass_id, section, bass, total, "bass"))
        section["parts"].append(part_for(drums_id, section, drums, total, "drums"))
    with open(PATH, "w") as f:
        json.dump(song, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"{len(song['tracks'])} tracks: " + ", ".join(t["name"] for t in song["tracks"]))

if __name__ == "__main__":
    main()
