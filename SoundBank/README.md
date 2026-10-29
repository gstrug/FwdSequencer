# FWD-GM.sf2, the built-in General MIDI sounds

`FWD-GM.sf2` (106.2 MB, sha256 `f20a7f1944ea5c40e48c7cb0fa5b679a885fa45980da0d16212af76237665f22`)
is kept here in six parts because GitHub refuses files over 100 MB. Xcode's
"Join sound bank" build phase joins them into the app bundle on every build.

## What it is

Each of the 128 General MIDI programs, and the drum kit, taken from one of two banks,
picked by Graham on 2026-10-29 by ear and by processor cost (`Tools/bank-picks.json`:
79 from FluidR3, 50 from GeneralUser):

- **GeneralUser GS v2.0.3** by S. Christian Collins (github.com/mrbumpy409/GeneralUser-GS),
  licence in `FwdSequencer/Resources/GeneralUser-GS-LICENSE.txt`.
- **FluidR3_GM** by Frank Wen, MIT licence, `FwdSequencer/Resources/FluidR3-LICENSE.txt`
  (Debian package fluid-soundfont-gm 3.1).

GeneralUser's acoustic pianos cost Apple's sampler 20-30% of a core per busy track,
which overloaded songs with piano parts; FluidR3's cost about 2%.

## How to rebuild it

1. Patch both banks so Apple's sampler can play them: `Tools/prepare_soundfont.py in out`
   (loop ends at least 8 points before the sample end, sample start offsets cleared;
   unpatched, many instruments crash the sampler).
2. Merge: `Tools/merge_banks.py GU-patched.sf2 Fluid-patched.sf2 Tools/bank-picks.json FWD-GM.sf2`.
3. Split: `split -b 18000000 -a 1 FWD-GM.sf2 SoundBank/FWD-GM.sf2.part-`. Six parts are
   expected by the build phase; change it if the count changes.

Verified 2026-10-29 on a GitHub macOS runner: every program renders through
AVAudioUnitSampler with no crash and no gaps (`Tools/SamplerVoiceTest.swift`).
