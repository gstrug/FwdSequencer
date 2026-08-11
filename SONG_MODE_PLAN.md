# Song Mode — Architecture History

This document records the design that introduced ordered sections over a shared,
load-once instrument set. The shipped app is now song-only; references below to a
parallel standalone-pattern browser are historical. Parameter automation remains
deferred.

## Settled design

- **Song** = instrument tracks (loaded once) + an ordered list of sections.
- **Track** owns the instrument (plugin + song-level state) and the mixer. The
  instrument is independent of the notes — swap it and the parts stay.
- **Section** holds its own **independent** note data per track (Fork A). Duplicating
  a section clones everything; edits never leak between sections.
- **Gapless** because instruments load once when the song opens; moving between
  sections only swaps which note data each track reads — no plugin reload, no
  node-graph change.

Key insight that makes it cheap: instruments in `AudioEngineManager` are keyed by
track UUID. If a section's per-track note data reuses the **SongTrack's** UUID, notes
route to the already-loaded instrument with zero audio-graph churn at section
boundaries.

---

## Data model (new — `Models.swift`)

```swift
struct Song: Codable, Identifiable {
    var id = UUID()
    var name = "Untitled Song"
    var tempo: Double = 120
    var timeSignature = TimeSignature()
    var masterVolume: Float = 1.0
    var tracks: [SongTrack] = []      // instruments — loaded once
    var sections: [SongSection] = []      // arrangement, in play order
}

struct SongTrack: Codable, Identifiable {
    var id = UUID()                   // stable instrument key in AudioEngineManager
    var name = "Track"
    var pluginInfo: PluginInfo? = nil
    var pluginStateData: Data? = nil  // song-level sound (reuses getPluginState)
    var mixer = MixerState()
}

struct SongSection: Codable, Identifiable {
    var id = UUID()
    var name = "Section"              // "Verse", "Chorus", …
    var numberOfBars = 4              // per-section length (editable in the UI)
    var key = 0                       // section-wide harmonic context (shared by all tracks)
    var scale: MusicalScale = .chromatic
    var parts: [Part] = []            // one per SongTrack
}

struct Part: Codable {               // the per-track note data for one section
    var trackID: UUID                 // == SongTrack.id (routing key)
    var notePool: [NoteEntry] = []
    var steps: [Step] = []
    var tempoDivision: TempoDivision = .quarter   // per-track rhythm rate
}
```

Notes:
- `tempo` / `timeSignature` are song-global in v1 (per-section tempo can come later).
- Adding a SongTrack appends an empty `Part` (with that track's id) to every section;
  removing a track drops its Parts.
- The `sections` array **is** the arrangement — no separate reference layer, because
  independent-clone means no reuse. A section appearing "twice" is two SongSection objects.

---

## Phase 0 — Model + persistence (no behavior change)

- Add the structs above.
- Songs persist to their own directory `Songs/` with extension `.fwdsong`, mirroring
  `ProjectStore`'s `Projects/` / `.fwdproj` helpers. Separate namespace so patterns
  and songs never collide.
- Add `Song` load/save/list/delete statics (copy the shape of
  `ProjectStore.allSavedProjects` / `delete`).

**Risk: none** — additive types and files only.

---

## Phase 1 — Engine: section sequencing (`SequencerEngine.swift`)

Add an additive song path; leave `start(project:)` untouched so the pattern flow can't
regress.

- Introduce an internal playable shape the tick loop already understands
  (`id, tempoDivision, notePool, steps, mixer` — note the tick loop does **not** read
  key/scale, those are edit-time only).
- `func startSong(sections: [SequencerSection], tempo:, timeSignature:)` where
  `SequencerSection = { numberOfBars, tracks: [PlayTrack] }`.
- Extract the per-track trigger body of `tick()` into a helper that runs against the
  **current** section's tracks.
- At the existing loop point (`globalStep >= totalSteps`): instead of only resetting,
  **advance `sectionIndex`** (wrapping to 0 → song loops), reset per-track `TrackState`,
  recompute `stepsPerBar`/`totalSteps` from the new section's `numberOfBars`, and
  continue. Cancel pending note-offs across the boundary (reuse existing logic).
- Fire a new `onSectionChange?(index)` callback for the UI's playhead.

Because track ids are stable (SongTrack.id), `TrackState` and instrument routing carry
across sections automatically. Section changes land on a tick boundary, exactly like
today's loop — no new timing behavior.

**Test:** hardcode a 2-section song and confirm it advances and loops audibly.

---

## Phase 2 — Share one AudioEngineManager

- Lift `let audioEngine = AudioEngineManager()` out of `ProjectStore` to app level
  (`FwdSequencerApp`) and inject it into `ProjectStore` (and the new `SongStore`).
- One audio engine / one audio session; only one document plays at a time.
- Verify the pattern flow is byte-for-byte unaffected.

**Risk: low** — pure ownership move; guard that pattern and song playback are mutually
exclusive.

---

## Phase 3 — SongStore + plugin state

`SongStore: ObservableObject`, mirroring `ProjectStore`, sharing the app-level
`AudioEngineManager` and reusing the `LevelMonitor` / `PlaybackMonitor` split:

- **Open song:** load every `SongTrack`'s instrument **once**, keyed by `SongTrack.id`,
  restoring `pluginStateData`. Instantiation is async, so instruments load
  **concurrently** — open time ≈ one plugin's load, not the sum. Show a loading state
  until all report ready.
- **Play:** flatten `(SongTrack.mixer + currentSection.parts)` → `SequencerSection`s and
  call `startSong`. Wire `onSectionChange` / telemetry callbacks.
- **Save:** debounced, snapshot-copy pattern (same infinite-loop-safe approach as
  `ProjectStore.saveNow`); capture each SongTrack's state via the existing
  `getPluginState(for: SongTrack.id)`.

Plugin save/restore is reused verbatim — it's already keyed by track UUID.

---

## Phase 4 — UI

**Browser (`ProjectBrowserView`)** — add a Patterns / Songs switch (segmented control).
"New Song" creates an empty song, or optionally **seeds from a pattern**: that pattern's
tracks become the song's instruments and its notes become section 1. (This is the only
place existing patterns feed a song — as a seed, not as matched pieces.)

**SongView** (new, parallels `ProjectView`):
- Reuse `TransportBar` (tempo/time-sig/play — all song-global).
- **Track rows** reuse most of `TrackRowView`, split into two zones:
  - *Track-level (constant):* name, instrument picker, Edit Sound, mixer.
  - *Section-level (bound to selected section's Part):* key/scale/division, the
    `PianoKeyboardView` note pool, and the steps editor.
- **Arrangement strip** (new): horizontal list of sections with a playhead highlight
  driven by `onSectionChange`. Selecting a section rebinds every track row's
  section-level editors to that section's Parts.

---

## Phase 5 — Section operations

All are note-data-only (no audio-graph cost):

| Op | Implementation |
|----|----------------|
| Add | append a `SongSection` with an empty `Part` per track |
| Duplicate | deep-copy a `SongSection` (new ids) → independent clone |
| Move | reorder `song.sections` |
| Rename | edit `Section.name` |
| Delete | remove from `song.sections` |
| Edit | select section + track → existing note editor bound to that `Part` |

---

## Phase 6 — Polish

- Per-section bar length UI; song-loop toggle; current-section indicator during
  playback; empty-state and loading-state screens for song open.

---

## Risks / decisions already made

- **Independent clones (Fork A):** no cross-section reuse; duplication is the only way
  parts relate. Chosen for simplicity; CPU-identical to the reference model since only
  synthesis (shared, load-once) costs anything at playback.
- **Song-global tempo/time-sig in v1** — per-section variation deferred with automation.
- **Two documents never play at once** — enforced by the shared engine guard.
- **Concurrent instrument load** keeps song-open time bounded to a single plugin's load.

## Suggested build order

Phase 0 → 1 (engine provable in isolation) → 2 → 3 → 4 → 5 → 6. Each phase leaves the
app shippable and the pattern flow untouched.
