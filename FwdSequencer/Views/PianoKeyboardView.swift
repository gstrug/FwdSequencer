import SwiftUI

struct PianoKeyboardView: View {
    @Binding var notePool: [NoteEntry]
    let scale: MusicalScale
    var playingNote: Int? = nil
    var key: Int = 0

    @State private var scrollLock = false

    // Full 88-key range: A0 (21) – C8 (108)
    private let midiRange = 21...108
    private let keyH:   CGFloat = 140
    // Key width is derived from container size at render time (see body)

    private func isWhiteKey(_ midi: Int) -> Bool {
        [0, 2, 4, 5, 7, 9, 11].contains(midi % 12)
    }

    private var whiteKeys: [Int] { midiRange.filter { isWhiteKey($0) } }
    private var blackKeys: [Int] { midiRange.filter { !isWhiteKey($0) } }

    // Index of each white key (used to position black keys)
    private var whiteKeyIndex: [Int: Int] {
        Dictionary(uniqueKeysWithValues: whiteKeys.enumerated().map { ($1, $0) })
    }

    // X offset of a black key's leading edge within the ZStack
    private func blackKeyX(_ midi: Int, whiteW: CGFloat) -> CGFloat {
        let blackW = whiteW * 0.65
        var left = midi - 1
        while left >= 21 && !isWhiteKey(left) { left -= 1 }
        guard let idx = whiteKeyIndex[left] else { return 0 }
        return CGFloat(idx + 1) * whiteW - blackW / 2
    }

    private func isInScale(_ midi: Int) -> Bool {
        let semitone = ((midi % 12) - key + 12) % 12
        return scale.intervals.contains(semitone)
    }

    private func isSelected(_ midi: Int) -> Bool {
        notePool.contains(where: { $0.midiNote == midi })
    }

    private func toggle(_ midi: Int) {
        guard isInScale(midi) else { return }
        if let idx = notePool.firstIndex(where: { $0.midiNote == midi }) {
            notePool.remove(at: idx)
        } else {
            let entry = NoteEntry(midiNote: midi)
            let insertAt = notePool.firstIndex(where: { $0.midiNote > midi }) ?? notePool.endIndex
            notePool.insert(entry, at: insertAt)
        }
    }

    private func whiteColor(_ midi: Int) -> Color {
        if playingNote == midi { return .yellow }
        if isSelected(midi)    { return .blue }
        if !isInScale(midi)    { return Color.gray.opacity(0.25) }
        return .white
    }

    private func blackColor(_ midi: Int) -> Color {
        if playingNote == midi { return .yellow }
        if isSelected(midi)    { return .blue }
        if !isInScale(midi)    { return Color(white: 0.45) }
        return .black
    }

    var body: some View {
        // GeometryReader captures the available width so keys fill it exactly
        // as the original did for 4 octaves (28 white keys), but now the
        // scroll content extends to all 52 white keys of the full 88-key range.
        GeometryReader { geo in
            let whiteW   = geo.size.width / 28   // same visual size as original
            let blackW   = whiteW * 0.65
            let blackH   = keyH * 0.62
            let totalW   = CGFloat(whiteKeys.count) * whiteW

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        // White keys
                        HStack(spacing: 0) {
                            ForEach(whiteKeys, id: \.self) { midi in
                                Rectangle()
                                    .fill(whiteColor(midi))
                                    .frame(width: whiteW, height: keyH)
                                    .overlay(Rectangle().stroke(Color.gray.opacity(0.4), lineWidth: 0.5))
                                    .overlay(alignment: .bottom) {
                                        cMarker(midi: midi, whiteW: whiteW)
                                    }
                                    .onTapGesture { toggle(midi) }
                                    .id(midi)
                            }
                        }
                        // Black keys — absolutely positioned via offset
                        ForEach(blackKeys, id: \.self) { midi in
                            Rectangle()
                                .fill(blackColor(midi))
                                .frame(width: blackW, height: blackH)
                                .offset(x: blackKeyX(midi, whiteW: whiteW))
                                .onTapGesture { toggle(midi) }
                        }
                    }
                    .frame(width: totalW, height: keyH)
                }
                .onAppear {
                    // Small delay lets layout complete before scrolling
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo(60, anchor: .center)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Button { scrollLock.toggle() } label: {
                        Image(systemName: scrollLock ? "lock.fill" : "lock.open")
                            .font(.caption2)
                            .padding(5)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .padding(4)
                }
                .onChange(of: playingNote) { newNote in
                    guard scrollLock, let note = newNote else { return }
                    let target = isWhiteKey(note) ? note : note - 1
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
        .frame(height: keyH)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 1))
    }

    // Dot marker on every C; bold "C4" label on middle C
    @ViewBuilder
    private func cMarker(midi: Int, whiteW: CGFloat) -> some View {
        if midi % 12 == 0 {
            if midi == 60 {
                Text("C4")
                    .font(.system(size: max(7, whiteW * 0.38), weight: .bold))
                    .foregroundColor(.blue)
                    .padding(.bottom, 5)
                    .allowsHitTesting(false)
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.45))
                    .frame(width: max(5, whiteW * 0.22), height: max(5, whiteW * 0.22))
                    .padding(.bottom, 5)
                    .allowsHitTesting(false)
            }
        }
    }
}
