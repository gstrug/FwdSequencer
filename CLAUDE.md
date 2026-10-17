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
- Version 1.0, **build 86** (last bumped 2026-10-16). Every TestFlight upload needs the
  build number (`CURRENT_PROJECT_VERSION`) bumped first; commits like
  "Bump build to NN for TestFlight" are the convention.
- Commit often with plain-English messages stating *why* (see `git log` for the style).
  Author commits as `Graham Struwig <g.struwig@gmail.com>`.

### Release workflow — Graham's rule (2026-10-13)

1. Make the change and **commit locally only**. **Do not push to GitHub.**
2. Graham builds from Xcode and tests on his iPad.
3. When he says so: bump `CURRENT_PROJECT_VERSION` (both Debug and Release), commit
   "Bump build to NN for TestFlight", and **only then push** to GitHub.
4. Graham archives and uploads to TestFlight himself.

### How Claude reaches the code (since 2026-10-13, personal Claude account)

- The project folder on Graham's Mac (`~/Desktop/FwdSequencer`) is connected to the
  session; edits and commits happen there via the device shell. That shell is a Linux
  sandbox: no Xcode, no `swift`, and no network access to GitHub.
- Git there needs delete permission on the folder (git removes its own lock/temp
  files); without it commits leave `.git/*.lock` files that break git and Xcode.
- To push: `git bundle create .build/claude-transfer.bundle origin/main..main` on the
  Mac, stage the bundle to the cloud workspace, fetch it into the cloud clone of
  `gstrug/FwdSequencer` and push from there (the Claude GitHub App is installed on the
  repo). Then `git update-ref refs/remotes/origin/main <sha>` on the Mac so it knows.
- GitHub Actions (`Validate`) then runs `swift test` and simulator builds — the only
  compile check available, since nothing here can run Xcode. Check it with `gh run list`.
- Contributors: Philipp ("filjo", philalimov@gmail.com) made ~21 commits in Aug 2026
  via `codex/*` PRs; he is a contributor but inactive.

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
- **MIDI controller input and MIDI Learn** (added 2026-10-16): `Models/MIDIControl.swift`
  (portable and unit-tested: decoding, links, scaling, pickup, the built-in
  nanoKONTROL2 template), `Engine/MIDIInputManager.swift` (CoreMIDI, all sources),
  `Store/MIDIControlCenter.swift` (templates per device, Learn, applying to the song,
  batched onto the main thread), `Views/MIDILearnable.swift` (`.midiLearnable(target)`,
  Learn button and banner), `Views/MIDISettingsView.swift` (Settings ▸ MIDI Controllers
  & Clock). Links are app-wide in UserDefaults and address tracks **by position**.
  Controllers act only while a song is open (set in `ProjectBrowserView`) and are
  ignored while instruments restore (`isLoading`). Learn sits in Settings ▸ MIDI.
- **Keys** (2026-10-16): per controller, "Keys play" Off / Play keyboard / Track N
  (`MIDIKeysDestination`). Notes are played **on the CoreMIDI thread** by
  `MIDIKeyRouter` (logic in the tested `MIDIKeyRouting`) straight into
  `AudioEngineManager.playNote`, so they don't wait on the UI; held notes are released
  when routing changes. Notes linked with Learn go to their link instead.
- **Write Notes from Keys** (2026-10-17): a global switch (Settings ▸ MIDI, and on the
  MIDI page; `learn.writeNotesEnabled`, UserDefaults) shows a red **W** on each track.
  W arms one track at a time (`learn.writingTrackID`, not saved). While armed, every
  enabled controller's unlinked keys play the armed track (overriding Keys play;
  silent if it can't be heard) and toggle that note in its pool for the selected
  section, obeying its scale. New tracks are armed on add. Targets `trackWriteNotes(N)`
  and `writeNotes` (punch in/out, re-arming the last armed track).
- **Play keyboard as a channel** (2026-10-16): `song.performance` gets a Mixer strip,
  M/S/FX on the Play dock, effects (SongStore `channelPath` finds a track or the
  performance), pan, and MIDI targets `play*`. Mute/solo for it is one rule,
  `Song.isAudible` / `isPlayKeyboardAudible`: Play solo silences non-soloed tracks (fed
  to the sequencer as muted, and used by `SongMIDIExporter`, so export parity holds);
  a soloed track silences Play keys unless Play is soloed. Keys routed to a muted or
  solo-silenced channel are silent. Also learnable: Show Play Keyboard, Trigger Mode.
- **Help mode** (2026-10-17): a ? button on each screen (`HelpButton`) turns on
  `HelpCenter`; controls tagged `.helpTag(.topic, instance:)` are outlined and a tap
  shows that topic in a card at the bottom (`.helpHost()` once per screen/sheet), using
  nothing else while on. All wording is in `Views/HelpTopics.swift`, also used as
  VoiceOver hints. Learn and help mode switch each other off. Not covered: plugin
  windows, Key & Scale, Number of Bars/Rename, step type and plugin pickers. The
  tutorial (`OnboardingView`) is now four pages explaining help mode, with Exit on each.
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

- **NEXT, reported 2026-10-17 — plugin screen (Graham is testing the 17 Oct changes
  first; do not start until he says):**
  1. Some plugins' editor windows do not size to the screen (`PluginEditorView`).
     Remember lesson 2: resize with Auto Layout, never transform the view.
  2. **GeoShred no longer loads.** It had been made to work after a lot of effort, so
     this is a regression, not the old "not hostable" verdict (lesson 7 may be out of
     date). Find which build it last loaded in, then look at what changed since.
     Candidates touching plugin load and MIDI delivery since build 83: `a0227ab`
     performance pass, `e82b5cb` rotation, `6c62689` Play keyboard effects
     (`loadEffects` for the performance channel, `channelPath`), and the MIDI input
     work (keys sent straight to `AudioEngineManager.playNote` from the CoreMIDI
     thread; it honours `isSuspended`, but check). Ask Graham: on a track or the Play
     keyboard, new song or existing, and what he sees (error, blank, hang, crash).

- Decide whether a hosted-plugin build (FWD as an AUv3 MIDI generator) is wanted; it
  affects where the scheduler seam goes (see `TIMING.md` section 6).
- Groove templates (per-position offset tables) not built; swing covers the common case.
- **Parked (Graham hears no problem on device):** the Timing feel caps at 40 ms
  (`SongTrack.effectiveTimingJitter`), but `scheduleLead` is 20 ms, so early pushes
  beyond 20 ms are clamped and the feel skews late above ~20 ms. The comment there
  wrongly says the lead is 50 ms; `TIMING.md` §5 still says 15 ms. Check export parity
  if this is ever touched.
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
