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
- Version 1.0, **build 89** (last bumped 2026-10-27). Every TestFlight upload needs the
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
- **Keys** (reworked 2026-10-22): per controller, two switches (`MIDIKeysSetting`,
  UserDefaults "MIDIKeySettings.v2", carried over once from the old single "Keys play"
  choice): **Keys → Play Keyboard** and **Keys → Tracks**, either or both, so one
  keyboard can play the Play keyboard while another plays tracks. Which tracks:
  **Write Notes on** → each track shows a red **W**; one armed track at a time
  (`learn.writingTrackID`, not saved) is played and written into. **Write Notes off** →
  each track shows a green **P**; keys play every track with P on (`learn.playTrackIDs`,
  saved by track id). The W/P button appears when a controller has Keys → Tracks on
  (`learn.keysReachTracks`) or Write Notes is on. Notes are played **on the CoreMIDI
  thread** by `MIDIKeyRouter` (logic in the tested `MIDIKeyRouting`, which now takes a
  list of instruments per device) straight into `AudioEngineManager.playNote`; held
  notes are released when routing changes; muted/solo-silenced channels are left out.
  Notes linked with Learn go to their link instead. Writing: the pressed note is
  toggled in the armed track's pool for the selected section, obeying its scale; a
  chord (key pressed while another is down) only adds (`writePress`). New tracks are
  armed on add. Targets `trackWriteNotes(N)` (the W/P button) and `writeNotes` (punch
  in/out, re-arming the last armed track).
- **Performance controllers** (2026-10-17): unlinked CCs (not 120+), pitch bend and
  aftertouch (poly and channel) from a controller go to the same instrument as its keys
  (`MIDIKeyRouting.routeControl` → `AudioEngineManager.sendPerformanceMessage`, channel
  1, suspension-gated; channel pressure sent as a 2-byte message). Pedal up, bend
  centre, mod 0 and pressure 0 are sent when the keys move away. Program change is
  deliberately not passed (it would change the plugin's preset).
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
  VoiceOver hints. Learn and help mode switch each other off. **Menus** (track ⋯,
  Section, Settings; a folded track's name): in help mode the menu button is
  outlined and opens a **help screen** (`.helpMenu(HelpMenuPage)`, `HelpMenuSheet`)
  listing the menu's items with icon, name and each item's own help, grouped as in
  the menu; the menu itself does not open. Pages are defined in `HelpMode.swift`
  (`HelpMenuPage.section/.track/.settings`) — add items there when a menu changes.
  `HelpCenter.perform` / `guarded` on the items remain as a safety net if a menu does
  open in help mode (a folded track's long press). Toolbar items use `HelpToolbarItem`. Not covered: plugin
  windows, Key & Scale, Number of Bars/Rename, plugin pickers. The
  tutorial was removed 2026-10-22 (Graham: help mode makes it redundant). The help
  text was rewritten by Graham on 2026-10-22; keep his wording when editing it.
- **Arranger** (2026-10-23, Song Parts 2026-10-26): Section menu ▸ Arranger…
  (`Views/ArrangerView.swift`). `Song.songParts` = named groups of sections
  (`SongPart`, a section may repeat in one). `Song.arrangement` = places
  (`ArrangementSlot`: `partID` or `sectionID`, own id), no repeat counts (Graham: add
  it twice). `Song.playsArrangement` = on/off, saved with the song. All optional, old
  songs load; build-88 slots (sectionID only) decode unchanged. The order is worked out
  once, `Song.playOrder()` → `PlayOrderEntry` (id, section, slotIndex, position in the
  part); a part's sections get ids `slot.id.derived(n)`, stable across edits. Used by
  `SongStore.flattenedSections` (entries go to the sequencer under those ids, with
  `SequencerSection.sectionID` naming the section) and `SongMIDIExporter`, so export
  parity holds. Hold and Pattern Trigger set the arrangement aside
  (`SongStore.followsArrangement`) and play plain sections; switching mid-play keeps the
  place via `updateSong` matching `playsSectionID`. **Song order strip** above the
  section chips while it is active (`SongOrderStrip` in SongView): tap a place to queue
  it (`queueArrangementSlot` → engine `jump(to:)`, taken at the next section boundary,
  then carries on — unlike the pattern queue it is not held); stopped, a tap plays from
  there (`play(startingAt:)`). Deleting a section removes it from parts and the order;
  a part left empty goes too. The validator drops missing references, keeps empty parts.
- **No steps = instrument only** (2026-10-27): a track with no steps (or no notes) in a
  section does not sequence there; it stays an instrument for a MIDI keyboard with its
  own fader. Same rule in the sequencer tick and `SongMIDIExporter`; a Hold carried in
  from the previous section is released at the track's first trigger in both. No
  migration (Graham: nothing is public yet). `ExampleSongTests` checks every example
  song gives steps to every part with notes — **add new example songs there**.
- **MIDI import** (2026-10-27): Section menu ▸ Import MIDI… → `Views/MIDIImportSheet.swift`
  (each file part → New Track / existing track / skip, step size, start at first note,
  fit length, file tempo). Core in `Models/MIDIImport.swift` (tested): `MIDIFileReader`
  (SMF 0/1, running status, a track with several channels splits into parts) and
  `MIDIImportConverter` (notes → pool + Play/Hold/Pause steps, quantised; a new onset
  ends the previous note; velocities bucketed by 8). `MIDIImportPlan` gives every part
  one origin and length. `SongStore.importMIDI` converts all first, snapshots existing
  target tracks ("Before MIDI import"), sets scale chromatic. Round-trip test: what the
  exporter writes imports back to the same steps. Parts are named after the file's GM
  program ("Fretless Bass · Verse bass", "Drums" on ch 10); new tracks start on that
  built-in sound ("Use the File's Instruments").
- **Built-in sound** (2026-10-27): `SongTrack.builtInSound` (nil = program 0, 0–127, or
  `GeneralMIDI.drumKit` = 128, the percussion bank 0x78). `AudioEngineManager` keeps
  `builtInSounds[trackID]` so any sampler made later (plugin removed / failed) starts on
  it; `setBuiltInSound`. Track ⋯ menu ▸ Built-in Sound (families of 8), shown when the
  track has no plugin; also Select Instrument ▸ Built-in GM Sound (tracks and the Play
  keyboard), which switches a plugin off. Apple's MIDI Synth / Sampler / DLS Synth are
  hidden from the instrument list (silent without a host-loaded bank; they'd duplicate
  this). The bank is **GeneralUser GS v2.0.3** (S. Christian Collins),
  bundled as `Resources/GeneralUser-GS.sf2` (32 MB) with its licence beside it (free
  for software, commercial included; no attribution required, credit is courteous).
  iPadOS has no GM set of its own (Apple's gs_instruments.dls is Mac-only, the
  fallback). Source: github.com/mrbumpy409/GeneralUser-GS.
  **The bundled file is patched** by `Tools/prepare_soundfont.py` (sha256 15bb8f57…):
  unpatched, Apple's sampler CRASHES on many instruments (pianos, strings), which on
  the iPad silenced whole tracks for stretches. Fixes: loop end ≥ 8 points before the
  sample end (181 samples), sample start offsets cleared (595). Verified 2026-10-27 by
  rendering all 128 programs + drum kit offline on a GitHub macOS runner
  (`Tools/SamplerVoiceTest.swift`; runner logs are blocked by the proxy, so results
  were read back as a `::notice::` annotation). Acoustic pianos (0–3) are expensive:
  ~25–30% of a core per busy track; filters aren't the cause and the sampler's 64-voice
  limit can't be changed via fullState. Apple's DLS renders the same at <1%.
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

- **Plugin screen, reported 2026-10-17 — both items DONE 2026-10-20 (build 87):**
  1. Some plugins' editor windows do not size to the screen (`PluginEditorView`).
     **Fixed 2026-10-20, tested OK by Graham:** mid-sized plugins (KAGARIBI) were put in a scroll
     view zoomed to aspect-FILL, so they came up zoomed in with controls off screen,
     and the scroll view stole knob drags. Now no scroll view or zoom at all: large /
     undeclared-size plugins fill; others show at their declared size, centred, shrunk
     by Auto Layout if too big. Pinch-zoom of plugin windows is gone with it.
  2. **GeoShred slowness — SOLVED 2026-10-20, not our bug.** Timing showed the app had
     both instances created, restored and receiving notes within 4 s, but GeoShred was
     silent until 30 s. Cause: the GeoShred standalone app was loading a promotional
     video in the background; dismissing it ("don't show again") in the GeoShred app
     brought loading back to normal. If a plugin is ever slow again, check its own app
     first. (The timing messages used to find this were removed afterwards; commit
     a5b7444 has them if they are needed again.)

- **Effects that crash on adding — fix built 2026-10-29, to test on device.** Graham:
  Nembrini Audio Crunk, Wah and Analog Delay, and Apple's Sound Isolation crash the app
  at once. Likely cause: `engine.connect` raises an NSException (uncatchable in Swift)
  when an effect refuses the offered format (guitar effects often mono-only). Now
  `rebuildChainLocked` connects each effect via `connectEffectLocked` under
  `FWDExceptionCatcher` (Bridge/, Objective-C @try/@catch); refused, it inserts an
  `AVAudioMixerNode` converter (`effectAdapters`) trying mono/stereo at the track's
  rate, 48k, 44.1k; still refused → left out (`refusedUnits`, excluded from latency)
  and `onEffectRefused` posts a notice. NSLog lines `[FWD] … connected through a
  converter` / `would not connect` show which path was taken. If crashes persist, they
  are elsewhere (state restore, editor, render) — get the Xcode console.
- **Earlier report, 2026-10-22 — some of Apple's built-in effects crash the app** (may be
  the same cause as above).
  Seen in Graham's testing on 2026-10-21, adding Apple's own AU effects (the ones that
  ship with iPadOS, e.g. AUDelay, AUReverb, AUDistortion) to a track. Not yet looked
  at. Ask which effects, and when it crashes (on adding, on opening Edit, on play, on
  bypass), and get the crash log (Xcode console when run from Xcode, or Settings ▸
  Privacy & Security ▸ Analytics Data on the iPad). Suspects to check: Apple's units
  are in-process v2 AUs, not out-of-process AUv3s, so they may have no
  `scheduleMIDIEventBlock`/view controller and behave differently in
  `loadEffect`, `rebuildChainLocked`, bypass routing (`7a648dc`), state capture, and
  `PluginEditorView` (no custom view → generic/preset fallback).
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
