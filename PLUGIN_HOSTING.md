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
                  …or AUv3 instrument               ─┼─▶ AVAudioMixerNode ─▶ mainMixerNode ─▶ output
                                                     ┘   (per-track vol/pan/meter tap)   (meter/record tap)
```

- Each instrument (keyed by `SongTrack.id` in `AudioEngineManager`) owns one
  `AVAudioMixerNode`. The instrument feeding it is either a built-in
  `AVAudioUnitSampler` (GM fallback) or a loaded AUv3 unit. `swapInstrument`
  disconnects the old node and connects the new one to the same mixer, so
  volume/pan/metering survive instrument changes.
- The main mixer connects directly to the output. A limiter was removed after physical-
  device testing showed that it added CPU pressure and audible crackle with heavy
  sampled instruments. Users retain per-track and master headroom controls; release
  testing must check dense arrangements for clipping.
- The AUv3 → mixer connection uses `format: nil` so `AVAudioEngine` negotiates the
  plugin's preferred format rather than forcing stereo (some synths go silent under a
  mismatched format).

All of this lives in `Engine/AudioEngineManager.swift`.

---

## 2. Instantiating an AUv3 plugin

`AudioEngineManager.loadPlugin(_:for:stateData:completion:)`:

1. Build an `AudioComponentDescription` from the saved `PluginInfo`.
2. `AVAudioUnit.instantiate(with:options:)` — **`options: []`** (iOS AUv3 is always
   out-of-process; `.loadInProcess` is macOS-only and won't compile).
3. On success, `swapInstrument` attaches/connects the unit.
4. If saved state exists, restore it **after a 1.0 s delay** — many plugins need a
   run-loop cycle before they accept `fullState`.

If instantiation fails or exceeds 15 seconds, the instrument falls back to the GM
sampler so it still makes sound. Completion reports the actual result; `SongStore`
keeps a per-track ready/failed status and presents the failure rather than pretending
the requested plugin loaded.

### Loading protection (don't interrupt a plugin mid-load)

Instantiation + state restore is asynchronous. Interacting with a half-restored
plugin can corrupt it, and with a fragile AUv3 (GeoShred) it crashes the extension.

Three layers protect the window, and **all three are load-bearing**:

1. `SongStore` tracks generation-tokened requests, so a stale completion can never
   clear a newer load's state. Each load has a 15-second timeout and an explicit GM
   fallback — no guessed two-second window.
2. The engine **suspends MIDI per loading track**, so the sequencer tick can't hit a
   half-attached node. Note-offs still pass, so nothing hangs.
3. `SongView` shows a **blocking** *Restoring instruments…* overlay that **captures
   touches** until every load finishes.

Layer 3 is not cosmetic and must not be downgraded to a passive banner. Suspension
(layer 2) gates only *sequencer-generated* MIDI; it does nothing about the **user**
opening a plugin's UI, swapping the instrument again, or playing the Play dock
during instantiate+restore — which is precisely how GeoShred is crashed. A
non-blocking banner with `.allowsHitTesting(false)` reintroduced that crash and was
reverted; if the overlay ever needs to allow interaction, gate the plugin editor,
plugin picker, and Play dock individually first.

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

**Diagnosed by controlled A/B test (2026-08-16).** Build 54 and a build-13 fork
(separate bundle id, run back to back on the same device) produce the *identical*
failure, so nothing in ~40 builds of changes causes it.

Our embed is provably correct — GeoShred reports a sane size, we take the
no-transform fill path, and the view is visible at full alpha:

    [FWD-UI] embed declared={810, 1080} hostBounds={{0,0},{810,917.5}}
             vcClass=AUAudioUnitRemoteViewController
    [FWD-UI] FILL path -> pluginFrame={{0,0},{810,1080}} hidden=0 alpha=1.00

Both builds show the same extension dying underneath that view:

    personaAttributesForPersonaType ... com.apple.mobile.usermanagerd.xpc was invalidated
    fopen failed for data file: errno = 2          (build 13 — its OWN data files)
    Invalid frame dimension (negative or non-finite).      (x14, from its own scene)
    [C:n] Connection interrupted. / [S:4] Connection invalidated.
    [GeoShredAUExtension] Connection to plugin interrupted while in use.
    [GeoShredAUExtension] Connection to plugin invalidated while in use.
    LaunchServices: ... Code=-54 "process may not map database"
    Attempt to map database failed: permission was denied. This attempt will not be retried.
    Ignoring update for invalidated scene: UIHostedScene-...GeoShredAUExtension...
    Error acquiring assertion: "Specified target process 518 does not exist"

GeoShred's extension fails to initialise its LaunchServices client context and its
own data files, its XPC connection is invalidated, and the process ceases to
exist. We then embed a correct view belonging to a dead process, which renders
white. A host cannot revive a dead extension — which is why **Reload works** (it
launches a new extension process) and why nothing else did.

This is not a regression and not something we introduced. Report it to the vendor
with these logs; do not attempt further host-side fixes. Tried and disproven, so
not retried: request timing (viewDidLoad -> viewDidAppear -> +0.45s), discarding
the first view controller, deallocateRenderResources on the outgoing unit,
deferring its release, stopping playback before loading, pausing metering and
playback telemetry, and enlarging the settle delay. Several were kept because they
were correct on their own merits; none addressed this.

Note also that device state dominates: GeoShred's behaviour changes across
reboots, so any A/B test of our code must control for uptime and boot session or
the result is meaningless.

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

Reading AUv3 state is a *poke* — it walks `fullStateForDocument` and the parameter
tree, which can destabilise a fragile plugin the user is mid-edit. So capture is
**decoupled from the auto-save timer** and happens only at safe moments:

- On the plugin editor closing: `AUPluginHostController.viewWillDisappear` → the
  `onCommitState` closure → `SongStore.capturePluginState` (matches how AUM captures,
  after UI interaction settles).
- On **pause**, on **leaving the song** (`close()`), and on **backgrounding**
  (`captureAndSave`) — points where no MIDI is flowing.

`SongStore.saveNow` now persists the **model only** (notes/arrangement + whatever
state blob is already in the model); it never re-reads live plugins. `scheduleSave`
(1 s debounce) can therefore fire freely without poking anything. All capture is
skipped while `isLoading`, so it can't read a plugin mid-restore.

Every capture goes through `AudioEngineManager.captureState(for:)`, which **suspends
the track** (gates its MIDI + flushes ringing notes) for the moment of the read, so
the read can't race an in-flight note-on.

### Thread safety (the crash class)

The sequencer tick sends MIDI from a **background queue** while the **main thread**
loads/swaps/removes instruments and reads/writes plugin state. Those touch the same
`auv3Units`/`samplers`/`trackMixers` dictionaries and the same `auAudioUnit`. A
dictionary mutated during a concurrent read — or MIDI sent to a node mid-swap — is a
hard crash. `AudioEngineManager` serialises **all** of it behind one `NSRecursiveLock`
(`withLock`). Additionally, a `suspended` set gates MIDI per track: `loadPlugin`
suspends the track for the whole swap+restore window (and `captureState` for the read),
so the tick can't hit a half-attached node or a not-yet-restored preset. Note-offs are
still allowed while suspended, so nothing hangs.

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
| `Engine/AudioEngineManager.swift` | Audio graph, plugin load/swap, state save/restore, master recording, MIDI + clock out |
| `Engine/SequencerEngine.swift`    | Real-time step sequencer (dispatch-timer tick, section sequencing, chord voicings) |
| `Engine/SongMIDIExporter.swift`   | Deterministic type-1 MIDI rendering with tempo, meter, markers, chance, and ratchets |
| `Engine/PluginManager.swift`      | Scans the device for installed AUv3 instruments |
| `Store/SongStore.swift`           | Song playback, live loading protection, debounced persistence |
| `Store/SongPersistence.swift`     | Song file storage (`Songs/*.fwdsong`) |
| `Store/PlaybackMonitor.swift`     | Isolated high-frequency telemetry (`LevelMonitor`, `PlaybackMonitor`) |
| `Views/SongView.swift`            | Song editor: transport, arrangement strip, adaptive track rows, loading banner |
| `Views/PlayDockView.swift`        | Manual Play dock (its own performance instrument + scrollable keyboard) |
| `Views/SongMixerView.swift` / `MixerComponents.swift` | Mixer sheet + shared fader/VU components |
| `Views/PluginEditorView.swift`    | Native plugin UI hosting + preset fallback |
| `Views/StepEditor.swift`          | Step-sequence editor rows |
| `Bridge/AUViewControllerHelper.*` | ObjC shim for `requestViewController…` |
