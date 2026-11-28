import SwiftUI

extension ShipKit {
    /// A static thumbs up / thumbs down row for a feature. Shows the user's existing score and
    /// only sends a rating when they tap.
    public struct RatingRow: View {
        private let feature: String
        private let title: String?
        @State private var score: Int?
        @State private var sending = false

        public init(feature: String, title: String? = nil) {
            self.feature = feature
            self.title = title
        }

        public var body: some View {
            HStack(spacing: 12) {
                Text(title ?? L("rating.prompt"))
                    .font(.subheadline)
                Spacer(minLength: 8)
                thumb(up: true)
                thumb(up: false)
            }
            .task(id: feature) {
                guard let engine = ShipKit.engine else { return }
                if let existing = try? await engine.myRating(feature: feature) {
                    score = existing
                }
            }
            .accessibilityElement(children: .contain)
        }

        private func thumb(up: Bool) -> some View {
            let value = up ? 5 : 1
            let selected = score.map { up ? $0 >= 4 : $0 <= 2 } ?? false
            return Button {
                rate(value)
            } label: {
                Image(systemName: up ? (selected ? "hand.thumbsup.fill" : "hand.thumbsup") : (selected ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
                    .font(.title3)
                    .foregroundStyle(selected ? ShipKit.theme.primaryColor : Color.secondary)
                    .frame(width: 36, height: 36)
                    .symbolEffectIfAvailable(value: selected)
            }
            .skBorderlessButton()
            .disabled(sending)
            .accessibilityLabel(L(up ? "rating.up" : "rating.down"))
            .accessibilityAddTraits(selected ? .isSelected : [])
        }

        private func rate(_ value: Int) {
            guard let engine = ShipKit.engine, score != value else { return }
            let previous = score
            score = value
            sending = true
            Task {
                do {
                    try await engine.rate(feature: feature, score: value)
                } catch {
                    score = previous
                }
                sending = false
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func skBorderlessButton() -> some View {
        #if os(tvOS)
        buttonStyle(.plain)
        #else
        buttonStyle(.borderless)
        #endif
    }

    @ViewBuilder
    func symbolEffectIfAvailable(value: Bool) -> some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, *) {
            symbolEffect(.bounce, value: value)
        } else {
            self
        }
    }
}
