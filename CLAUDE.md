# FWD Sequencer — project briefing for Claude

Read this first in any new session. It was reconstructed on 2026-10-13 from the repo's
notes (README, SONG_MODE_PLAN, TIMING, PLUGIN_HOSTING, RELEASE_CHECKLIST) and the git
history, after earlier chat history became unavailable. Treat the code and the notes
as the source of truth; if this file disagrees with them, the repo wins.

## Who and how we work

- Owner: Graham Struwig. **Not a programmer.** He relies on Claude to run git, handle
  signing/provisioning, build, and push to GitHub. Explain in plain words, do the
  technical steps yourself, and say what you did.
- Personal project (not company work). GitHub: `gstrug/FwdSequencer`, branch `main`.
- Apple developer team `8MDY92DSB9`, bundle id `com.grahamstruwig.FwdSequencer`.
- Version 1.0, **build 82** (last bumped 2026-09-30). Every TestFlight upload needs the
  build number (`CURRENT_PROJECT_VERSION`) bumped first; commits like
  "Bump build to NN for TestFlight" are the convention.
- Commit often with plain-English messages stating *why* (see `git log` for the style).

## What it is

An iPad-first generative music sequencer. A track walks a small note pool using
readable step types (Fwd, Back, Repeat, Play, Random, Hold, Rest). Independent parts
are arranged into song sections. Paid standalone app: no accounts, analytics, ads or
backend. iPadOS 16.6+. It also **hosts third-party AUv3 instruments and effects**, with
a built-in General MIDI sampler as fallback. No third-party package dependencies.

Files: `.fwdsong` documents (import/export/backup/Recently Deleted), Type-1 MIDI
export, master recording (WAV/CAF), optional CoreMIDI clock output.

## Where things stand (as of 2026-09-30)

- ~212 commits since 2026-07-09. Build numbers reached 82 via TestFlight. Whether it has
  gone to the App Store is not recorded; every box in `RELEASE_CHECKLIST.md` is unticked in the repo, so
  what has been verified is unknown.
- Working tree was clean and `main` matched GitHub when this was written.
- Recent work (Sept): Shape sheet (transform + generate), per-track snapshots, Hold
  (repeat a section for editing, replaced "Follow"), triplet-capable tick grid, swing
  and timing feel, humanise (chord roll, accent), look-ahead scheduler, plugin delay
  compensation, AUv3 effect inserts (chain of up to four, reorderable), pattern
  trigger mode (section chips as pads, queue a pattern), double-tap-to-reset sliders,
  tutorial reachable from Song Settings, "Happy Birthday in C (Jazz)" example song.
- Last commits were CPU/render-thread lock reductions and trigger-mode pad latency.

## Architecture (details in the notes)

- `Models/` song > sections > per-track `Part`s (note pool + steps). Backward-compatible
  Codable: **old saved songs must keep loading** (this broke once; see git history).
- `Engine/SequencerEngine.swift` real-time scheduling; `MusicalTimeline.swift` ticks
  to time; `AudioEngineManager.swift` audio graph, plugin load/state, recording, MIDI;
  `SongMIDIExporter.swift` re-implements tick logic for export.
- `Store/SongStore.swift` playback, loading protection, debounced saves; telemetry is
  deliberately split into `LevelMonitor`/`PlaybackMonitor` so meters don't re-render
  the whole UI.
- `Views/` SwiftUI. `Bridge/` is a tiny Objective-C shim needed to open plugin UIs.
- Sequencer core has no AVFoundation dependency, so `swift test` runs anywhere. CI
  (`.github/workflows/validate.yml`) runs `swift test` and a simulator build on every
  push/PR.

## Hard-won lessons (do not re-learn these)

1. **Plugin loading is fragile.** Three layers protect it and all are load-bearing:
   generation-tokened loads with 15 s timeout and GM fallback, per-track MIDI
   suspension, and a *blocking* "Restoring instruments…" overlay. Never downgrade the
   overlay to a passive banner.
2. **Don't transform plugin views** (pinch-zoom) — out-of-process UIs go blank. Resize
   via Auto Layout instead.
3. **Plugin state** is a binary plist; only trust `fullState` when it has a data
   payload, otherwise re-apply the parameter tree. Capture state only at safe moments
   (editor closing, pause, leaving, backgrounding), never on the autosave timer.
4. **Thread safety:** all engine dictionaries are behind one recursive lock.
   `saveNow` must never mutate `song` (it caused an infinite autosave loop once).
5. **Stamping AUv3 notes with future sample times does not work** (plugins have their
   own render timeline) and silenced tracks on device. Delivery is lead-time +
   dispatch. Flush on *stop* only, never on start (that cut notes off).
6. **Unit tests can't hear.** Anything touching timing or plugins must be checked on a
   physical iPad with real plugins. Verify foundations on device before building on them.
7. **GeoShred** is not reliably hostable (its extension dies at OS level; a device
   reboot is the only recovery). Diagnosed by A/B test; not our bug. Other plugins
   (Galileo 2, EG Pulse, AudioKit synths) are solid.
8. **Export parity:** any change to note placement must land in both the sequencer and
   `SongMIDIExporter`, or exported MIDI stops matching what is heard.
9. Removed on purpose: undo/redo was removed (2026-08-25) and the master limiter was
   removed (it added crackle). Pattern-era code is gone; the app is song-only.

## Open items and ideas

- Decide whether a hosted-plugin build (FWD as an AUv3 MIDI generator) is wanted; it
  affects where the scheduler seam goes (see `TIMING.md` section 6).
- Groove templates (per-position offset tables) not built; swing covers the common case.
- Parameter automation deferred; per-section tempo deferred.
- Finish and tick `RELEASE_CHECKLIST.md` before any App Store submission (privacy
  answers, screenshots, accessibility, oldest/newest iPadOS smoke test).

## Build and test

- Open `FwdSequencer.xcodeproj`, scheme `FwdSequencer`, run on an iPad or simulator.
- `swift test` for the portable suite; the README has the `xcodebuild` simulator gate.
- AUv3 hosting must be tested on a physical iPad with plugins installed.

## Housekeeping

- The old `test/build-13-geoshred` fork (separate bundle id, for side-by-side build 13
  testing) has been retired. Its commits survive in the backup bundle on the Desktop.
- A full backup was taken 2026-10-13 in `~/Desktop/FwdSequencer-BACKUP-2026-10-13`.
