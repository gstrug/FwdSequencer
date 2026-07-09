import SwiftUI

struct TransportBar: View {
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var showMixer = false
    @State private var savedVisible = false
    @State private var tapTimes: [Date] = []
    @State private var beatFlash = false
    @State private var beatIsDown = false

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
                if store.isPlaying {
                    store.pause()
                } else if store.isPaused {
                    store.resume()
                } else {
                    store.play()
                }
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

            // Time Signature
            HStack(spacing: 4) {
                Text("Sig").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $store.project.timeSignature.numerator) {
                    ForEach([2,3,4,5,6,7,8], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 44)
                .clipped()
                Text("/").foregroundStyle(.secondary)
                Picker("", selection: $store.project.timeSignature.denominator) {
                    ForEach([2,4,8], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 44)
                .clipped()
            }

            Divider().frame(height: 28)

            // Bars — beat indicator, bar counter, and bars stepper
            HStack(spacing: 6) {
                Circle()
                    .fill(beatFlash
                          ? (beatIsDown ? Color.red : Color.green)
                          : Color.gray.opacity(0.25))
                    .frame(width: 10, height: 10)
                    .animation(.easeOut(duration: 0.1), value: beatFlash)

                Text("Bar").font(.caption).foregroundStyle(.secondary)
                Text("\(store.currentBar + 1)").font(.caption.monospacedDigit())
                Text("of").font(.caption).foregroundStyle(.secondary)

                Stepper("\(store.project.numberOfBars)",
                        value: $store.project.numberOfBars,
                        in: 1...32)
            }
            .onReceive(store.beatSignal) { isDownbeat in
                beatIsDown = isDownbeat
                beatFlash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    beatFlash = false
                }
            }

            Divider().frame(height: 28)

            // Project name
            TextField("Project Name", text: $store.project.name)
                .font(.subheadline.bold())
                .multilineTextAlignment(.center)
                .frame(minWidth: 120, maxWidth: 200)

            Spacer()

            if savedVisible {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }

            Button {
                showMixer = true
            } label: {
                Label("Mixer", systemImage: "slider.vertical.3")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .sheet(isPresented: $showMixer) {
            MixerView().environmentObject(store)
        }
        .onReceive(store.savedSignal) {
            withAnimation { savedVisible = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { savedVisible = false }
            }
        }
    }

    private func handleTap() {
        let now = Date()
        // Reset if more than 2 seconds since last tap
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
