import SwiftUI

/// How one piano key looks, shared by every keyboard in the app — the note-pool
/// keyboard on each track, the Play dock, and the plugin editor's audition keys — so
/// they read as the same instrument and a change to the look happens in one place.
///
/// Drawn rather than flat-filled: a key is lit from above, so each face is a vertical
/// gradient; white keys end in a lip and black keys have a raised top face inside a
/// darker body, with a shadow cast onto the white keys beside them. A held key is
/// drawn pressed down — darker and with its lip gone — as a real key travels.
///
/// Deliberately cheap. The note-pool keyboard redraws on every playing-note change
/// during playback, 88 keys at a time, so the depth comes from gradients and plain
/// shapes; there are no blurred shadows or offscreen effects.
struct PianoKeyFace: View {
    enum Tint: Equatable {
        /// An ordinary key.
        case natural
        /// Outside the selected scale: present but receding.
        case dimmed
        /// Selected, sounding or held — the colour carries the meaning.
        case colored(Color)
    }

    let isBlack: Bool
    var tint: Tint = .natural
    /// Drawn pushed down. Independent of tint, so a held key can also be coloured.
    var pressed: Bool = false
    /// The key's size. Every caller already knows it, so it is passed in rather than
    /// measured: a GeometryReader per key was 88 extra layout passes each time the
    /// note-pool keyboard redrew during playback.
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Group {
            if isBlack { blackKey } else { whiteKey }
        }
        .frame(width: width, height: height)
    }

    // MARK: Colours
    //
    // Every key is one SOLID base colour with the same light laid over it, so a
    // selected, sounding or dimmed key is lit exactly like an ordinary one and only
    // the colour changes. Translucent fills were avoided: a black key drawn see-
    // through would let the white keys beneath show and wash it out.

    private var base: Color {
        switch tint {
        case .natural:        return isBlack ? Color(white: 0.07) : Color(red: 0.99, green: 0.99, blue: 0.97)
        case .dimmed:         return isBlack ? Color(white: 0.42) : Color(white: 0.70)
        case .colored(let c): return c
        }
    }

    // MARK: White

    private var whiteKey: some View {
        let lip = pressed ? 0 : min(6, height * 0.045)
        return ZStack(alignment: .bottom) {
                // The front edge of the key, seen below the top face: the base colour
                // in shade. Gone when pressed — the key has travelled down.
                KeyShape(radius: 4).fill(base)
                KeyShape(radius: 4).fill(Color.black.opacity(0.22))
                // The top face: lit from above and in front, so darker at the back
                // where it runs under the fallboard and brightest towards the player.
                Group {
                    KeyShape(radius: 4).fill(base)
                    KeyShape(radius: 4).fill(LinearGradient(
                        colors: [Color.black.opacity(pressed ? 0.22 : 0.12),
                                 Color.black.opacity(pressed ? 0.10 : 0.0),
                                 Color.white.opacity(pressed ? 0 : 0.10)],
                        startPoint: .top, endPoint: .bottom))
                }
                .padding(.bottom, lip)
                // A thin highlight down the left edge, where the light catches it.
                Rectangle()
                    .fill(Color.white.opacity(pressed ? 0 : 0.55))
                    .frame(width: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, lip + 2)
            }
            .padding(.horizontal, 0.5)   // the gap between keys shows the bed behind
    }

    // MARK: Black

    private var blackKey: some View {
        let w = width, h = height
        return Group {
            // The raised top face sits inside the body, narrower and stopping short of
            // the front, which is what makes the key look like a block rather than a
            // tile. Pressed, it sinks: the face nearly fills the body.
            let side = pressed ? w * 0.06 : w * 0.12
            let front = pressed ? h * 0.03 : h * 0.10
            ZStack(alignment: .top) {
                // Shadow cast onto the white keys, down and to the right of the light.
                KeyShape(radius: 3)
                    .fill(Color.black.opacity(pressed ? 0.15 : 0.32))
                    .offset(x: w * 0.12, y: pressed ? 1 : 3)
                // The body: the sides and front of the key, in shade.
                KeyShape(radius: 3).fill(base)
                KeyShape(radius: 3).fill(LinearGradient(
                    colors: [Color.black.opacity(0.35), Color.black.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom))
                // The top face, catching the light: a sheen towards the front.
                Group {
                    KeyShape(radius: 2).fill(base)
                    KeyShape(radius: 2).fill(LinearGradient(
                        colors: [Color.white.opacity(pressed ? 0.02 : 0.06),
                                 Color.white.opacity(pressed ? 0.06 : 0.20),
                                 Color.white.opacity(pressed ? 0.04 : 0.12)],
                        startPoint: .top, endPoint: .bottom))
                }
                .padding(.horizontal, side)
                .padding(.bottom, front)
            }
        }
    }
}

/// A key outline: square at the back, where the key disappears under the fallboard,
/// rounded at the front. Spelled out because UnevenRoundedRectangle needs iOS 17 and
/// the app supports 16.6.
struct KeyShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// What sits behind and above the keys: a dark bed that shows in the gaps between
/// them, and the shadow of the fallboard falling across their backs.
struct KeyboardCase: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(white: 0.12))
            .overlay(alignment: .top) {
                LinearGradient(colors: [Color.black.opacity(0.45), Color.black.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 8)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func keyboardCase() -> some View { modifier(KeyboardCase()) }
}
