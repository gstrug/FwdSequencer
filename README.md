# FWD Sequencer

FWD Sequencer is an iPad-first generative music sequencer. A track moves through a
small note pool using readable operations—Fwd, Back, Repeat, Play, Random, Hold,
and Rest—then arranges independent parts into song sections.

## Product scope

- iPadOS 16.6 or later
- Paid standalone app; no accounts, analytics, advertising, or backend
- Built-in GM fallback sound and hosted AUv3 music-device instruments
- Local `.fwdsong` documents with import, export, backup, and Recently Deleted
- Background audio, deterministic Random steps, and local-only preferences

The v1 goal is a focused composition instrument, not a full DAW. Effects chains,
cloud collaboration, and broad automation should be driven by validated user need.

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
- `Engine/AudioEngineManager.swift`: audio session, limiter, AUv3 graph, MIDI, and recovery
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

See `RELEASE_CHECKLIST.md` for the complete shipping gate.
