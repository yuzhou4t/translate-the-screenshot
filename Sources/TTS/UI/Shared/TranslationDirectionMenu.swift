import AppKit
import SwiftUI

struct TranslationDirectionMenu: View {
    @Binding var selection: TranslationDirection
    var width: CGFloat?

    var body: some View {
        Menu {
            ForEach(TranslationDirection.allCases) { direction in
                Button {
                    selection = direction
                } label: {
                    menuLabel(for: direction)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(selection.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(width: width, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(NSColor.separatorColor).opacity(0.45), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func menuLabel(for direction: TranslationDirection) -> some View {
        if direction == selection {
            Label(direction.displayName, systemImage: "checkmark")
        } else {
            Text(direction.displayName)
        }
    }
}
