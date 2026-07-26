# FwdSequencer — AUv3 Plugin Hosting & State Persistence

How FwdSequencer loads third-party AUv3 instrument plugins, shows their native UI,
and persists their sound state. These were the hardest problems in the app; the
notes here exist so the solution can be maintained without re-deriving it.

The app is **song-only**: a `Song` owns instrument `SongTrack`s (loaded once) plus a
dedicated `performance` instrument for the manual Play dock. `SongStore` coordinates
playback and persistence. (The song data model itself is documented in
`SONG_MODE_PLAN.md`.)

---

## 1. Audio graph

```
AVAudioEngine
 per instrument:  AVAudioUnitSampler (GM fallback)  ─┐
                  …or AUv3 instrument               ─┼─▶ AVAudioMixerNode ─▶ mainMixerNode ─▶ masterLimiter ─▶ output
                                                     ┘   (per-track vol/pan/meter tap)         (AUPeakLimiter)
```

- Each instrument (keyed by `SongTrack.id` in `AudioEngineManager`) owns one
  `AVAudioMixerNode`. The instrument feeding it is either a built-in
  `AVAudioUnitSampler` (GM fallback) or a loaded AUv3 unit. `swapInstrument`
  disconnects the old node and connects the new one to the same mixer, so
  volume/pan/metering survive instrument changes.
- A **master peak limiter** (`AUPeakLimiter`) sits between `mainMixerNode` and the
  output — a transparent safety that stops hot plugins (or dense chords) pushing the
  mix past 0 dBFS and clipping. Meters read the *pre-limiter* mix, so they still show
  when a signal is hot.
- The AUv3 → mixer connection uses `format: nil` so `AVAudioEngine` negotiates the
  plugin's preferred format rather than forcing stereo (some synths go silent under a
  mismatched format).

All of this lives in `Engine/AudioEngineManager.swift`.

---

## 2. Instantiating an AUv3 plugin

`AudioEngineManager.loadPlugin(_:for:stateData:)`:

1. Build an `AudioComponentDescription` from the saved `PluginInfo`.
2. `AVAudioUnit.instantiate(with:options:)` — **`options: []`** (iOS AUv3 is always
   out-of-process; `.loadInProcess` is macOS-only and won't compile).
3. On success, `swapInstrument` attaches/connects the unit.
4. If saved state exists, restore it **after a 1.0 s delay** — many plugins need a
   run-loop cycle before they accept `fullState`.

If instantiation fails, the instrument falls back to the GM sampler so it still makes
sound.

### Loading protection (don't interrupt a plugin mid-load)

Instantiation + state restore is asynchronous (~1–2 s). Interacting with a fragile
plugin during that window can corrupt it. So `SongStore` sets an `isLoading` flag
(`beginLoadingWindow`, ~2 s) that `SongView` renders as a **blocking "Loading
instruments…" overlay**. It fires on song **open** *and* on **live plugin changes**
(`setPlugin` / `setPerformancePlugin`), so adding/switching an instrument can't be
interrupted either.

---

## 3. Showing the plugin's native UI

`Views/PluginEditorView.swift` hosts the plugin's own view controller. It's decoupled
from any store — it uses `AudioEngineManager.shared` and calls back an
`onCommitState` closure so the caller (`SongTrackRowView` or `PlayDockView`) can
capture state.

### The ObjC bridge

`requestViewControllerWithCompletionHandler:` is annotated `API_UNAVAILABLE(ios)` in
Apple's Swift headers even though it works on iOS, so Swift refuses to call it. A tiny
Objective-C shim re-declares the selector via a category:

- `Bridge/AUViewControllerHelper.{h,m}` → Swift calls `AUViewControllerHelper.requestViewController(for:)`.
- Wired through `Bridge/FwdSequencer-Bridging-Header.h`.

### Embedding (`AUPluginHostController`)

A `UIViewControllerRepresentable` wraps `AUPluginHostController`, which:

- **Forwards UIKit appearance lifecycle** (`beginAppearanceTransition` /
  `endAppearanceTransition`) around the embed — without it some plugins never receive
  `viewWillAppear` and render blank.
- Chooses layout by the plugin's declared `preferredContentSize`:
  - **Large / full-UI plugins** (≥ 900 wide or ≥ 700 tall) and **degenerate sizes**
    (< 100 in either axis) → fit by **resizing via Auto Layout** (pinned to fill), with
    **no transform**.
  - **Smaller fixed-size plugins** → a `UIScrollView` with **pinch-zoom** so their
    controls stay reachable.
  - Why the split: zoom applies a `CGAffineTransform` to the plugin's view. Plugins
    whose UI is an **out-of-process hosted scene** (GeoShred) get that scene
    *invalidated* by a transform ("Invalid frame dimension" → blank UI). Resizing
    bounds is safe; transforming is not.
- Overrides `preferredContentSize` to `.zero` so the child's size doesn't propagate up
  and mis-size the SwiftUI representable.

Presented via `.fullScreenCover` (from `SongTrackRowView` / `PlayDockView`), not
`.sheet` — on iPad a sheet won't fill the screen.

### Preset fallback

If a plugin has no view controller, `onNoUI` flips the editor into a preset-list
fallback. Preset lists are read **lazily** (`loadPresets`, only when the fallback is
shown) — reading them eagerly pokes a plugin's preset machinery, which destabilises
fragile ones.

### GeoShred — a cautionary note

GeoShred was the single hardest plugin and, ultimately, is **not reliably hostable**
as an AUv3 on-device. Its extension fails at the OS level — `LaunchServices … Code=-54
"process may not map database"`, `fopen failed for data file`, and
`Connection to plugin interrupted/invalidated while in use` — i.e. its own process
crashes, which no host app can fix. It's also unstable with a second live instance.

We fixed everything on *our* side that provoked it: appearance-transition forwarding,
the resize-not-transform embed path, `nil`-format audio connection, reduced state
polling (below), and the loading-protection window. When it's in a good state it
works; when the device's LaunchServices/usermanager state goes bad it doesn't, and a
**device reboot** (sometimes reinstalling GeoShred itself) is the only recovery. Every
other tested plugin (Galileo 2, EG Pulse, AudioKit synths) is solid.

---

## 4. Persisting plugin state (`getPluginState` / `applyPluginState`)

The saved blob is a **binary property list** (`PropertyListSerialization`) — it
handles `NSData`/`NSString`/`NSNumber` natively, unlike `NSKeyedUnarchiver`'s
type-allowlist. Keys it can contain:

| Key                      | Meaning                                                     |
|--------------------------|-------------------------------------------------------------|
| `_fullState`             | `fullStateForDocument` (falls back to `fullState`)          |
| `_fullStateIsDocument`   | which property `_fullState` came from — restore writes back to the **same** one |
| `_parameterTree`         | `{ address : value }` for every `AUParameter`               |
| `_parameterTreeRequired` | whether restore should re-apply the parameter tree          |

To minimise poking fragile plugins, `getPluginState` reads **only
`fullStateForDocument`** (falling back to `fullState` only if absent) and does **not**
read `currentPreset`.

### The three plugin families

1. **Standard plugins** — real state in `fullState`; saved/restored via `_fullState`.
2. **AudioKit plugins** — `fullState` is ~2 keys of metadata; the real sound is in a
   158-entry `AUParameterTree`. Save + re-apply the tree.
3. **EG Pulse (drum sequencer)** — everything (pad volumes, patterns) is in a
   *substantial* `fullState`; re-applying the tree on top would clobber it.

### `_parameterTreeRequired` — the disambiguator

On save: `_parameterTreeRequired = (fullState is NOT substantial)`, where
"substantial" means `> 5` keys. On restore:

- Apply `_fullState` to the **same** property it came from (`_fullStateIsDocument`).
  Writing to *both* `fullStateForDocument` and `fullState` corrupts complex synths
  (GeoShred). Legacy saves without the flag fall back to the old set-both behaviour.
- Apply `_parameterTree` **only if** `_parameterTreeRequired` is true.
- Setting `au.currentPreset` during restore was removed — it fired async internal
  resets that wiped freshly-applied parameters.

### When state is captured

- On the plugin editor closing: `AUPluginHostController.viewWillDisappear` → the
  `onCommitState` closure → `SongStore.capturePluginState` (matches how AUM captures,
  after UI interaction settles).
- On debounced auto-save: `SongStore.saveNow` captures every instrument's state — but
  **skips capture while `isLoading`**, so it can't read a plugin mid-restore (which
  would clobber good state, or block the main thread on a hung plugin).

---

## 5. The auto-save loop (and the bug that made it pulse)

`SongStore.song` has a `didSet` that calls `scheduleSave()` (1 s debounced write).
`saveNow()` builds a **snapshot copy** and writes that — it must never mutate
`self.song`, or `didSet → scheduleSave` would loop forever (the original "pulsing"
bug). Songs persist to `Documents/Songs/*.fwdsong` (see `Store/SongPersistence.swift`).

---

## 6. Observation architecture (playback performance)

`SongStore` holds the editable `song` and playback flags. It deliberately does **not**
hold high-frequency telemetry: any change to an `@Published` property invalidates
*every* view observing that object, so 20 Hz meter updates on the store would
re-render the whole track list and transport during playback.

Telemetry lives on two small `ObservableObject`s (`Store/PlaybackMonitor.swift`),
which `SongView` injects into its subtree:

- **`LevelMonitor`** — `trackLevels`, `masterLevel` (~20 Hz VU meters).
- **`PlaybackMonitor`** — `playingNotes`, `activeSteps`, `currentBar` (musical-event
  rate). Kept apart so note/step observers don't re-render on level ticks.

The rule that makes it pay off: **only small leaf views observe the monitors** —
`SongTrackMeter`, `SongMiniSteps`, `SongKeyboard`, `SongBarCounter`, and the mixer VU
leaves. Container views observe only the store, so they don't re-render during
playback.

Other performance notes:
- `PianoKeyboardView` key geometry (white/black key arrays, index map) is `static` —
  computed once, not per re-render.
- The volume/pan Combine pipeline in `SongStore` uses `removeDuplicates` (via a
  `TrackMix` value type) so it only touches the audio node graph when a volume/pan
  value actually changed.

## 7. Files map

| File | Responsibility |
|------|----------------|
| `Engine/AudioEngineManager.swift` | Audio graph, master limiter, plugin load/swap, state save/restore, MIDI out |
| `Engine/SequencerEngine.swift`    | Real-time step sequencer (dispatch-timer tick, section sequencing, chord voicings) |
| `Engine/PluginManager.swift`      | Scans the device for installed AUv3 instruments |
| `Store/SongStore.swift`           | Song playback, live loading protection, debounced persistence |
| `Store/SongPersistence.swift`     | Song file storage (`Songs/*.fwdsong`) |
| `Store/PlaybackMonitor.swift`     | Isolated high-frequency telemetry (`LevelMonitor`, `PlaybackMonitor`) |
| `Views/SongView.swift`            | Song editor: transport, arrangement strip, track rows, loading overlay |
| `Views/PlayDockView.swift`        | Manual Play dock (its own performance instrument + scrollable keyboard) |
| `Views/SongMixerView.swift` / `MixerComponents.swift` | Mixer sheet + shared fader/VU components |
| `Views/PluginEditorView.swift`    | Native plugin UI hosting + preset fallback |
| `Views/StepEditor.swift`          | Step-sequence editor rows |
| `Bridge/AUViewControllerHelper.*` | ObjC shim for `requestViewController…` |
