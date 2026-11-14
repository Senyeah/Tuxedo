import SwiftUI

/// The tool pill: a dark capsule with the keys' edge, so it sits in the pad's light and not over it.
/// It holds the Lab's tools and Tuxedo's session tools; each tool is a `PadPillButtonStyle` button.
struct PadPill<Content: View>: View {
    var tuning: PadTuning
    /// nil follows the system.
    var increaseContrast: Bool?
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    init(tuning: PadTuning, increaseContrast: Bool? = nil, @ViewBuilder content: () -> Content) {
        self.tuning = tuning
        self.increaseContrast = increaseContrast
        self.content = content()
    }

    var body: some View {
        let p = tuning.pill, k = tuning.keys
        let hc = increaseContrast ?? (contrast == .increased)
        let edge = hc ? [Color.white.opacity(tuning.contrast.lineAlpha)] : [Color.white.opacity(k.topEdge), Color.white.opacity(k.bottomEdge)]
        let fill = PadTuning.rgb(p.fill)
        HStack(spacing: p.spacing) { content }
            .padding(.horizontal, p.sidePadding)
            .frame(height: p.height)
            .background(Capsule().fill(Color(.sRGB, red: fill.0, green: fill.1, blue: fill.2, opacity: p.fillAlpha)))
            .overlay(Capsule().strokeBorder(LinearGradient(colors: edge, startPoint: .top, endPoint: .bottom),
                                            lineWidth: hc ? tuning.contrast.lineWidth : k.edgeWidth))
            .buttonStyle(PadPillButtonStyle(tuning: tuning, increaseContrast: hc))
    }
}

/// A tool in the pill: a full hit target, the symbol at the keys' alpha, full white while pressed.
struct PadPillButtonStyle: ButtonStyle {
    var tuning: PadTuning
    var increaseContrast = false

    func makeBody(configuration: Configuration) -> some View {
        let p = tuning.pill
        let rest = increaseContrast ? tuning.contrast.symbolAlpha : tuning.keys.symbolAlpha
        configuration.label
            .font(.system(size: p.symbolSize, weight: .regular))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 1 : rest))
            .frame(width: p.target, height: p.target)
            .contentShape(Rectangle())
    }
}
