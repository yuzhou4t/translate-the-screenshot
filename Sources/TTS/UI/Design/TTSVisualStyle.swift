import AppKit
import SwiftUI

enum TTSVisualStyle {
    static let accent = Color(nsColor: .ttsAccent)
    static let accentStrong = Color(nsColor: .ttsAccentStrong)
    static let surface = Color(nsColor: .ttsGlassSurface)
    static let raisedSurface = Color(nsColor: .ttsRaisedSurface)
    static let controlSurface = Color(nsColor: .ttsControlSurface)
    static let border = Color(nsColor: .ttsGlassBorder)
    static let subtleBorder = Color(nsColor: .ttsSubtleBorder)

    static let windowRadius: CGFloat = 20
    static let panelRadius: CGFloat = 16
    static let controlRadius: CGFloat = 10
}

struct TTSWindowBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.035, green: 0.082, blue: 0.145), Color(red: 0.055, green: 0.145, blue: 0.245)]
                    : [Color(red: 0.945, green: 0.975, blue: 1), Color(red: 0.835, green: 0.915, blue: 1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [TTSVisualStyle.accent.opacity(colorScheme == .dark ? 0.18 : 0.14), .clear],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 520
            )

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(colorScheme == .dark ? 0.48 : 0.6)
        }
        .ignoresSafeArea()
    }
}

private struct TTSGlassSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat
    var elevated: Bool

    func body(content: Content) -> some View {
        content
            .background(.thinMaterial)
            .background(TTSVisualStyle.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(TTSVisualStyle.border, lineWidth: 1)
            }
            .shadow(
                color: Color.black.opacity(elevated ? 0.16 : 0.08),
                radius: elevated ? 22 : 10,
                x: 0,
                y: elevated ? 12 : 5
            )
    }
}

extension View {
    func ttsGlassSurface(
        cornerRadius: CGFloat = TTSVisualStyle.panelRadius,
        elevated: Bool = false
    ) -> some View {
        modifier(TTSGlassSurfaceModifier(cornerRadius: cornerRadius, elevated: elevated))
    }

    func ttsTintedControl(cornerRadius: CGFloat = TTSVisualStyle.controlRadius) -> some View {
        background(TTSVisualStyle.controlSurface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(TTSVisualStyle.subtleBorder, lineWidth: 1)
            }
    }
}

struct TTSPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 13)
            .frame(minHeight: 32)
            .background {
                LinearGradient(
                    colors: [TTSVisualStyle.accent, TTSVisualStyle.accentStrong],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.38)
            }
            .clipShape(RoundedRectangle(cornerRadius: TTSVisualStyle.controlRadius, style: .continuous))
            .shadow(
                color: TTSVisualStyle.accent.opacity(isEnabled ? 0.22 : 0),
                radius: configuration.isPressed ? 3 : 8,
                y: configuration.isPressed ? 1 : 4
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct TTSSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.6))
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(configuration.isPressed ? TTSVisualStyle.accent.opacity(0.13) : TTSVisualStyle.controlSurface)
            .clipShape(RoundedRectangle(cornerRadius: TTSVisualStyle.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: TTSVisualStyle.controlRadius, style: .continuous)
                    .stroke(TTSVisualStyle.subtleBorder, lineWidth: 1)
            }
    }
}

extension NSColor {
    static let ttsAccent = ttsDynamic(
        light: NSColor(calibratedRed: 0.25, green: 0.49, blue: 0.96, alpha: 1),
        dark: NSColor(calibratedRed: 0.40, green: 0.65, blue: 1, alpha: 1)
    )

    static let ttsAccentStrong = ttsDynamic(
        light: NSColor(calibratedRed: 0.13, green: 0.38, blue: 0.86, alpha: 1),
        dark: NSColor(calibratedRed: 0.31, green: 0.57, blue: 0.98, alpha: 1)
    )

    static let ttsGlassSurface = ttsDynamic(
        light: NSColor(calibratedWhite: 1, alpha: 0.76),
        dark: NSColor(calibratedRed: 0.065, green: 0.13, blue: 0.22, alpha: 0.78)
    )

    static let ttsRaisedSurface = ttsDynamic(
        light: NSColor(calibratedRed: 0.965, green: 0.985, blue: 1, alpha: 0.78),
        dark: NSColor(calibratedRed: 0.085, green: 0.17, blue: 0.28, alpha: 0.82)
    )

    static let ttsControlSurface = ttsDynamic(
        light: NSColor(calibratedRed: 0.93, green: 0.965, blue: 1, alpha: 0.82),
        dark: NSColor(calibratedRed: 0.10, green: 0.21, blue: 0.35, alpha: 0.86)
    )

    static let ttsGlassBorder = ttsDynamic(
        light: NSColor(calibratedRed: 0.68, green: 0.80, blue: 0.94, alpha: 0.62),
        dark: NSColor(calibratedRed: 0.40, green: 0.65, blue: 1, alpha: 0.26)
    )

    static let ttsSubtleBorder = ttsDynamic(
        light: NSColor(calibratedRed: 0.68, green: 0.78, blue: 0.89, alpha: 0.48),
        dark: NSColor(calibratedRed: 0.48, green: 0.65, blue: 0.84, alpha: 0.26)
    )

    private static func ttsDynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

@MainActor
final class TTSGlassEffectView: NSVisualEffectView {
    var ttsCornerRadius: CGFloat = TTSVisualStyle.panelRadius {
        didSet {
            updateTTSAppearance()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTTSAppearance()
    }

    private func configure() {
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        updateTTSAppearance()
    }

    private func updateTTSAppearance() {
        layer?.cornerRadius = ttsCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.ttsGlassBorder.cgColor
        layer?.backgroundColor = NSColor.ttsGlassSurface.cgColor
    }
}
