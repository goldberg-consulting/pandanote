import SwiftUI

/// The entire rendered label is the target, including its padding and spacers.
struct RegionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Region(configuration: configuration) }
    private struct Region: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .frame(minHeight: 24)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(enabled && configuration.isPressed ? 0.12 : enabled && hovering ? 0.055 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(enabled && hovering ? 0.10 : 0), lineWidth: 1).allowsHitTesting(false))
                .onHover { hovering = $0 }
        }
    }
}
