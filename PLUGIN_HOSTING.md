# FwdSequencer — AUv3 Plugin Hosting & State Persistence

This document explains how FwdSequencer loads third-party AUv3 instrument plugins,
displays their native UI, and persists their sound state inside a project. These
were the hardest problems in the app; the notes here exist so the solution can be
maintained without re-deriving it.

---

## 1. Overview of the audio graph

```
AVAudioEngine
 └─ per track:
      AVAudioUnitSampler  ─┐        (GM fallback instrument)
         …or…              ├─▶ AVAudioMixerNode ─▶ mainMixerNode ─▶ output
      AUv3 instrument     ─┘        (track volume / pan / meter tap)
```

Each track owns one `AVAudioMixerNode` (`trackMixers[id]`). The instrument feeding
that mixer is **either** a built-in `AVAudioUnitSampler` (General MIDI fallback) **or**
a loaded AUv3 unit (`auv3Units[id]`). Swapping instruments disconnects the old node
and connects the new one to the same mixer, so volume/pan/metering are unaffected by
instrument changes. All of this lives in `Engine/AudioEngineManager.swift`.

Key detail: the AUv3 → mixer connection uses `format: nil`
(`swapInstrument`). This lets `AVAudioEngine` negotiate the plugin's preferred output
format instead of forcing a hardcoded stereo format — some synths (e.g. GeoShred)
produce no sound when a mismatched format is imposed.

---

## 2. Instantiating an AUv3 plugin

`AudioEngineManager.loadPlugin(_:for:stateData:)`:

1. Build an `AudioComponentDescription` from the saved `PluginInfo`.
2. `AVAudioUnit.instantiate(with:options:)` — **`options: []`** (out-of-process is
   the only mode on iOS; `.loadInProcess` is macOS-only and won't compile).
3. On success, `swapInstrument` attaches/connects the unit.
4. If saved state exists, restore it **after a 1.0 s delay** — many plugins need a
   run-loop cycle to finish initialising before they accept `fullState`.

If instantiation fails, the track falls back to the GM sampler so it always makes
sound.

---

## 3. Showing the plugin's native UI

`Views/PluginEditorView.swift` hosts the plugin's own view controller.

### The ObjC bridge (why it exists)

The API that returns a plugin's view controller,
`requestViewControllerWithCompletionHandler:`, is annotated `API_UNAVAILABLE(ios)`
in Apple's Swift AudioToolbox headers even though it works fine on iOS. Swift
therefore refuses to call it. We bypass this with a tiny Objective-C shim:

- `Bridge/AUViewControllerHelper.{h,m}` re-declares the selector via a category and
  calls it. Swift calls `AUViewControllerHelper.requestViewController(for:)`.
- Wired up through `Bridge/FwdSequencer-Bridging-Header.h`.

### Embedding (`AUPluginHostController`)

A `UIViewControllerRepresentable` wraps `AUPluginHostController`, a UIKit controller
that:

- Puts the plugin view inside a `UIScrollView` with pinch-to-zoom, so fixed-size
  plugin UIs remain fully reachable on iPad.
- Uses the plugin's `preferredContentSize` as the content size. If the plugin
  reports a degenerate size (< 100 pt in either axis, e.g. GeoShred reports 0×0),
  it falls back to **800×600** so the view has real bounds to lay out in.
- **Forwards UIKit appearance lifecycle** with `beginAppearanceTransition(true,…)`
  / `endAppearanceTransition()` around the embed. Without this, some plugins
  (GeoShred) never receive `viewWillAppear` and render a blank/white view.
- On first layout, aspect-**fills** the scroll view (`max(scaleX, scaleY)`) so there
  is no dead space; the user can then pinch to zoom, tracked by `userHasZoomed` so
  auto-fit doesn't fight manual zoom.
- Overrides `preferredContentSize` to return `.zero`, preventing the child's content
  size from propagating up and forcing SwiftUI to mis-size the representable.

`PluginEditorView` is presented via `.fullScreenCover` (see `TrackRowView`), **not**
`.sheet` — on iPad a sheet is a form sheet and won't fill the screen.

### The "no UI" and preset fallbacks

If a plugin has no view controller, `onNoUI` flips the editor into a preset-list
fallback driven by the plugin's `factoryPresets` / `userPresets`.

### GeoShred note

GeoShred logs a `LaunchServices … Code=-54 "process may not map database"` error.
This is a **non-fatal** check inside GeoShred's own extension process (AUM produces
the same log). It does not prevent operation. GeoShred's blank UI was caused by the
missing appearance-transition forwarding, and its silence by the imposed audio
format — both fixed as described above.

---

## 4. Persisting plugin state (`getPluginState` / `applyPluginState`)

Different plugins store their sound state in different places. The saved blob is a
**binary property list** (`PropertyListSerialization`) — chosen over
`NSKeyedArchiver` because plugin state dictionaries mix `NSData`/`NSString`/`NSNumber`
freely and the keyed unarchiver's type allowlist rejects them.

The serialized dictionary can contain:

| Key                      | Meaning                                                     |
|--------------------------|-------------------------------------------------------------|
| `_fullState`             | `fullStateForDocument` ?? `fullState` (standard AUv3 state) |
| `_fullStateIsDocument`   | which property `_fullState` came from (restore writes back to the same one) |
| `_parameterTree`         | `{ address : value }` for every `AUParameter`               |
| `_presetNumber` / `_presetName` | current preset identity                              |
| `_parameterTreeRequired` | whether restore should re-apply the parameter tree          |

### The three plugin families and how they save

1. **Standard plugins** — real state lives in `fullState`. Saved and restored via
   `_fullState`.
2. **AudioKit plugins** — `fullState` is only ~2 keys of metadata; the actual sound
   is in a 158-entry `AUParameterTree`. We save the parameter tree and re-apply it on
   restore.
3. **EG Pulse (drum sequencer)** — stores everything (pad volumes, patterns) in a
   *substantial* `fullState`. Re-applying the parameter tree on top would clobber it.

### `_parameterTreeRequired` — the disambiguator

On save we set `_parameterTreeRequired = (fullState is NOT substantial)`, where
"substantial" means `fullState.count > 5`. On restore:

- Apply `_fullState` if present, writing it back to the **same** property it was
  captured from (`_fullStateIsDocument` records which). Writing to *both*
  `fullStateForDocument` and `fullState` corrupts complex synths — GeoShred loaded
  silently on reload until this was made symmetric. Legacy saves without the flag
  fall back to the old set-both behaviour.
- Apply `_parameterTree` **only if** `_parameterTreeRequired` is true.

This lets AudioKit's sparse-fullState plugins get their parameter tree restored,
while EG Pulse's rich fullState is left authoritative and untouched.

Two things that were deliberately removed from the restore path because they fired
async internal resets that wiped freshly-applied parameters:

- Setting `au.currentPreset` during restore.

### When state is captured

Captured in `AUPluginHostController.viewWillDisappear` (wired to
`store.capturePluginState`), **not** on the Done button — this matches how AUM
captures state, after all UI interaction has settled and the plugin has committed
its values.

---

## 5. The auto-save loop (and the bug that made it pulse)

`ProjectStore.project` has a `didSet` that calls `scheduleSave()` (a 1 s debounced
write). `saveNow()` must build a **snapshot copy** and write that — it must never
mutate `self.project`, because that would re-trigger `didSet → scheduleSave` in an
infinite ~1 Hz loop (this was the "pulsing" bug). See the comment in `saveNow()`.

---

## 6. Observation architecture (playback performance)

`ProjectStore` holds the editable `project` and playback flags. It deliberately
does **not** hold high-frequency playback telemetry, because any change to an
`@Published` property invalidates *every* view observing that object — so putting
20 Hz meter updates on the store would re-render the whole track list and transport
during playback.

Telemetry lives on two separate small `ObservableObject`s
(`Store/PlaybackMonitor.swift`), injected into the environment alongside the store:

- **`LevelMonitor`** — `trackLevels`, `masterLevel`. Updates at ~20 Hz (VU meters).
- **`PlaybackMonitor`** — `playingNotes`, `activeSteps`, `currentBar`. Updates at
  musical-event rate.

They are kept apart from each other so note/step observers (e.g. the 88-key
keyboard highlight) don't re-render on every level tick.

The rule that makes this pay off: **only small leaf views observe the monitors.**
Container views (`ProjectView`, `TrackRowView`, `TransportBar`, `MixerView`) observe
only the store, so they don't re-render during playback. The telemetry is drawn by
dedicated leaves that each observe just the monitor they need:

| Leaf view | Observes | Draws |
|-----------|----------|-------|
| `TrackPlayingDot` | `PlaybackMonitor` | per-track playing indicator |
| `TrackStepStrip`  | `PlaybackMonitor` | active-step highlight |
| `TrackKeyboard`   | `PlaybackMonitor` | keyboard note highlight |
| `TrackLevelMeter` | `LevelMonitor`    | collapsed-row VU |
| `TrackVUMeter` / `MasterVUMeter` | `LevelMonitor` | mixer VU |
| `BarCounter`      | `PlaybackMonitor` | transport bar number |

Because `fullScreenCover` / `sheet` present in a fresh environment, the monitors are
re-injected at each of those boundaries (see `FwdSequencerApp`, `ProjectBrowserView`,
`TransportBar`) exactly as `store` is.

Other performance notes:
- `PianoKeyboardView` keyboard geometry (white/black key arrays, index map) is
  `static` — computed once, not rebuilt on each re-render.
- The volume/pan Combine pipeline in `ProjectStore` uses `removeDuplicates` (via the
  `TrackMix` value type) so it only touches the audio node graph when a volume or pan
  value actually changed, not on every unrelated project edit.

## 7. Files map

| File | Responsibility |
|------|----------------|
| `Engine/AudioEngineManager.swift` | Audio graph, plugin load/swap, state save/restore, MIDI out |
| `Engine/SequencerEngine.swift`    | Real-time step sequencer (dispatch-timer tick loop) |
| `Engine/PluginManager.swift`      | Scans device for installed AUv3 instruments |
| `Store/ProjectStore.swift`        | App state, playback control, debounced persistence |
| `Store/PlaybackMonitor.swift`     | Isolated high-frequency telemetry (`LevelMonitor`, `PlaybackMonitor`) |
| `Views/PluginEditorView.swift`    | Native plugin UI hosting + preset fallback |
| `Bridge/AUViewControllerHelper.*` | ObjC shim for `requestViewController…` |
