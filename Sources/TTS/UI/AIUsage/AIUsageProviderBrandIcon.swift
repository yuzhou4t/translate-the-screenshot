import AppKit
import SwiftUI

@MainActor
struct AIUsageProviderBrandIcon: View {
    var providerID: AIUsageProviderID
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: backgroundColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let image = brandImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.20)
            } else {
                Image(systemName: providerID.systemImage)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
        }
        .shadow(color: backgroundColors.last?.opacity(0.23) ?? .clear, radius: 5, y: 2)
        .accessibilityHidden(true)
    }

    private var brandImage: NSImage? {
        AIUsageProviderIconCache.shared.image(for: providerID)
    }

    private var backgroundColors: [Color] {
        switch providerID {
        case .codex:
            [Color(red: 0.12, green: 0.14, blue: 0.16), Color(red: 0.02, green: 0.03, blue: 0.04)]
        case .grok:
            [Color(red: 0.20, green: 0.22, blue: 0.25), Color.black]
        case .deepSeek:
            [Color(red: 0.36, green: 0.52, blue: 1.00), Color(red: 0.18, green: 0.34, blue: 0.91)]
        case .miniMax:
            [Color(red: 0.20, green: 0.55, blue: 1.00), Color(red: 0.14, green: 0.32, blue: 0.82)]
        case .gemini:
            [Color(red: 0.43, green: 0.53, blue: 1.00), Color(red: 0.39, green: 0.22, blue: 0.82)]
        }
    }
}

@MainActor
private final class AIUsageProviderIconCache {
    static let shared = AIUsageProviderIconCache()

    private var images: [AIUsageProviderID: NSImage] = [:]

    func image(for providerID: AIUsageProviderID) -> NSImage? {
        if let image = images[providerID] {
            return image
        }
        let url = AIUsageProviderBrandAssets.overrideDirectoryURL?
            .appendingPathComponent("\(providerID.brandResourceName).svg")
            ?? Bundle.main.url(
                forResource: providerID.brandResourceName,
                withExtension: "svg"
            )
        guard let url, let image = NSImage(contentsOf: url) else {
            return nil
        }
        images[providerID] = image
        return image
    }
}

@MainActor
enum AIUsageProviderBrandAssets {
    static var overrideDirectoryURL: URL?
}

private extension AIUsageProviderID {
    var brandResourceName: String {
        switch self {
        case .codex: "ProviderIcon-codex"
        case .grok: "ProviderIcon-grok"
        case .deepSeek: "ProviderIcon-deepseek"
        case .miniMax: "ProviderIcon-minimax"
        case .gemini: "ProviderIcon-antigravity"
        }
    }
}
