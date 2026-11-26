import SwiftUI

enum Variant: String, CaseIterable { case original, blackRow, blackRowMoved, scrollView }

let pageNumber = ProcessInfo.processInfo.arguments.contains("page2") ? 1 : 0
let perPage = 3
let page: [Variant] = Array(Variant.allCases.dropFirst(pageNumber * perPage).prefix(perPage))

@main
struct HarnessApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text("iOS \(UIDevice.current.systemVersion) page \(pageNumber + 1)").font(.title2).foregroundStyle(.white)
                ForEach(page, id: \.self) { v in
                    Text(v.rawValue).foregroundStyle(.white)
                    // As in PlayDockView: padding, material, clipped.
                    PlayableKeyboard(variant: v)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                        .clipped()
                }
                Spacer()
            }
            .padding()
            .background(Color.black)
            .preferredColorScheme(.dark)
        }
    }
}

struct PlayableKeyboard: View {
    let variant: Variant
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let lowMidi = 36
    private static let highMidi = 84
    private static func isWhite(_ m: Int) -> Bool { [0,2,4,5,7,9,11].contains(m % 12) }
    private static let whiteKeys: [Int] = (lowMidi...highMidi).filter { isWhite($0) }
    private static let blackKeys: [Int] = (lowMidi...highMidi).filter { !isWhite($0) }
    private static let whiteIndex: [Int: Int] =
        Dictionary(uniqueKeysWithValues: whiteKeys.enumerated().map { ($1, $0) })
    private let whiteW: CGFloat = 70
    private let keyH: CGFloat = 132
    private var blackW: CGFloat { whiteW * 0.6 }
    private var blackH: CGFloat { keyH * 0.62 }
    private var totalW: CGFloat { CGFloat(Self.whiteKeys.count) * whiteW }
    @State private var centerC = 60
    @State private var held = Set<Int>()

    private var layout: KeyboardLayout {
        KeyboardLayout(whiteKeys: Self.whiteKeys, whiteWidth: whiteW,
                       blackKeys: Self.blackKeys.map { (midi: $0, x: blackX($0)) },
                       blackWidth: blackW, blackHeight: blackH)
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let visible = geo.size.width
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(Self.whiteKeys, id: \.self) { m in
                            PlayKey(midi: m, isBlack: false, width: whiteW, height: keyH, pressed: false)
                        }
                    }
                    if variant == .blackRow || variant == .blackRowMoved {
                        blackRow
                    } else {
                        blacks
                    }
                }
                .overlay(alignment: .topLeading) {
                    if false {
                        ZStack(alignment: .topLeading) { blacks }
                    }
                }
                .frame(width: totalW, height: keyH, alignment: .topLeading)
                .keyboardCase()
                .overlay {
                    if true {
                        KeyboardTouchSurface(keyAt: { layout.key(at: $0) },
                                             onPress: { held.insert($0) },
                                             onRelease: { held.remove($0) })
                            .accessibilityHidden(true)
                    }
                }
                .modifier(Shift(variant: variant, by: scrollOffset(visible: visible)))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: centerC)
.frame(width: visible, height: keyH, alignment: .leading)
                .clipped()
            }
            .frame(height: keyH)
        }
    }

    private static let blackAfter: Set<Int> = Set(whiteKeys.filter { !isWhite($0 + 1) && $0 + 1 <= highMidi })
    /// The black keys as one row, like the white keys: each white key's slot carries the
    /// black key that sits on its right-hand edge.
    private var blackRow: some View {
        HStack(spacing: 0) {
            ForEach(Self.whiteKeys, id: \.self) { m in
                Color.clear
                    .frame(width: whiteW, height: blackH)
                    .overlay(alignment: .topTrailing) {
                        if Self.blackAfter.contains(m) {
                            PlayKey(midi: m + 1, isBlack: true, width: blackW, height: blackH, pressed: false)
                                .offset(x: blackW / 2)
                        }
                    }
            }
        }
    }

    private var keyPadding: Bool { false }
    @ViewBuilder private var blacks: some View {
        ForEach(Self.blackKeys, id: \.self) { m in
            if keyPadding {
                PlayKey(midi: m, isBlack: true, width: blackW, height: blackH, pressed: false)
                    .padding(.leading, blackX(m))
            } else {
                PlayKey(midi: m, isBlack: true, width: blackW, height: blackH, pressed: false)
                    .offset(x: blackX(m))
            }
        }
    }

    private func scrollOffset(visible: CGFloat) -> CGFloat {
        let centre = CGFloat(Self.whiteIndex[centerC] ?? 0) * whiteW + whiteW / 2
        return min(max(0, centre - visible / 2), max(0, totalW - visible))
    }
    private func blackX(_ m: Int) -> CGFloat {
        var left = m - 1
        while left >= Self.lowMidi && !Self.isWhite(left) { left -= 1 }
        guard let idx = Self.whiteIndex[left] else { return 0 }
        return CGFloat(idx + 1) * whiteW - blackW / 2
    }
}

private struct PlayKey: View {
    let midi: Int
    let isBlack: Bool
    let width: CGFloat
    let height: CGFloat
    let pressed: Bool
    var body: some View {
        PianoKeyFace(isBlack: isBlack, tint: .natural, pressed: pressed, width: width, height: height)
            .frame(width: width, height: height)
            .accessibilityElement()
            .accessibilityLabel("\(midi)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { }
    }
}

struct TrackKeyboard: View {
    private static func isWhite(_ m: Int) -> Bool { [0,2,4,5,7,9,11].contains(m % 12) }
    private let whiteKeys = (21...108).filter { [0,2,4,5,7,9,11].contains($0 % 12) }
    private let blackKeys = (21...108).filter { ![0,2,4,5,7,9,11].contains($0 % 12) }
    private let keyH: CGFloat = 90
    var body: some View {
        GeometryReader { geo in
            let whiteW = geo.size.width / 28
            let blackW = whiteW * 0.65
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(whiteKeys, id: \.self) { _ in
                            PianoKeyFace(isBlack: false, width: whiteW, height: keyH).frame(width: whiteW, height: keyH)
                        }
                    }
                    ForEach(blackKeys, id: \.self) { m in
                        PianoKeyFace(isBlack: true, width: blackW, height: keyH * 0.62)
                            .frame(width: blackW, height: keyH * 0.62)
                            .offset(x: x(m, whiteW, blackW))
                    }
                }
                .frame(width: CGFloat(whiteKeys.count) * whiteW, height: keyH)
                .keyboardCase()
            }
        }.frame(height: keyH)
    }
    private func x(_ m: Int, _ w: CGFloat, _ bw: CGFloat) -> CGFloat {
        var l = m - 1; while !Self.isWhite(l) { l -= 1 }
        return CGFloat(whiteKeys.firstIndex(of: l)! + 1) * w - bw / 2
    }
}

struct Shift: ViewModifier {
    let variant: Variant
    let by: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        switch variant {
        case .blackRowMoved: content.offset(x: -by - 140)
        case .scrollView:
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    content.overlay(alignment: .topLeading) {
                        Color.clear.frame(width: 1, height: 1).offset(x: by).id("anchor")
                    }
                }
                .scrollDisabled(true)
                .onAppear { proxy.scrollTo("anchor", anchor: .leading) }
            }
        default: content.offset(x: -by)
        }
    }
}

struct MaybeClip: ViewModifier {
    let on: Bool
    @ViewBuilder func body(content: Content) -> some View { if on { content.clipped() } else { content } }
}
