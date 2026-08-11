# FWD Sequencer release checklist

## Automated

- [ ] `swift test` passes
- [ ] Simulator Debug and Release builds pass without warnings introduced by this release
- [ ] Thread Sanitizer stress run passes start/stop/rewind/tempo/live-edit loops
- [ ] Privacy report contains only expected file-timestamp and UserDefaults reasons
- [ ] Archive contains `PrivacyInfo.xcprivacy` and no unused AudioKit framework

## Musical correctness

- [ ] Rewind reproduces Random-step output for the same song seed
- [ ] Added tracks play without restarting transport
- [ ] Deleted tracks stop and cannot receive delayed note-offs
- [ ] Mute and solo silence already-ringing notes immediately
- [ ] Reordering sections preserves the section currently sounding
- [ ] Loop and time-signature changes take effect coherently
- [ ] Non-looping songs stop once and return the playhead to the start

## Audio and AUv3

- [ ] Master output cannot exceed the limiter ceiling with 12 loud tracks
- [ ] AUv3 load status remains visible until restoration actually completes
- [ ] Failed and timed-out AUv3 instruments show GM fallback and a retryable error
- [ ] Calls/Siri, headphone removal, Bluetooth changes, and Media Services Reset recover
- [ ] Background playback does not cut notes merely to autosave
- [ ] GeoShred and other compatibility exceptions are documented from device evidence

## Documents

- [ ] Existing build 1–16 songs open and migrate without musical changes
- [ ] Save failure is visible and does not show a false “Saved” confirmation
- [ ] Corrupt files appear under Needs Attention
- [ ] Exported `.fwdsong` files import on a second device
- [ ] Delete, restore, and permanent delete behave as labelled
- [ ] Undo/redo restores destructive structural and key/scale edits

## Interface and accessibility

- [ ] First launch reaches audible template playback in under 60 seconds
- [ ] Portrait and landscape layouts fit 10.2-inch through 13-inch iPads
- [ ] VoiceOver can identify transport, track, mixer, piano, and section controls
- [ ] Dynamic Type does not obscure primary actions
- [ ] All frequent controls have at least 44-point targets
- [ ] Reduced Motion and Increased Contrast remain usable
- [ ] App icon is legible at Settings and Spotlight sizes

## Distribution

- [ ] Marketing version and build number are intentional
- [ ] App Store privacy answers match the archive privacy report
- [ ] Microphone permission and deprecated Inter-App Audio entitlement are absent
- [ ] Support URL, privacy policy, screenshots, subtitle, keywords, and release notes are current
- [ ] TestFlight smoke test passes on the oldest and newest supported iPadOS versions
