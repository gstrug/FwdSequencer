import SwiftUI
import AVFoundation
import AudioToolbox
import UIKit

// MARK: - UIViewControllerRepresentable wrapper

private struct AUPluginView: UIViewControllerRepresentable {
    let audioUnit: AUAudioUnit
    var onNoUI: (() -> Void)?
    var onWillDisappear: (() -> Void)?
    /// Fired once the plugin's view controller is embedded (or known not to exist),
    /// i.e. when it is safe to send the plugin MIDI again. See PluginEditorView.
    var onViewReady: (() -> Void)?

    func makeUIViewController(context: Context) -> AUPluginHostController {
        AUPluginHostController(audioUnit: audioUnit, onNoUI: onNoUI,
                               onWillDisappear: onWillDisappear, onViewReady: onViewReady)
    }

    func updateUIViewController(_ uiViewController: AUPluginHostController, context: Context) {}
}

final class AUPluginHostController: UIViewController, UIScrollViewDelegate {
    private let audioUnit: AUAudioUnit
    private var onNoUI: (() -> Void)?
    private var onWillDisappear: (() -> Void)?
    private var onViewReady: (() -> Void)?
    private var pluginView: UIView?
    private let scrollView = UIScrollView()
    private var userHasZoomed = false

    init(audioUnit: AUAudioUnit, onNoUI: (() -> Void)?, onWillDisappear: (() -> Void)?,
         onViewReady: (() -> Void)? = nil) {
        self.audioUnit = audioUnit
        self.onNoUI = onNoUI
        self.onWillDisappear = onWillDisappear
        self.onViewReady = onViewReady
        super.init(nibName: nil, bundle: nil)
    }

    /// Call once the plugin UI is up (or absent). Idempotent — only the first call fires.
    private func signalViewReady() {
        guard let ready = onViewReady else { return }
        onViewReady = nil
        ready()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onWillDisappear?()
    }

    required init?(coder: NSCoder) { fatalError() }

    // Prevent the plugin VC's preferredContentSize from propagating to SwiftUI.
    override var preferredContentSize: CGSize {
        get { .zero }
        set {}
    }
    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {}

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        scrollView.delegate = self
        scrollView.minimumZoomScale = 0.25
        scrollView.maximumZoomScale = 3.0
        scrollView.bouncesZoom = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

    }

    private var hasRequestedView = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Deliberately NOT in viewDidLoad. Standing up an out-of-process AUv3 view is
        // heavy (XPC + a hosted UIScene), and doing it during the editor's presentation
        // animation put it in direct competition with that transition and with live
        // audio rendering — a big plugin (GeoShred) then came up blank while the
        // sequencer was running. Requesting once the transition has finished gives the
        // scene a quiet frame to establish in.
        guard !hasRequestedView else { return }
        hasRequestedView = true
        AUViewControllerHelper.requestViewController(for: audioUnit) { [weak self] vc in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let vc else {
                    NSLog("[FWD-UI] requestViewController returned NIL — plugin has no UI")
                    self.onNoUI?(); self.signalViewReady(); return
                }
                self.embed(vc)
            }
        }
    }

    private func embed(_ vc: UIViewController) {
        addChild(vc)
        let pv = vc.view!
        let declared = vc.preferredContentSize
        NSLog("[FWD-UI] embed declared=%@ hostBounds=%@ vcClass=%@",
              NSCoder.string(for: declared), NSCoder.string(for: view.bounds),
              String(describing: type(of: vc)))

        // Large full-UI plugins (or ones with a degenerate declared size) are fitted by
        // RESIZING via Auto Layout — never by a zoom transform. Out-of-process/hosted
        // plugin views (e.g. GeoShred) get their scene invalidated when a CGAffineTransform
        // is applied to them ("Invalid frame dimension"); resizing their bounds is safe.
        let wantsFill = declared.width < 100 || declared.height < 100
                     || declared.width >= 900 || declared.height >= 700
        if wantsFill {
            scrollView.isHidden = true
            pv.translatesAutoresizingMaskIntoConstraints = false
            vc.beginAppearanceTransition(true, animated: false)
            view.addSubview(pv)
            NSLayoutConstraint.activate([
                pv.topAnchor.constraint(equalTo: view.topAnchor),
                pv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                pv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                pv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            vc.didMove(toParent: self)
            vc.endAppearanceTransition()
            NSLog("[FWD-UI] FILL path -> pluginFrame=%@ hidden=%d alpha=%.2f",
                  NSCoder.string(for: pv.frame), pv.isHidden ? 1 : 0, pv.alpha)
            signalViewReady()
            return
        }

        // Small fixed-size plugin: scroll + zoom to fit so its controls stay reachable.
        pv.translatesAutoresizingMaskIntoConstraints = true
        pv.frame = CGRect(origin: .zero, size: declared)
        vc.beginAppearanceTransition(true, animated: false)
        scrollView.addSubview(pv)
        scrollView.contentSize = declared
        pluginView = pv
        vc.didMove(toParent: self)
        vc.endAppearanceTransition()
        NSLog("[FWD-UI] SCROLL path -> pluginFrame=%@ contentSize=%@ hidden=%d alpha=%.2f",
              NSCoder.string(for: pv.frame), NSCoder.string(for: scrollView.contentSize),
              pv.isHidden ? 1 : 0, pv.alpha)
        signalViewReady()
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !userHasZoomed,
              let pv = pluginView,
              scrollView.bounds.width > 0,
              pv.frame.width > 0 else { return }

        let scaleX = scrollView.bounds.width  / pv.frame.width
        let scaleY = scrollView.bounds.height / pv.frame.height
        let scale  = max(scaleX, scaleY)   // aspect-fill: no dead space, overflow is scrollable
        guard scale > 0.01 else { return }
        scrollView.minimumZoomScale = min(0.25, scale * 0.5)
        // Only update if the scale has meaningfully changed to avoid layout loops.
        if abs(scrollView.zoomScale - scale) > 0.01 {
            scrollView.setZoomScale(scale, animated: false)
        }
        centerContent()
        NSLog("[FWD-UI] laidOut zoom=%.3f pluginFrame=%@ scrollBounds=%@",
              scrollView.zoomScale, NSCoder.string(for: pv.frame),
              NSCoder.string(for: scrollView.bounds))
    }

    private func centerContent() {
        guard let pv = pluginView else { return }
        let scaledW = pv.frame.width  * scrollView.zoomScale
        let scaledH = pv.frame.height * scrollView.zoomScale
        let xInset = max(0, (scrollView.bounds.width  - scaledW) / 2)
        let yInset = max(0, (scrollView.bounds.height - scaledH) / 2)
        scrollView.contentInset = UIEdgeInsets(top: yInset, left: xInset, bottom: yInset, right: xInset)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { pluginView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        userHasZoomed = true
    }
}

// MARK: - Mini audition keyboard

private struct AuditionKeyboard: View {
    let onNoteOn:  (UInt8) -> Void
    let onNoteOff: (UInt8) -> Void

    // Two octaves from C3 (MIDI 48) to B4 (MIDI 71)
    private static let whiteKeys: [(name: String, midi: UInt8)] = [
        ("C3",48),("D3",50),("E3",52),("F3",53),("G3",55),("A3",57),("B3",59),
        ("C4",60),("D4",62),("E4",64),("F4",65),("G4",67),("A4",69),("B4",71),
    ]
    private static let blackPattern = [true, true, false, true, true, true, false,
                                       true, true, false, true, true, true, false]
    // black key midi offsets from white key index
    private static let blackMidi: [UInt8?] = [
        49,51,nil,54,56,58,nil,
        61,63,nil,66,68,70,nil,
    ]

    var body: some View {
        GeometryReader { geo in
            let wCount = Self.whiteKeys.count
            let wWidth = geo.size.width / CGFloat(wCount)
            let wHeight = geo.size.height
            ZStack(alignment: .topLeading) {
                // White keys
                HStack(spacing: 1) {
                    ForEach(0..<wCount, id: \.self) { i in
                        let midi = Self.whiteKeys[i].midi
                        KeyButton(midi: midi, isBlack: false,
                                  width: wWidth - 1, height: wHeight,
                                  onNoteOn: onNoteOn, onNoteOff: onNoteOff)
                    }
                }
                // Black keys
                ForEach(0..<wCount, id: \.self) { i in
                    if let bMidi = Self.blackMidi[i] {
                        let xOffset = CGFloat(i) * wWidth + wWidth * 0.6
                        KeyButton(midi: bMidi, isBlack: true,
                                  width: wWidth * 0.7, height: wHeight * 0.6,
                                  onNoteOn: onNoteOn, onNoteOff: onNoteOff)
                            .offset(x: xOffset)
                    }
                }
            }
        }
    }
}

private struct KeyButton: View {
    let midi: UInt8
    let isBlack: Bool
    let width: CGFloat
    let height: CGFloat
    let onNoteOn:  (UInt8) -> Void
    let onNoteOff: (UInt8) -> Void
    @State private var pressed = false

    private var noteName: String {
        let names = ["C", "C sharp", "D", "D sharp", "E", "F",
                     "F sharp", "G", "G sharp", "A", "A sharp", "B"]
        return "\(names[Int(midi) % 12]) \(Int(midi) / 12 - 1)"
    }

    var body: some View {
        Rectangle()
            .fill(pressed
                  ? (isBlack ? Color.gray : Color.accentColor.opacity(0.4))
                  : (isBlack ? Color.black : Color.white))
            .frame(width: width, height: height)
            .overlay(Rectangle().stroke(Color.gray.opacity(0.4), lineWidth: 0.5))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            onNoteOn(midi)
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        onNoteOff(midi)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(noteName)
            .accessibilityValue(pressed ? "Playing" : "Ready")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                guard !pressed else { return }
                pressed = true
                onNoteOn(midi)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard pressed else { return }
                    pressed = false
                    onNoteOff(midi)
                }
            }
            .onDisappear {
                if pressed {
                    pressed = false
                    onNoteOff(midi)
                }
            }
    }
}

// MARK: - Plugin Editor Sheet

struct PluginEditorView: View {
    let trackID: UUID
    let trackName: String
    /// Called when the native plugin UI is about to close, so the host document
    /// (pattern or song) can capture the plugin's current state into its model.
    var onCommitState: (() -> Void)? = nil
    /// Re-instantiate this track's instrument. Recovery when the hosted plugin view
    /// comes up blank because its out-of-process scene or extension died.
    var onReload: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var auUnit: AUAudioUnit? = nil
    @State private var usePresetFallback = false
    @State private var factoryPresets: [AUAudioUnitPreset] = []
    @State private var userPresets:    [AUAudioUnitPreset] = []
    @State private var currentPreset:  AUAudioUnitPreset?  = nil
    @State private var showPresets = false
    /// The editor owns exactly ONE suspension of this track. Both onViewReady and
    /// onDisappear can fire, so the release is guarded — an extra resume would lift
    /// somebody else's gate (e.g. an in-flight plugin load) and let MIDI reach a
    /// half-instantiated plugin. See AudioEngineManager.suspendCounts.
    @State private var releasedSuspension = false
    /// Changing this rebuilds AUPluginView so a reloaded instrument gets a fresh hosted
    /// view. Without it the editor kept showing the OLD unit's dead view after a reload,
    /// which is why Reload appeared to do nothing while Done + reopen worked.
    @State private var reloadToken = UUID()
    @State private var isReloading = false

    // The audio engine is a shared singleton, so the editor needs no store.
    private var engine: AudioEngineManager { .shared }
    private var avUnit: AVAudioUnit? { engine.auv3Unit(for: trackID) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Main content area
                Group {
                    if avUnit == nil {
                        noPluginPlaceholder
                    } else if usePresetFallback {
                        presetFallback
                    } else if let au = auUnit {
                        AUPluginView(
                            audioUnit: au,
                            onNoUI: { usePresetFallback = true; loadPresets() },
                            onWillDisappear: { onCommitState?() },
                            // Its UI is built — safe to send MIDI again. Small settle
                            // delay because view construction continues briefly after
                            // endAppearanceTransition (image/asset loading).
                            onViewReady: {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    releaseSuspension()
                                }
                            }
                        )
                        .id(reloadToken)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Audition keyboard strip
                if avUnit != nil {
                    Divider()
                    AuditionKeyboard(
                        onNoteOn:  { midi in engine.playNote(trackID: trackID, midiNote: midi, velocity: 100) },
                        onNoteOff: { midi in engine.stopNote(trackID: trackID, midiNote: midi) }
                    )
                    .frame(height: 72)
                    .padding(.horizontal, 2)
                    .padding(.bottom, 4)
                }
            }
            .navigationTitle(trackName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Only show our preset picker in fallback mode — when the native
                // plugin UI is shown it has its own preset management built in.
                if usePresetFallback && (!factoryPresets.isEmpty || !userPresets.isEmpty) {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Presets") { showPresets = true }
                    }
                }
                if onReload != nil {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            // Re-instantiate, then re-bind to the NEW unit and rebuild the
                            // hosted view in place. Previously this dismissed the editor
                            // while the view kept pointing at the retired unit.
                            isReloading = true
                            auUnit = nil
                            usePresetFallback = false
                            onReload?()
                            DispatchQueue.main.asyncAfter(
                                deadline: .now() + AudioEngineManager.instrumentSettleDelay + 0.5
                            ) {
                                reloadToken = UUID()
                                setup()
                                isReloading = false
                            }
                        } label: {
                            Label("Reload", systemImage: "arrow.clockwise")
                        }
                        .disabled(isReloading)
                        .help("Rebuild this instrument if its interface is blank")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Gate MIDI to this track while the plugin builds its UI. A plugin constructing
        // its view controller is not ready to handle MIDI: GeoShred segfaults in
        // PerformanceHandler_runMidiEvent (null handler) on its render thread while its
        // main thread is still in loadViewIfRequired. Resumed by onViewReady above, and
        // unconditionally on disappear so a track can never be left silent.
        .onAppear {
            releasedSuspension = false
            engine.suspendTrack(trackID)
            // Quieten our own main-thread/CoreAnimation work while the plugin builds
            // its (out-of-process) UI — a heavy plugin can otherwise fail to establish
            // its hosted scene and come up blank.
            engine.telemetryPaused = true
            setup()
        }
        .onDisappear {
            engine.telemetryPaused = false
            releaseSuspension()
        }
        .sheet(isPresented: $showPresets) { presetSheet }
    }

    /// Release the editor's single suspension, at most once.
    private func releaseSuspension() {
        guard !releasedSuspension else { return }
        releasedSuspension = true
        engine.resumeTrack(trackID)
    }

    // MARK: - Preset fallback

    private var presetFallback: some View {
        Group {
            if factoryPresets.isEmpty && userPresets.isEmpty {
                noPresetsPlaceholder
            } else {
                presetList
            }
        }
    }

    private var presetList: some View {
        List {
            if !factoryPresets.isEmpty {
                Section("Factory Presets") {
                    ForEach(factoryPresets, id: \.number) { presetRow($0) }
                }
            }
            if !userPresets.isEmpty {
                Section("User Presets") {
                    ForEach(userPresets, id: \.number) { presetRow($0) }
                }
            }
        }
    }

    private func presetRow(_ preset: AUAudioUnitPreset) -> some View {
        Button { apply(preset) } label: {
            HStack {
                Text(preset.name).foregroundStyle(.primary)
                Spacer()
                if currentPreset?.number == preset.number {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var presetSheet: some View {
        NavigationStack {
            presetList
                .navigationTitle("Presets")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showPresets = false }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Placeholders

    private var noPluginPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Plugin not loaded").font(.headline)
            Text("Close this sheet and reopen the track to reload the plugin.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noPresetsPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No presets available").font(.headline)
            Text("This plugin doesn't expose presets.\nOpen the plugin's own app to configure sounds, then return here — your settings will be saved with the pattern.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Setup

    private func setup() {
        guard let av = avUnit else { return }
        // Only grab the audio unit here. Reading preset lists eagerly pokes the plugin's
        // preset machinery, which can destabilise fragile plugins (GeoShred) — defer it
        // to loadPresets(), called only when we actually show the preset fallback.
        auUnit = av.auAudioUnit
    }

    private func loadPresets() {
        guard let au = auUnit else { return }
        factoryPresets = au.factoryPresets ?? []
        currentPreset  = au.currentPreset
        if #available(iOS 13, *) {
            userPresets = au.userPresets
        }
    }

    private func apply(_ preset: AUAudioUnitPreset) {
        guard let au = auUnit else { return }
        au.currentPreset = preset
        currentPreset = preset
    }
}
