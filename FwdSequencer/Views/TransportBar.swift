import SwiftUI

struct TransportBar: View {
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var showMixer = false
    @State private var savedVisible = false
    @State private var tapTimes: [Date] = []
    @State private var currentBeat: Int = 0

    private var beatCount: Int { store.project.timeSignature.numerator }

    var body: some View {
        HStack(spacing: 14) {

            // Back to browser
            Button {
                store.saveNow()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
            }
            .buttonStyle(.plain)

            Divider().frame(height: 28)

            // Rewind
            Button { store.rewind() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.body)
                    .foregroundStyle(store.isPlaying || store.isPaused ? .primary : .secondary)
            }
            .buttonStyle(.plain)

            // Play / Pause
            Button {
                if store.isPlaying      { store.pause() }
                else if store.isPaused  { store.resume() }
                else                    { store.play() }
            } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundColor(.green)
                    .frame(width: 32)
            }
            .buttonStyle(.plain)

            // Stop
            Button { store.stop() } label: {
                Image(systemName: "stop.fill")
                    .font(.body)
                    .foregroundStyle(store.isPlaying || store.isPaused ? .red : .secondary)
            }
            .buttonStyle(.plain)

            // MIDI Panic
            Button { store.midiPanic() } label: {
                Text("!")
                    .font(.body.bold())
                    .foregroundStyle(.red)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .help("MIDI Panic — all notes off")

            Divider().frame(height: 28)

            // Tempo + tap
            HStack(spacing: 6) {
                Text("BPM").font(.caption).foregroundStyle(.secondary)
                Text("\(Int(store.project.tempo))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
                Stepper("", value: $store.project.tempo, in: 40...240, step: 1)
                    .labelsHidden()
                Button("Tap") { handleTap() }
                    .font(.caption)
                    .buttonStyle(.bordered)
            }

            Divider().frame(height: 28)

            // Time Signature — fixedSize lets pickers breathe
            HStack(spacing: 2) {
                Picker("", selection: $store.project.timeSignature.numerator) {
                    ForEach([2,3,4,5,6,7,8], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Text("/")
                    .font(.body.bold())
                    .foregroundStyle(.secondary)

                Picker("", selection: $store.project.timeSignature.denominator) {
                    ForEach([2,4,8], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            Divider().frame(height: 28)

            // Beat lights + bar counter
            HStack(spacing: 8) {
                // One dot per beat — red for beat 1, green for the rest
                HStack(spacing: 4) {
                    ForEach(0..<beatCount, id: \.self) { beat in
                        let isActive = store.isPlaying && beat == currentBeat
                        let dotColor: Color = beat == 0 ? .red : .green
                        Circle()
                            .fill(isActive ? dotColor : Color.gray.opacity(0.25))
                            .frame(width: 10, height: 10)
                            .animation(.easeOut(duration: 0.08), value: isActive)
                    }
                }

                // Bar X of [stepper]
                Text("Bar")
                    .font(.caption).foregroundStyle(.secondary)
                BarCounter()
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 20, alignment: .trailing)
                Text("of")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("\(store.project.numberOfBars)",
                        value: $store.project.numberOfBars,
                        in: 1...32)
                    .labelsHidden()
                Text("\(store.project.numberOfBars)")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 20, alignment: .leading)
            }
            .onReceive(store.beatSignal) { isDownbeat in
                if isDownbeat {
                    currentBeat = 0
                } else {
                    currentBeat = (currentBeat + 1) % max(1, beatCount)
                }
            }
            .onChange(of: store.isPlaying) { playing in
                if !playing { currentBeat = 0 }
            }

            Divider().frame(height: 28)

            // Pattern name
            TextField("Pattern Name", text: $store.project.name)
                .font(.subheadline.bold())
                .multilineTextAlignment(.center)
                .frame(minWidth: 120, maxWidth: 200)

            Spacer()
                .overlay(alignment: .center) {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .opacity(savedVisible ? 1 : 0)
                        .animation(.easeInOut(duration: 0.3), value: savedVisible)
                }

            Button { showMixer = true } label: {
                Label("Mixer", systemImage: "slider.vertical.3")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .sheet(isPresented: $showMixer) {
            MixerView()
                .environmentObject(store)
                .environmentObject(store.levels)
        }
        .onReceive(store.savedSignal) {
            savedVisible = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                savedVisible = false
            }
        }
    }

    // Isolates the once-per-bar counter so the whole transport bar doesn't
    // re-render when other playback telemetry (notes/steps) changes.
    private struct BarCounter: View {
        @EnvironmentObject var playback: PlaybackMonitor
        var body: some View {
            Text("\(playback.currentBar + 1)")
        }
    }

    private func handleTap() {
        let now = Date()
        if let last = tapTimes.last, now.timeIntervalSince(last) > 2 {
            tapTimes.removeAll()
        }
        tapTimes.append(now)
        if tapTimes.count > 8 { tapTimes.removeFirst() }
        guard tapTimes.count >= 2 else { return }
        let intervals = zip(tapTimes.dropLast(), tapTimes.dropFirst())
            .map { $1.timeIntervalSince($0) }
        let avg = intervals.reduce(0, +) / Double(intervals.count)
        store.project.tempo = min(240, max(40, (60.0 / avg).rounded()))
    }
}
