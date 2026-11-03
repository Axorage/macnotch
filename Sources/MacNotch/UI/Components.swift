import SwiftUI

/// Button style with hover + pressed fills (no pointing hand, per spec).
struct IslandButtonStyle: ButtonStyle {
    var radius: CGFloat = 8
    var hovering: Bool
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(configuration.isPressed ? palette.fillPressed : (hovering ? palette.fillHover : .clear))
            )
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Wrapper that tracks hover for IslandButtonStyle.
struct HoverButton<Label: View>: View {
    var radius: CGFloat = 8
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(IslandButtonStyle(radius: radius, hovering: hovering && enabled))
            .onHover { h in withAnimation(Motion.hover) { hovering = h } }
    }
}

struct IconButton: View {
    let symbol: String
    var size: CGFloat = 13
    var frame: CGFloat = Metrics.minHit
    let label: String
    var hint: String?
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        HoverButton(radius: frame / 2, action: action) {
            Image(systemName: symbol)
                .font(Typo.symbol(size))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(palette.textPrimary)
                .frame(width: frame, height: frame)
        }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
    }
}

/// Compact empty / error state, centered in the notes pane (docs/DESIGN.md 5.6).
struct StateView: View {
    let symbol: String?
    var symbolColor: Color?
    let title: String
    let message: String
    var buttons: [(String, () -> Void)] = []
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(symbolColor ?? palette.textSecondary)
                    .accessibilityHidden(true)
            }
            Text(title).font(Typo.rowTitle).foregroundStyle(palette.textPrimary)
            Text(message)
                .font(Typo.snippet)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 300)
            if !buttons.isEmpty {
                HStack(spacing: Space.s) {
                    ForEach(Array(buttons.enumerated()), id: \.offset) { i, b in
                        TextButton(title: b.0, prominent: i == 0, action: b.1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

struct TextButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        HoverButton(radius: 7, action: action) {
            Text(title)
                .font(Typo.button)
                .foregroundStyle(prominent ? Color.black : palette.textPrimary)
                .padding(.horizontal, Space.m)
                .frame(minHeight: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? Color.white : Color.white.opacity(0.12)))
        }
    }
}

/// Primary round button (Start / Pause). Filled with the phase accent while a timer is active.
struct PrimaryRoundButton: View {
    let symbol: String
    let fill: Color
    let label: String
    var value: String = ""
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Typo.symbol(16))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.black)
                .frame(width: Metrics.primaryButton, height: Metrics.primaryButton)
                .background(Circle().fill(fill))
                .overlay(Circle().fill(Color.white.opacity(hovering ? 0.18 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// Spring press feedback (scale 0.96) with no background of its own.
struct PressScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Fade + slide up 6 pt, staggered by `index`. Reduce Motion: opacity only.
struct Entrance: ViewModifier {
    let index: Int
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : Motion.entranceOffset)
            .animation(Motion.entrance.delay(Motion.entranceDelay + Double(index) * Motion.stagger), value: shown)
    }
}
extension View {
    func entrance(_ index: Int, shown: Bool) -> some View { modifier(Entrance(index: index, shown: shown)) }
}

/// Island content presence: before (0.85, blur 8) -> shown -> after (0.92, blur 6), anchored at the top.
/// Reduce Motion: opacity only. Blur radius is 0 at rest.
struct IslandContentEffect: ViewModifier {
    let phase: ContentPhase
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(phase == .shown ? 1 : 0)
            .scaleEffect(reduceMotion ? 1 : (phase == .before ? 0.85 : (phase == .after ? 0.92 : 1)), anchor: .top)
            .blur(radius: reduceMotion ? 0 : (phase == .before ? 8 : (phase == .after ? 6 : 0)))
            .allowsHitTesting(phase == .shown)
    }
}
extension View {
    func islandContent(_ phase: ContentPhase, reduceMotion: Bool) -> some View {
        modifier(IslandContentEffect(phase: phase, reduceMotion: reduceMotion))
    }
}
