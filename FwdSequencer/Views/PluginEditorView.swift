import SwiftUI
import AVFoundation
import AudioToolbox
import UIKit

// MARK: - UIViewControllerRepresentable wrapper

private struct AUPluginView: UIViewControllerRepresentable {
    let audioUnit: AUAudioUnit
    var onNoUI: (() -> Void)?
    var onWillDisappear: (() -> Void)?

    func makeUIViewController(context: Context) -> AUPluginHostController {
        AUPluginHostController(audioUnit: audioUnit, onNoUI: onNoUI, onWillDisappear: onWillDisappear)
    }

    func updateUIViewController(_ uiViewController: AUPluginHostController, context: Context) {}
}

final class AUPluginHostController: UIViewController, UIScrollViewDelegate {
    private let audioUnit: AUAudioUnit
    private var onNoUI: (() -> Void)?
    private var onWillDisappear: (() -> Void)?
    private var pluginView: UIView?
    private let scrollView = UIScrollView()
    private var userHasZoomed = false

    init(audioUnit: AUAudioUnit, onNoUI: (() -> Void)?, onWillDisappear: (() -> Void)?) {
        self.audioUnit = audioUnit
        self.onNoUI = onNoUI
        self.onWillDisappear = onWillDisappear
        super.init(nibName: nil, bundle: nil)
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

        AUViewControllerHelper.requestViewController(for: audioUnit) { [weak self] vc in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let vc else { self.onNoUI?(); return }
                self.embed(vc)
            }
        }
    }

    private func embed(_ vc: UIViewController) {
        addChild(vc)
        let pv = vc.view!
        let declared = vc.preferredContentSize

        var size = declared
        if size.width < 100 || size.height < 100 {
            size = CGSize(width: 800, height: 600)
        }
        pv.translatesAutoresizingMaskIntoConstraints = true
        pv.frame = CGRect(origin: .zero, size: size)
        vc.beginAppearanceTransition(true, animated: false)
        scrollView.addSubview(pv)
        scrollView.contentSize = size
        pluginView = pv
        vc.didMove(toParent: self)
        vc.endAppearanceTransition()
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
    }
}

// MARK: - Plugin Editor Sheet

struct PluginEditorView: View {
    let trackID: UUID
    let trackName: String
    /// Called when the native plugin UI is about to close, so the host document
    /// (pattern or song) can capture the plugin's current state into its model.
    var onCommitState: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var auUnit: AUAudioUnit? = nil
    @State private var usePresetFallback = false
    @State private var factoryPresets: [AUAudioUnitPreset] = []
    @State private var userPresets:    [AUAudioUnitPreset] = []
    @State private var currentPreset:  AUAudioUnitPreset?  = nil
    @State private var showPresets = false

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
                            onNoUI: { usePresetFallback = true },
                            onWillDisappear: { onCommitState?() }
                        )
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { setup() }
        .sheet(isPresented: $showPresets) { presetSheet }
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
        let au = av.auAudioUnit
        auUnit = au
        factoryPresets = au.factoryPresets ?? []
        currentPreset  = au.currentPreset
        if #available(iOS 13, *) {
            userPresets = (try? au.userPresets) ?? []
        }
    }

    private func apply(_ preset: AUAudioUnitPreset) {
        guard let au = auUnit else { return }
        au.currentPreset = preset
        currentPreset = preset
    }
}
