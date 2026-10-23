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
    case sectionChip, sectionMenu, sectionBars, shape, snapshots, hold, addTrack,
         triggerMode, triggerHold, sectionRename, sectionAdd, sectionDuplicate, sectionMove,
         sectionDelete, arranger, arrangerPlay, arrangerSlot, arrangerAdd, arrangerFill,
         arrangerClear

    // A track
    case trackExpand, trackName, trackMenu, trackInstrument, trackEditInstrument,
         trackVolume, trackPan, trackMeter, trackMute, trackSolo, trackEffects, trackWrite,
         trackPlayKeys, trackMove, trackDuplicate, trackDelete, trackEffectsMenu,
         feelChordRoll, feelAccent, feelVariation, feelSwing, feelTiming,
         trackTime, trackKeyScale, trackSteps, trackKeyboard, trackNoteParams,
         trackStepsButton

    // Play keyboard
    case playInstrument, playEditInstrument, playVolume, playMute, playSolo, playEffects,
         playKeys, playClose, playOctave

    // Mixer
    case mixerMaster, mixerFader, mixerPan

    // Steps
    case stepType, stepFwd, stepBack, stepRepeat, stepPlay, stepRandom, stepHold, stepRest,
         stepAmount, stepChord, stepGate, stepProbability, stepDivide,
         stepDelete, addStep, clearSteps

    // Note parameters
    case notePattern, noteShapeVelocity, noteShapeGate, noteApply, noteReset,
         noteVelocity, noteGate

    // Shape
    case shapeTracks, shapeRotate, shapeReverse, shapeTranspose, shapeApply, shapeLength, shapeCharacter, shapeGenerate

    // Snapshots
    case snapshotTracks, snapshotSave, snapshotAudition, snapshotRestore,
         snapshotRestoreKeep, snapshotRename

    // Effects
    case effectsOn, effectEdit, effectBypass, effectReplace, effectRemove, effectAdd,
         effectOrder

    // MIDI
    case midiController, midiUse, midiTemplate, midiLoad, midiSaveAs, midiKeysPlay,
         midiKeysTracks,
         midiTemplates, midiWriteNotes, midiClock, midiLearn, midiControllersPage

    var title: String {
        switch self {
        case .newSong: return "New Song"
        case .importSong: return "More (⋯)"
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
        case .addTrack: return "Add Track"
        case .triggerMode: return "Pattern Trigger Mode"
        case .triggerHold: return "Trigger Holds to Play"
        case .sectionRename: return "Rename"
        case .sectionAdd: return "Add Section"
        case .sectionDuplicate: return "Duplicate Section"
        case .sectionMove: return "Move Earlier / Later"
        case .sectionDelete: return "Delete Section"
        case .arranger: return "Arranger"
        case .arrangerPlay: return "Play Arrangement"
        case .arrangerSlot: return "A Place in the Arrangement"
        case .arrangerAdd: return "Available Sections"
        case .arrangerFill: return "Fill with Sections in Order"
        case .arrangerClear: return "Clear Arrangement"

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
        case .trackPlayKeys: return "Keys Play (P)"
        case .trackMove: return "Move Up / Down"
        case .trackDuplicate: return "Duplicate Track"
        case .trackDelete: return "Delete Track"
        case .trackEffectsMenu: return "Effects"
        case .feelChordRoll: return "Chord Roll"
        case .feelAccent: return "Accent"
        case .feelVariation: return "Variation"
        case .feelSwing: return "Swing"
        case .feelTiming: return "Timing"
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
        case .playOctave: return "Octave"

        case .mixerMaster: return "Master"
        case .mixerFader: return "Channel Fader"
        case .mixerPan: return "Pan"

        case .stepType: return "Step Type"
        case .stepFwd: return "Fwd"
        case .stepBack: return "Back"
        case .stepRepeat: return "Repeat"
        case .stepPlay: return "Play"
        case .stepRandom: return "Random"
        case .stepHold: return "Hold"
        case .stepRest: return "Pause (Rest)"
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
        case .shapeRotate: return "Rotate"
        case .shapeReverse: return "Reverse"
        case .shapeTranspose: return "Transpose"
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
        case .midiKeysPlay: return "Keys → Play Keyboard"
        case .midiKeysTracks: return "Keys → Tracks"
        case .midiTemplates: return "Templates"
        case .midiWriteNotes: return "Write Notes from Keys"
        case .midiClock: return "MIDI Clock Output"
        case .midiLearn: return "MIDI Learn"
        case .midiControllersPage: return "Controllers & Templates"
        }
    }

    var text: String {
        switch self {
        // Song list
        case .newSong:
            return "Start a new song from scratch or open an example template. Give new songs a name. If a name is already in use, a suffix is added."
        case .importSong:
            return "Import Song: bring in a .fwdsong file from Files or another app. It is added as a new song."
        case .songRow:
            return "Tap to open the song. Long press to Rename, Duplicate, Export or Delete the song. Swipe left to delete, right to export to midi or .fwdsong. \"Arranged\" means the song has an arrangement (dimmed when Play Arrangement is off)."
        case .recentlyDeleted:
            return "Deleted songs list. Restore the song or delete it for good."
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
            return "Play/Pause the song. If the Hold function is active it works on the selected section."
        case .stop:
            return "Stops playback and returns to the start."
        case .record:
            return "Records the active audio. Tap again to stop, then choose WAV (24-bit) or CAF (32-bit float) to save the take."
        case .panic:
            return "Panic! Stops playback and silences every note. Will not silence effects tails."
        case .loop:
            return "Loop: Plays through the song and repeats. In Pattern Trigger Mode it makes the active pad repeat."
        case .tempo:
            return "Beats per minute. Drag up or down to change tempo, tap to enter an exact value or double tap resets to 120."
        case .tapTempo:
            return "Tap Tempo: tap at least twice, to set the tempo in time with your tapping."
        case .beatAndBar:
            return "Beat Indicator: Shows the bar count and beat number in a section. Red indicates beat one."
        case .timeSignature:
            return "Time signature: How many beats in a bar / which note gets one beat. Tap to change."
        case .masterVolume:
            return "Master Volume and level meter. Double tap to reset to 100%."
        case .cpu:
            return "Indicates cpu usage. Keep an eye on it, especially when adding many tracks or effects. Crackles and dropouts start when it runs out."
        case .playButton:
            return "Shows or hides the virtual keyboard. Used for playing an independent part with its own instrument."
        case .mixerButton:
            return "Opens the audio mixer: Adjust volume, pan, mute, solo and effects for every track and the virtual keyboard."
        case .settingsMenu:
            return "Settings menu: Midi learn, templates and keyboard routing."

        // Sections
        case .sectionChip:
            return "Songs can contain multiple sections. Tap a section to select for editing. Long press for its menu. In Pattern Trigger Mode, tap or hold to play the section."
        case .sectionMenu:
            return "Section Menu: Scroll through the items on this view for help on Section menu items."
        case .sectionBars:
            return "Number of bars for the selected section. Tap to change."
        case .shape:
            return "Creative options to rework the selected section. Generate or modify notes and steps on the tracks you choose. Only available when 'Hold' is on."
        case .snapshots:
            return "Save versions of a section's notes and steps and go back to them. Only available when 'Hold' is on."
        case .addTrack:
            return "Add Track: Adds a new track with the default sound."
        case .triggerMode:
            return "Enables Pattern Trigger. In this mode section chips become triggers. Tap a section to play it. Tap a second section while the first plays to queue it to follow."
        case .triggerHold:
            return "Enables Trigger Holds to Play: In Pattern Trigger Mode, a section plays when touched and stops when released."
        case .sectionRename:
            return "Rename the selected section."
        case .sectionAdd:
            return "Adds a new, empty section at the end of the song."
        case .sectionDuplicate:
            return "Adds a copy of the selected section with its settings."
        case .sectionMove:
            return "Move the position of the section in a song."
        case .sectionDelete:
            return "Deletes the selected section. A song must always have at least one section."
        case .arranger:
            return "Opens the Arranger: set the order your sections play in, using any section as often as you like."
        case .arrangerPlay:
            return "On: Play follows the arrangement. Off: sections play in order. Saved with the song. Hold and Pattern Trigger Mode play sections on their own while they are on."
        case .arrangerSlot:
            return "Position in the song's order. Drag the handle to move it, swipe left to remove it. The one playing is shown in green. Sections play from top to bottom."
        case .arrangerAdd:
            return "Adds a section to the arrangement."
        case .arrangerFill:
            return "Replaces the arrangement with every section once, in order, to rearrange from there."
        case .arrangerClear:
            return "Removes every place from the arrangement. Your sections are not changed."
        case .hold:
            return "Hold: Repeats the selected section so you can audition changes while you make them. Shape and Snapshot menu is only available when 'Hold' is on."

        // Track
        case .trackExpand:
            return "Expands the track to edit its notes, or collapses it to a single line."
        case .trackName:
            return "The track name. Tap to edit; long press to select all."
        case .trackMenu:
            return "Track Menu Help: Scroll through this screen to get help on the Track menu items."
        case .trackInstrument:
            return "The sound played by this track. Tap to choose an AUv3 plugin."
        case .trackEditInstrument:
            return "Opens the plugin's controls, to change its sound."
        case .trackVolume:
            return "Track volume. Drag to adjust. Move your finger away from the slider for finer steps. Double tap to reset to 0 dB."
        case .trackPan:
            return "Pan: Sets the track audio position in the stereo mix. Drag up or down to change; double tap to centre."
        case .trackMeter:
            return "Visual display of the track volume."
        case .trackMute:
            return "Mute: Silences the track."
        case .trackSolo:
            return "Solo: Plays only the soloed tracks; Solo more than one to hear them together."
        case .trackEffects:
            return "Effects: Tap to toggle all the track effects on or off; long press to add or edit effects. Green when effects are active, Orange when they are off or bypassed."
        case .trackWrite:
            return "Write: Arms a track so notes can quickly be edited using a midi controller. Play a chord to add multiple notes. Single notes can be toggled on/off. Write Notes from Keys must be on in Settings ▸ MIDI."
        case .trackPlayKeys:
            return "Play: Turn Keys ▸ Tracks on in Settings ▸ MIDI ▸ Controllers & Templates to enable. Your MIDI controller can now play any track where P is active (green)."
        case .trackMove:
            return "Moves the track up or down in the list. MIDI links are attached to the track position, so Track 1 is always the top track."
        case .trackDuplicate:
            return "Adds a copy of the entire track with instrument, sound, mixer settings and notes for every section."
        case .trackDelete:
            return "Deletes the track. You are asked to confirm."
        case .trackEffectsMenu:
            return "Opens the track's effects menu to add, edit, reorder or bypass them."
        case .feelChordRoll:
            return "Chord Roll: Slightly offsets note timing in a chord to add a more natural feel."
        case .feelAccent:
            return "Accent: Plays notes on the first beat a little louder to give the rhythm a pulse."
        case .feelVariation:
            return "Variation: varies each note's loudness and length slightly for a more natural feel."
        case .feelSwing:
            return "Swing: delays every second note slightly to give a shuffle feel."
        case .feelTiming:
            return "Timing: moves notes slightly early or late at random, like a human player."
        case .trackTime:
            return "Time: Duration of a step for the selected Section. Adjustable from four whole notes down to a 32nd note. T means triplet."
        case .trackKeyScale:
            return "The key and scale can be assigned independently for each track. Notes falling outside the scale are dimmed and not selectable. If a scale is changed, active notes outside of the new scale will be removed."
        case .trackSteps:
            return "The track's step sequence display for the active section; the lit step is the one playing. Edit Steps using the Steps menu under an expanded track."
        case .trackKeyboard:
            return "The heart of FWD Sequencer. Tap keys to add or remove notes in the track pool. Blue notes are added to the note pool. Notes in the pool are indexed from lowest to highest, not the order of selection. When notes sound they will display Yellow."
        case .trackNoteParams:
            return "Note Params: Set how loud (velocity) and how long (gate) each note in the pool plays. Adjust individual notes or apply a preset shape."
        case .trackStepsButton:
            return "Edit the step sequence: the rules that determine the order in which notes in the pool play."

        // Play keyboard
        case .playInstrument:
            return "Independently play a virtual keyboard over the sequenced tracks. Tap to choose a plugin."
        case .playEditInstrument:
            return "Tap to open the plugin's controls to edit the sound played by the virtual keyboard."
        case .playVolume:
            return "Volume of the virtual keyboard. Double tap to reset to 0 dB."
        case .playMute:
            return "Mute the virtual keyboard."
        case .playSolo:
            return "Solo the virtual keyboard."
        case .playEffects:
            return "Tap to toggle the virtual keyboard's effects on or off; long press to add or edit them."
        case .playKeys:
            return "Slide across the keys to move between notes or play individual notes or chords."
        case .playClose:
            return "Hides the Play keyboard."
        case .playOctave:
            return "Moves the virtual keyboard down or up an octave. The note in the middle shows which C you are on."

        // Mixer
        case .mixerMaster:
            return "Master Volume: Overall level for all tracks."
        case .mixerFader:
            return "Individual Track volume. Drag to adjust; move away from the fader for finer steps. Double tap for 0 dB."
        case .mixerPan:
            return "Left or right balance in the stereo mix. Double tap to centre."

        // Steps
        case .stepType:
            return "Step Type: Determines the next move the sequencer should make on this track. The sequencer steps continuously through the pool and executes the rules list from top to bottom."
        case .stepFwd:
            return "Fwd: moves forward through the note pool index by the amount set, and plays that note."
        case .stepBack:
            return "Back: moves back through the note pool index by the amount set, and plays that note."
        case .stepRepeat:
            return "Repeat: repeats the last note the number of times set."
        case .stepPlay:
            return "Play: jumps to a note in the pool by its index position and plays it. Several notes can be played together as a chord by specifying multiple comma separated notes e.g. 1,3,5."
        case .stepRandom:
            return "Random: Jumps to a random index in the pool and plays the note."
        case .stepHold:
            return "Hold: keeps the previous note active for the number of steps set."
        case .stepRest:
            return "Pause: silences notes for the number of steps set. The previous note stops."
        case .stepAmount:
            return "Depending on the step type, it sets how far the step moves, how many times it repeats, or how many steps it holds or rests."
        case .stepChord:
            return "Which notes in the pool to play. Type one number, or several like note 1,3,5 for a chord. The numbers indicate the note position, from bottom to top in the note pool."
        case .stepGate:
            return "How long this step's note sounds, as a share of the step. Double tap for 100%."
        case .stepProbability:
            return "How often the step plays. Lower percentage increases the chance of the note not playing every time. Double tap to reset to 100%."
        case .stepDivide:
            return "Splits the step into equal repeats: 3 on a quarter-note step is a triplet."
        case .stepDelete:
            return "Removes this step."
        case .addStep:
            return "Adds a new step at the end of the list. Initially set to Fwd, change it to your preference."
        case .clearSteps:
            return "Removes every step. With no steps, the notes play forward in order."

        // Note parameters
        case .notePattern:
            return "Choose a preset shape to apply to the note pool. Ramp up, Ramp down, Arch, Valley, Alternating, Random or Stagger."
        case .noteShapeVelocity:
            return "Activate to apply a minimum and maximum velocity range to the selected shape."
        case .noteShapeGate:
            return "Activate to apply a minimum and maximum gate range to the selected shape."
        case .noteApply:
            return "Applies the shape settings to the notes. Apply changes to Roll for random patterns. Keep rolling until you get something you like."
        case .noteReset:
            return "Sets the velocity and gate values back to the defaults."
        case .noteVelocity:
            return "Adjust how loud this note plays. Double tap to reset to 100."
        case .noteGate:
            return "How long this note sounds, as a share of its step. Double tap to reset to 50%."

        // Shape
        case .shapeTracks:
            return "Tick the tracks to change. Only selected tracks will be affected."
        case .shapeRotate:
            return "Rotate shifts the note pool round, forwards or backwards a number of steps, so each step now lands on a different note. The steps stay as they are."
        case .shapeReverse:
            return "Reverse flips the order of the note pool, so the lowest note takes the highest note's place. The steps stay as they are."
        case .shapeTranspose:
            return "Transpose moves every note in the pool up or down by the interval you choose. The steps stay as they are."
        case .shapeApply:
            return "Applies the changes to the selected (ticked) tracks."
        case .shapeLength:
            return "Sets how many steps to Generate."
        case .shapeCharacter:
            return "The kind of sequence Generate makes: Flowing moves mostly step by step, Sparse leaves long notes and rests, Jumpy leaps and surprises."
        case .shapeGenerate:
            return "Replaces the selected (ticked) tracks steps with a new sequence. Keep pressing until you find one you like. Tip: Save a snapshot of anything you like so you can come back to it."

        // Snapshots
        case .snapshotTracks:
            return "Tick the tracks a new snapshot covers, so you can keep parts while trying ideas on another."
        case .snapshotSave:
            return "Saves the ticked tracks' notes, steps, time, key and scale for this section. Instruments and mixer are not included."
        case .snapshotAudition:
            return "Plays the snapshot back without changing anything."
        case .snapshotRestore:
            return "Puts the saved snapshot back into the section and removes it from the list."
        case .snapshotRestoreKeep:
            return "Puts the saved snapshot back and keeps it in the list."
        case .snapshotRename:
            return "Change the snapshot's name to easily identify it."

        // Effects
        case .effectsOn:
            return "Switches the whole effects chain in or out. Bypassed effects stay bypassed."
        case .effectEdit:
            return "Opens the effect's controls for editing."
        case .effectBypass:
            return "Switches an effect in or out of the chain, keeping its settings."
        case .effectReplace:
            return "Replace the effect with a different one."
        case .effectRemove:
            return "Remove this effect."
        case .effectAdd:
            return "Adds an AUv3 effect at the end of the chain, each track can hold up to four effects."
        case .effectOrder:
            return "The sound passes through the effects chain from top to bottom. Drag the handles to reorder."

        // MIDI
        case .midiController:
            return "A connected controller. The light flashes when it sends MIDI."
        case .midiUse:
            return "Turn off to ignore this controller."
        case .midiTemplate:
            return "The set of MIDI links configured for this controller."
        case .midiLoad:
            return "Load a preconfigured template for this controller, or switch to None."
        case .midiSaveAs:
            return "Saves this controller's current links under a new name and switches to the saved copy."
        case .midiKeysPlay:
            return "Connects this controller to the virtual keyboard's instrument. Sustain, pitch bend, mod wheel and aftertouch are active unless linked differently in the template."
        case .midiKeysTracks:
            return "Send this controller's MIDI notes to every track armed with P. If Write Notes is on, sends notes to the track with W armed."
        case .midiTemplates:
            return "Saved templates. Tap one to view its links; swipe or long press to copy, rename or delete. Factory templates can be copied, not changed."
        case .midiWriteNotes:
            return "On: Shows W. Arm a track and write notes to it from your MIDI keyboard. Off: Shows P. Arm tracks you want your MIDI keyboard to play."
        case .midiClock:
            return "Sends this song's tempo and start and stop to other apps and hardware."
        case .midiLearn:
            return "Link a control to your MIDI controller: turn on MIDI Learn in settings, tap a control on screen, then move or press the hardware control on the MIDI device to link it."
        case .midiControllersPage:
            return "Opens the MIDI page to access connected controllers, their templates and track assignments. Write or Play notes and MIDI clock settings."
        }
    }
}
