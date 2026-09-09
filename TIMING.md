# Timing and the look-ahead scheduler

How FwdSequencer places notes in time today, why that limits it, and the staged plan to
fix it. Written before the change, because this touches the most timing-critical code
in the app and the risks are worth stating up front.

---

## 1. Where we are now

**Tick loop.** `SequencerEngine` runs a `DispatchSourceTimer` on `sequencerQueue` at 24
ticks per quarter (`stepsPerBeat`). Each firing works out which ticks are due from a
monotonic epoch and issues the backlog, so coalesced firings no longer make the
sequencer run slow. Measured accuracy of the *interval* is good: a triplet-eighth at
60 BPM came out at 0.3335 s against 0.3333 s expected.

**But the interval is not the placement.** A timer firing is only as punctual as the
system's willingness to run the queue. The interval averages out; individual notes still
land wherever the handler happened to run. Typical dispatch jitter is a few milliseconds,
which is at the edge of audibility on its own and clearly audible against another app.

**Everything is sent "now".**

- AUv3 notes: `sendMIDI` passes `AUEventSampleTimeImmediate`.
- MIDI clock: `sendMIDIRealtime` sets `packet.timeStamp = 0`.

Both APIs accept a *future* timestamp and we throw that away.

**Delayed events are dispatch-based.** Ratchets, chord roll and note-offs are
`DispatchWorkItem`s on `sequencerQueue` via `asyncAfter`. They are cancellable — which
is load-bearing, see §4 — but inherit the same jitter as the tick.

**Two independent clocks.** MIDI clock runs on its OWN `DispatchSourceTimer` on
`midiClockQueue`, started separately from `startSong`. Notes and clock are therefore not
phase-locked: they start at slightly different instants and drift apart. For an app
intended as a MIDI source this is the most serious of these problems.

---

## 2. What this prevents

- **Timing humanisation.** A note can only be pushed later, never earlier, so "rush"
  needs a fixed playback delay — which would drag the app behind its own MIDI clock.
  This is why Chord Roll (delay-only by nature) shipped and jitter did not.
- **Groove templates.** Same reason: they need to pull as well as push.
- **Being a trustworthy MIDI source.** Notes jittering a few ms against a clock that is
  itself on a different timer is not something to sync other gear to.
- **Being a MIDI destination.** Slaving to incoming clock needs events placed relative
  to that clock, not to when our timer fires.

---

## 3. The design

A **look-ahead scheduler**: the tick loop runs a short horizon *ahead* of real time and
emits every event stamped with the exact moment it should sound. The audio and MIDI
layers place it precisely; a late timer firing costs accuracy only if it is later than
the whole horizon.

    now ──────────── horizon (≈100 ms) ────────────▶
     │  timer fires here, emits everything due in the window,
     │  each event stamped with its own exact time
     ▼

**One timeline.** Notes and MIDI clock derive from the same musical origin, so they
cannot drift. This replaces the second timer.

**Stamping.**
- AUv3: `AUEventSampleTime` from `engine.outputNode.lastRenderTime.sampleTime` plus
  `offsetSeconds * sampleRate`.
- CoreMIDI: `MIDITimeStamp` from `mach_absolute_time()` plus the offset in host ticks.
- `AVAudioUnitSampler` cannot schedule; it keeps a dispatch fallback and stays as
  accurate as it is today.

**What it unlocks:** negative offsets for free (an event can be stamped earlier within
the horizon), so jitter, swing templates and groove cost nothing and add no latency.

---

## 4. The hard part: cancellation

Dispatch work items can be cancelled. **A stamped event handed to a plugin cannot.**

Stop, rewind, section change, track deletion and MIDI panic all currently rely on
cancelling queued events. With events already handed to the audio unit, a stop could
leave a note-on scheduled *after* the all-notes-off — a hung note, the exact failure the
panic button exists for.

This is the crux, and the horizon is the answer: keep it short (~100 ms), and on any
stop, flush by re-sending an all-notes-off stamped *after* the end of the horizon rather
than immediately. Anything already in flight is caught behind it. The horizon length is
a direct trade — longer tolerates worse timer jitter, longer is more to flush.

---

## 5. Phases

Each is separately shippable and independently revertable.

1. **Timing primitive.** ✅ Done. `MusicalTimeline` (portable core, no AVFoundation):
   ticks ↔ seconds, signed offsets, the tick window due in a horizon, and tempo change
   by REBASE so already-played ticks keep their times. No behaviour change — nothing
   drives playback from it yet.
2. **Stamped output.** ✅ Done, with one part RETRACTED. `SequencerAudioOutput` gained
   offset-carrying `playNote`/`stopNote` plus `placesScheduledEvents`, which an output
   must opt into rather than silently mistiming events. Delayed events go through a
   serial queue, so a note-off cannot overtake its note-on.

   **What did not work:** stamping AUv3 notes with a future `AUEventSampleTime` computed
   from `outputNode.lastRenderTime`. `scheduleMIDIEventBlock` takes times in the AUDIO
   UNIT'S OWN render timeline and AVAudioEngine does not expose it — the output node
   counts from engine start, a plugin attached later has its own baseline — so events
   were scheduled far in the plugin's future and never sounded. On device, a song whose
   first track was the built-in sampler and the rest AUv3s played only its first track.
   Removed; delayed delivery is uniform and dispatch-based.
3. **Horizon and flush.** ✅ Done, but UNPROVEN ON DEVICE — see below. Implemented as a
   fixed LEAD rather than a window-emitting loop: the timer runs `scheduleLead` (20 ms)
   ahead of each tick's moment and every event is stamped for that moment, so dispatch
   jitter is absorbed instead of heard. Far less disruption to a tick loop that has been
   stabilised twice already, and the same result.

   Delayed events (note-offs, ratchets, chord roll) keep their cancellable work items
   but run a lead early and stamp the lead — so nothing is ever in a plugin's hands more
   than 20 ms before it sounds, which is what makes §4 tractable. Stops flush twice:
   immediately for what is sounding, and stamped past the horizon for what is in flight.

   `scheduleLead = 0` restores the old behaviour exactly — every offset becomes "now" —
   and is the first thing to try if a plugin misbehaves. A test pins that.

   **Corrected after device testing:** the lead does NOT buy sample-accurate placement,
   because §2's stamping had to be withdrawn. What it does buy is a two-directional
   window — an event can be delivered before its nominal tick, which is what swing and
   jitter need — while accuracy stays as good as a dispatch queue, i.e. what it was
   before. The unit tests assert the sequencer emits the right OFFSETS, which it does;
   they cannot see how the output layer delivers them, which is where this went wrong.
4. **Unify the clock.** ✅ Done. `midiClockTimer` is gone. The sequencer emits clock
   pulses and transport bytes itself, from the same ticks and the same stamps as the
   notes, so the two cannot drift — the grid is 24 ticks per quarter and MIDI clock is
   24 PPQN, so it is one pulse per tick (derived, not assumed). Pulses carry a CoreMIDI
   host-time stamp rather than "now", so the clock does not inherit the dispatch jitter
   the look-ahead exists to remove. `AudioEngineManager` only decides whether pulses
   leave the app; tempo changes need no special handling, since they restart the timer
   and so rebuild the timeline the clock rides on.
5. **Timing jitter and swing.** ✅ Done, and cheap as predicted.

   *Swing* is systematic: the offbeat eighth moves from halfway through the beat to two
   thirds of the way at 100%, i.e. a sixth of a beat late. Downbeats never move.

   *Timing* is derived push and pull around each note's exact position, from the same
   FeelNoise as the rest of feel. This is the payoff for the whole rewrite — notes used
   to be sent the instant their tick fired, so they could only ever be LATE. Pulling one
   earlier is only possible because the sequencer now runs ahead of the beat. Capped at
   15 ms so the early half stays inside the 20 ms lead; beyond that a note would ask for
   a moment already gone and clamp, biasing the feel late rather than loosening it.

   Groove templates (per-position offset tables) are not built. Swing covers the common
   case; a template is the same mechanism with a table instead of a rule.

## 6. Keeping the AUv3 door open

This work decides whether FwdSequencer can ever be hosted as a plugin, so it is worth
being deliberate rather than discovering the constraint later.

An AUv3 has no timer. The host calls `internalRenderBlock` once per buffer and the
plugin emits events stamped with sample offsets *within that buffer*, taking transport,
tempo and position from the host. Timer-driven, play-now code cannot be hosted at all —
so the current design is the obstacle, and the look-ahead scheduler is the same shape as
a render block with the horizon set to one buffer. The cancellation problem in §4 also
mostly dissolves there: the horizon is a few milliseconds and the host calls back every
buffer, so little is ever in flight.

**Therefore the timeline is MUSICAL POSITION, not wall clock.** Ticks are beats; sample
and host time are derived at the output. Standalone, the position comes from our own
clock; hosted, from the host's `musicalContextBlock`. Building the horizon in seconds
would work standalone and have to be torn out to be hosted.

Already in our favour: `SequencerEngine` sits in the portable core package with no
AVFoundation dependency, and `SequencerAudioOutput` is a clean seam.

**Open product decision, needed before phase 3.** The app HOSTS AUv3 instruments, and an
AUv3 hosting other AUv3s is not practical. A plugin build would therefore be a MIDI
generator — sequencer only, notes out to the host, instruments the host's problem —
while the standalone app keeps its internal instruments. Two shapes over one core. This
affects where the seam goes, so settle it first.

## 7. Risks

- **Verify the primitive on device before building on it.** The AUv3 timeline
  assumption in §2 was flagged as uncertain in a code comment and then had phases 3, 4
  and 5 built on top of it before anyone had heard it. Two phases of that work were
  fine; the foundation was not.
- **Plugin fragility.** GeoShred crashed on MIDI it did not expect during instantiate.
  Changing *when* notes arrive is exactly the class of change that has bitten before.
  Phase 3 needs testing against the awkward plugins specifically.
- **Export parity.** `SongMIDIExporter` re-implements the tick logic. Anything affecting
  placement must land in both, or the file stops matching what was heard — already
  shipped once, with Hold.
- **Latency reporting.** A standalone CoreMIDI app cannot declare its latency to a host
  the way an AUv3 can. The horizon must not become audible offset.
