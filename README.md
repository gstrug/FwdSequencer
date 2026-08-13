# FWD Sequencer

FWD Sequencer is an iPad-first generative music sequencer. A track moves through a
small note pool using readable operations—Fwd, Back, Repeat, Play, Random, Hold,
and Rest—then arranges independent parts into song sections.

## Product scope

- iPadOS 16.6 or later
- Paid standalone app; no accounts, analytics, advertising, or backend
- Built-in GM fallback sound and hosted AUv3 music-device instruments
- Local `.fwdsong` documents with import, export, backup, and Recently Deleted
- Background audio, deterministic Random/chance steps, ratchets, and section variations
- Type-1 MIDI export, real-time master recording, and optional CoreMIDI clock output
- Searchable AUv3 instruments with local favorites and explicit GM replacement fallback

The v1 goal is a focused composition instrument, not a full DAW. Effects chains,
cloud collaboration, and broad automation should be driven by validated user need.

## Section tools (Transform / Variations / Follow)

These sit in the section settings bar and act on the **currently selected section**.

### Transform

Four one-shot edits applied **in place to every track** in the section. Each is a
single undoable action; none of them add or remove steps.

| Item | Effect |
|------|--------|
| **Rotate Notes** | Moves the first note of each track's pool to the end (pools of >1 note). Steps are unchanged, so every step lands on a different note — the pattern shifts through the pool. |
| **Reverse Notes** | Reverses each track's note pool order. Steps unchanged. |
| **Flip Direction** | Swaps every `Fwd` step ↔ `Back` step. Play/Rep/Hold/Pause/Random are untouched. |
| **Evolve One Step** | Picks **one** random step per track and reassigns its type from Fwd, Back, Rep, Random, Hold, Pause (never Play). Driven by the song's stored seed, which it advances — so it is deterministic and reproducible, not truly random. |

### Variations

Named **snapshots of a section's note data** — every track's note pool, steps,
key/scale, and rate. Up to 32 per section.

- **Save Current Snapshot** stores the section's current state as "Variation N".
- Each saved variation offers **Apply** (replaces the section's current parts) and
  **Delete Snapshot**.

Variations let you try alternate takes **without adding arrangement sections**.
Applying is undoable, but it overwrites whatever is currently in the section, so
snapshot the current state first if you want to return to it. Typical workflow:
snapshot → Transform → keep it, or Apply the snapshot to revert.

### Follow

When **on**, the editor switches the selected section to whichever section is
playing, so the steps and keyboard track the playhead. When **off**, manual section
selection stays put during playback — useful for editing section 3 while section 1
plays. The setting persists across launches.

## Build

1. Open `FwdSequencer.xcodeproj` in the current Xcode release.
2. Select the `FwdSequencer` scheme and an iPad simulator or physical iPad.
3. Build and run. AUv3 hosting must be tested on a physical device with installed
   instruments; the simulator proves only the app-owned UI and model paths.

There are no third-party package dependencies.

## Tests

Run the portable deterministic and migration suite:

```sh
swift test
```

Run the iOS build gate:

```sh
xcodebuild \
  -project FwdSequencer.xcodeproj \
  -scheme FwdSequencer \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Pull requests and pushes to `main` run both gates in GitHub Actions.

## Architecture

- `Models/`: backward-compatible song, section, track, note, and step documents
- `Engine/SequencerEngine.swift`: queue-owned real-time scheduling and step traversal
- `Engine/AudioEngineManager.swift`: audio session, AUv3 graph, recording, MIDI, and recovery
- `Engine/SongMIDIExporter.swift`: deterministic Standard MIDI File rendering
- `Store/SongStore.swift`: interaction, playback coordination, undo, and save lifecycle
- `Store/SongPersistence.swift`: atomic files, backups, import/export, and recovery
- `Views/`: SwiftUI browser, onboarding, transport, arrangement, editor, and mixer

## Audio verification matrix

Before release, test at least:

- Built-in GM sound with 1, 4, and 12 tracks
- Three AUv3 instruments: lightweight synth, sampled instrument, and known-fragile plugin
- Start/stop/rewind and rapid tempo changes
- Add/delete/mute/solo/reorder during playback
- Headphone removal, Bluetooth route change, phone/Siri interruption
- Background/foreground while playing and while stopped
- Media Services Reset from iOS Developer settings
- Save/reopen, failed plugin fallback, and state restoration
- Master recording export and MIDI file import in another music app
- MIDI clock Start/Continue/Stop and tempo following in a second app

See `RELEASE_CHECKLIST.md` for the complete shipping gate.
