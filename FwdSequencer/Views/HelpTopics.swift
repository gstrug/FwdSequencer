import Foundation
import Combine

/// Every piece of help text in the app, in one place so it can be read through and
/// corrected together. Shown by help mode (HelpMode.swift) when a control is tapped,
/// and read out by VoiceOver as each control's hint.
///
/// Style: say what the control does, then any gesture that isn't obvious. Plain words,
/// one to three short sentences. If a control's behaviour changes, change its text here.
enum HelpTopic: String {
    // Song list
    case newSong, importSong, songRow, recentlyDeleted, needsAttention

    // Transport, first row
    case backToSongs, songName, rewind, playPause, stop, record, panic, loop, tempo, tapTempo

    // Transport, second row
    case beatAndBar, timeSignature, masterVolume, cpu, playButton, mixerButton,
         settingsMenu

    // Sections
    case sectionChip, sectionMenu, sectionBars, shape, snapshots, hold

    // A track
    case trackExpand, trackName, trackMenu, trackInstrument, trackEditInstrument,
         trackVolume, trackPan, trackMeter, trackMute, trackSolo, trackEffects, trackWrite,
         trackTime, trackKeyScale, trackSteps, trackKeyboard, trackNoteParams,
         trackStepsButton

    // Play keyboard
    case playInstrument, playEditInstrument, playVolume, playMute, playSolo, playEffects,
         playKeys, playClose

    // Mixer
    case mixerMaster, mixerFader, mixerPan

    // Steps
    case stepType, stepAmount, stepChord, stepGate, stepProbability, stepDivide,
         stepDelete, addStep, clearSteps

    // Note parameters
    case notePattern, noteShapeVelocity, noteShapeGate, noteApply, noteReset,
         noteVelocity, noteGate

    // Shape
    case shapeTracks, shapeNotes, shapeApply, shapeLength, shapeCharacter, shapeGenerate

    // Snapshots
    case snapshotTracks, snapshotSave, snapshotAudition, snapshotRestore,
         snapshotRestoreKeep, snapshotRename

    // Effects
    case effectsOn, effectEdit, effectBypass, effectReplace, effectRemove, effectAdd,
         effectOrder

    // MIDI
    case midiController, midiUse, midiTemplate, midiLoad, midiSaveAs, midiKeysPlay,
         midiTemplates, midiWriteNotes, midiClock, midiLearn

    var title: String {
        switch self {
        case .newSong: return "New Song"
        case .importSong: return "Import Song"
        case .songRow: return "A Song"
        case .recentlyDeleted: return "Recently Deleted"
        case .needsAttention: return "Needs Attention"

        case .backToSongs: return "Back to Songs"
        case .songName: return "Song Name"
        case .rewind: return "Rewind"
        case .playPause: return "Play / Pause"
        case .stop: return "Stop"
        case .record: return "Record"
        case .panic: return "Panic"
        case .loop: return "Loop"
        case .tempo: return "Tempo"
        case .tapTempo: return "Tap Tempo"

        case .beatAndBar: return "Beat and Bar"
        case .timeSignature: return "Time Signature"
        case .masterVolume: return "Master Volume"
        case .cpu: return "CPU"
        case .playButton: return "Play Keyboard"
        case .mixerButton: return "Mixer"
        case .settingsMenu: return "Settings"

        case .sectionChip: return "Section"
        case .sectionMenu: return "Section Menu"
        case .sectionBars: return "Number of Bars"
        case .shape: return "Shape"
        case .snapshots: return "Snapshots"
        case .hold: return "Hold"

        case .trackExpand: return "Expand / Collapse"
        case .trackName: return "Track Name"
        case .trackMenu: return "Track Menu"
        case .trackInstrument: return "Instrument"
        case .trackEditInstrument: return "Edit Instrument"
        case .trackVolume: return "Volume"
        case .trackPan: return "Pan"
        case .trackMeter: return "Level Meter"
        case .trackMute: return "Mute (M)"
        case .trackSolo: return "Solo (S)"
        case .trackEffects: return "Effects (FX)"
        case .trackWrite: return "Write Notes (W)"
        case .trackTime: return "Time"
        case .trackKeyScale: return "Key and Scale"
        case .trackSteps: return "Step Display"
        case .trackKeyboard: return "Note Keyboard"
        case .trackNoteParams: return "Note Params"
        case .trackStepsButton: return "Steps"

        case .playInstrument: return "Play Keyboard Instrument"
        case .playEditInstrument: return "Edit Instrument"
        case .playVolume: return "Play Keyboard Volume"
        case .playMute: return "Mute (M)"
        case .playSolo: return "Solo (S)"
        case .playEffects: return "Effects (FX)"
        case .playKeys: return "Keys"
        case .playClose: return "Close"

        case .mixerMaster: return "Master"
        case .mixerFader: return "Channel Fader"
        case .mixerPan: return "Pan"

        case .stepType: return "Step Type"
        case .stepAmount: return "Amount"
        case .stepChord: return "Pool Notes"
        case .stepGate: return "Gate"
        case .stepProbability: return "Probability"
        case .stepDivide: return "Divide"
        case .stepDelete: return "Delete Step"
        case .addStep: return "Add Step"
        case .clearSteps: return "Clear All"

        case .notePattern: return "Pattern"
        case .noteShapeVelocity: return "Velocity Range"
        case .noteShapeGate: return "Gate Range"
        case .noteApply: return "Apply / Roll"
        case .noteReset: return "Reset"
        case .noteVelocity: return "Velocity"
        case .noteGate: return "Gate"

        case .shapeTracks: return "Tracks"
        case .shapeNotes: return "Note Changes"
        case .shapeApply: return "Apply"
        case .shapeLength: return "Number of Steps"
        case .shapeCharacter: return "Character"
        case .shapeGenerate: return "Generate Steps"

        case .snapshotTracks: return "Tracks"
        case .snapshotSave: return "Save Snapshot"
        case .snapshotAudition: return "Audition"
        case .snapshotRestore: return "Restore"
        case .snapshotRestoreKeep: return "Restore & Keep"
        case .snapshotRename: return "Rename"

        case .effectsOn: return "Effects On"
        case .effectEdit: return "Edit"
        case .effectBypass: return "Bypass"
        case .effectReplace: return "Replace"
        case .effectRemove: return "Remove"
        case .effectAdd: return "Add Effect"
        case .effectOrder: return "Order"

        case .midiController: return "Controller"
        case .midiUse: return "Use"
        case .midiTemplate: return "Template"
        case .midiLoad: return "Load"
        case .midiSaveAs: return "Save As"
        case .midiKeysPlay: return "Keys Play"
        case .midiTemplates: return "Templates"
        case .midiWriteNotes: return "Write Notes from Keys"
        case .midiClock: return "MIDI Clock Output"
        case .midiLearn: return "MIDI Learn"
        }
    }

    var text: String {
        switch self {
        // Song list
        case .newSong:
            return "Start a new song from a template. You name it first; a name already in use gets a number added."
        case .importSong:
            return "Bring in a .fwdsong file, from Files or another app. It is added as a new song; nothing is replaced."
        case .songRow:
            return "Tap to open. Long press for Rename, Duplicate, Export and Delete. Swipe left to delete, right to export."
        case .recentlyDeleted:
            return "Deleted songs wait here. Restore brings one back; the bin button deletes it for good."
        case .needsAttention:
            return "A song file that could not be read. Restore Backup brings back its last good copy, if there is one."

        // Transport
        case .backToSongs:
            return "Saves this song and goes back to the song list."
        case .songName:
            return "The song's name. Tap to edit it; long press to select it all and type over it."
        case .rewind:
            return "Back to the start of the song."
        case .playPause:
            return "Play the song from the start, or pause and carry on from the same place. With Hold on, it plays the held section."
        case .stop:
            return "Stops playback and returns to the start."
        case .record:
            return "Records everything you hear. Tap again to stop, then choose WAV (24-bit) or CAF (32-bit float) to save the take."
        case .panic:
            return "Stops playback and silences every note. Use it if a note gets stuck."
        case .loop:
            return "When on, the song starts again from the top when it reaches the end. In Pattern Trigger Mode it makes a pad repeat."
        case .tempo:
            return "Beats per minute. Drag up or down to change it, tap to type an exact value, double tap for 120."
        case .tapTempo:
            return "Tap in time, at least twice, to set the tempo to your tapping."
        case .beatAndBar:
            return "Where the song is: the lit dot is the beat (red on beat one), then the bar within the section playing."
        case .timeSignature:
            return "Beats per bar, and which note gets the beat. Tap to change."
        case .masterVolume:
            return "Volume of everything together, with the overall level shown underneath. Double tap to reset to 100%."
        case .cpu:
            return "How hard the iPad is working. Plugins use most of it; crackles and dropouts start when it runs out."
        case .playButton:
            return "Shows or hides the Play keyboard, for playing a part by hand over the song with its own instrument."
        case .mixerButton:
            return "Opens the mixer: a fader, pan, mute, solo and effects for every track, the Play keyboard and the master."
        case .settingsMenu:
            return "Pattern Trigger Mode (the section chips become pads you press to play), MIDI settings and the tutorial."

        // Sections
        case .sectionChip:
            return "A part of the song. Tap to select it for editing, long press for its menu. In Pattern Trigger Mode, press to play it."
        case .sectionMenu:
            return "Rename, set the length, add, duplicate, move or delete the selected section."
        case .sectionBars:
            return "How many bars the selected section lasts. Tap to change it."
        case .shape:
            return "Rework this section's notes and steps on the tracks you choose: rotate, reverse or transpose notes, or generate new steps. Needs Hold on."
        case .snapshots:
            return "Save versions of this section's notes and steps and go back to them. Needs Hold on."
        case .hold:
            return "Repeats the selected section and keeps the editor on it, so you can change it while you listen. Shape and Snapshots need it."

        // Track
        case .trackExpand:
            return "Opens the track to edit its notes, or folds it to a single line."
        case .trackName:
            return "The track's name. Tap to edit; long press to select it all."
        case .trackMenu:
            return "Move, duplicate or delete the track, its effects, and Feel: chord roll, accent, variation, swing and timing, which make it sound less mechanical. Tinted when any Feel is on."
        case .trackInstrument:
            return "The sound this track plays. Tap to choose an AUv3 plugin, or the built-in sound."
        case .trackEditInstrument:
            return "Opens the plugin's own controls, to change its sound."
        case .trackVolume:
            return "Track volume. Drag to change it; move your finger away from the slider for finer steps. Double tap to reset to 0 dB."
        case .trackPan:
            return "Left or right in the stereo mix. Drag up or down; double tap to centre."
        case .trackMeter:
            return "How loud the track is right now."
        case .trackMute:
            return "Silences the track. It keeps running, so it comes back in time."
        case .trackSolo:
            return "Plays only the soloed tracks; everything else goes quiet. Solo more than one to hear them together."
        case .trackEffects:
            return "Tap to switch all the track's effects on or off; long press to add or edit them. Green: on. Orange: off or bypassed. With none, a tap opens the list."
        case .trackWrite:
            return "Arms the track for Write Notes: keys on your MIDI controller play it and add or remove notes in this section. Play a chord to add notes without taking any out. One track at a time."
        case .trackTime:
            return "How long each step lasts, from four whole notes (4/1) down to a 32nd note. T means triplet."
        case .trackKeyScale:
            return "The key and scale this track's notes are chosen from. Notes outside it are dimmed on the keyboard."
        case .trackSteps:
            return "The track's step sequence for this section; the lit step is the one playing. Change it with Steps."
        case .trackKeyboard:
            return "Tap keys to add or remove notes from the pool this track plays from. Blue: in the pool. Yellow: sounding now."
        case .trackNoteParams:
            return "Set how loud (velocity) and how long (gate) each note in the pool plays, one by one or as a shape."
        case .trackStepsButton:
            return "Edit the step sequence: the rules that decide which note of the pool plays next."

        // Play keyboard
        case .playInstrument:
            return "The Play keyboard's own instrument, separate from the tracks. Tap to choose a plugin or the built-in sound."
        case .playEditInstrument:
            return "Opens the Play keyboard instrument's own controls."
        case .playVolume:
            return "Volume of the Play keyboard. Double tap to reset to 0 dB."
        case .playMute:
            return "Silences the Play keyboard."
        case .playSolo:
            return "Plays the Play keyboard and soloed tracks only."
        case .playEffects:
            return "Tap to switch the Play keyboard's effects on or off; long press to add or edit them."
        case .playKeys:
            return "Play by hand. Slide across the keys to move between notes."
        case .playClose:
            return "Hides the Play keyboard."

        // Mixer
        case .mixerMaster:
            return "Volume of everything together, with the overall level."
        case .mixerFader:
            return "Track volume, with its level beside it. Drag; move away from the fader for finer steps. Double tap for 0 dB."
        case .mixerPan:
            return "Left or right in the stereo mix. Double tap to centre."

        // Steps
        case .stepType:
            return "What the step does. Fwd and Back move through the pool, Repeat plays the same note again, Play jumps to a note or chord, Random picks one, Hold lets the last note ring, Rest is silence."
        case .stepAmount:
            return "How far the step moves, how many times it repeats, or how many steps it holds or rests."
        case .stepChord:
            return "Which pool notes to play, counting from the lowest as 1. Type one number, or several like 1,3,5 for a chord."
        case .stepGate:
            return "How long this step's note sounds, as a share of the step. Double tap for 100%."
        case .stepProbability:
            return "How often the step plays. Below 100% it is sometimes silent; the sequence still moves on, and repeats the same way each time."
        case .stepDivide:
            return "Splits the step into equal repeats: 3 on a quarter-note step is a triplet."
        case .stepDelete:
            return "Removes this step."
        case .addStep:
            return "Adds a Fwd step at the end."
        case .clearSteps:
            return "Removes every step. With no steps, the notes play in order."

        // Note parameters
        case .notePattern:
            return "The shape Apply gives the notes, from lowest to highest: ramps, arch, valley, alternating, random or stagger."
        case .noteShapeVelocity:
            return "Turn on to shape how loud the notes are, between Min and Max."
        case .noteShapeGate:
            return "Turn on to shape how long the notes are, between Min and Max."
        case .noteApply:
            return "Sets the notes to the pattern, replacing their values. Random patterns say Roll; tap again for another."
        case .noteReset:
            return "Puts the shaped values back to the defaults."
        case .noteVelocity:
            return "How loud this note plays. Double tap for 100."
        case .noteGate:
            return "How long this note sounds, as a share of its step. Double tap for 50%."

        // Shape
        case .shapeTracks:
            return "Tick the tracks to change. Nothing else is touched."
        case .shapeNotes:
            return "Rotate shifts the pool round so each step lands on a different note, Reverse flips its order, Transpose moves every note up or down. The steps stay as they are."
        case .shapeApply:
            return "Makes the note change on the ticked tracks."
        case .shapeLength:
            return "How many steps Generate makes."
        case .shapeCharacter:
            return "The kind of sequence Generate makes: Flowing moves mostly step by step, Sparse leaves long notes and rests, Jumpy leaps and surprises."
        case .shapeGenerate:
            return "Replaces the ticked tracks' steps with a new sequence. Keep pressing until you like one, then save a snapshot."

        // Snapshots
        case .snapshotTracks:
            return "Tick the tracks a new snapshot covers, so you can keep one part while trying ideas on another."
        case .snapshotSave:
            return "Saves the ticked tracks' notes, steps, time, key and scale for this section. Instruments and mixer are not included."
        case .snapshotAudition:
            return "Plays the snapshot without changing anything."
        case .snapshotRestore:
            return "Puts the snapshot back into the section and removes it from the list. Original is always kept."
        case .snapshotRestoreKeep:
            return "Puts the snapshot back and keeps it in the list."
        case .snapshotRename:
            return "Change the snapshot's name."

        // Effects
        case .effectsOn:
            return "Switches the whole chain in or out. Effects you bypassed one by one stay bypassed."
        case .effectEdit:
            return "Opens the effect's own controls."
        case .effectBypass:
            return "Takes this one effect out of the sound, keeping its settings."
        case .effectReplace:
            return "Swaps this effect for another in the same place."
        case .effectRemove:
            return "Removes this effect."
        case .effectAdd:
            return "Adds an AUv3 effect at the end of the chain, up to four."
        case .effectOrder:
            return "The sound passes through the effects from top to bottom. Drag the handles to reorder."

        // MIDI
        case .midiController:
            return "A connected controller. The light flashes when it sends something, so you can tell which one is which."
        case .midiUse:
            return "Turn off to make the app ignore this controller completely."
        case .midiTemplate:
            return "The set of links this controller uses: which knob, fader or button does what."
        case .midiLoad:
            return "Switch this controller to another template, or to None."
        case .midiSaveAs:
            return "Keeps this controller's current links under a new name and switches to the copy."
        case .midiKeysPlay:
            return "Where this controller's keys go: Off, the Play keyboard, or a track. Sustain pedal, pitch bend, mod wheel and aftertouch go with them, unless linked with Learn."
        case .midiTemplates:
            return "Every saved template. Tap one to see its links; swipe or long press to copy, rename or delete. Factory ones can be copied, not changed."
        case .midiWriteNotes:
            return "Adds a W button to every track, for playing notes into a track from your controller."
        case .midiClock:
            return "Sends this song's tempo and start and stop to other apps and hardware."
        case .midiLearn:
            return "Link a control to your controller: turn Learn on, tap a control on screen, then move or press the one on the controller."
        }
    }
}
