import SwiftUI

struct LinkCard: View {
    let state: SheetState

    var body: some View {
        HStack(spacing: 12) {
            platformIcon
            VStack(alignment: .leading, spacing: 3) {
                titleText
                domainText
            }
            Spacer(minLength: 0)
            thumbnailView
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Subviews

    @ViewBuilder
    private var platformIcon: some View {
        if let response = state.response {
            Image(systemName: response.sourcePlatform.sfSymbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
                .frame(width: 32, height: 32)
        }
    }

    @ViewBuilder
    private var titleText: some View {
        if let response = state.response {
            Text(response.displayTitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.tertiarySystemBackground))
                .frame(width: 180, height: 14)
                .shimmering()
        }
    }

    @ViewBuilder
    private var domainText: some View {
        if let response = state.response, let domain = response.displayDomain {
            Text(domain)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.tertiarySystemBackground))
                .frame(width: 100, height: 10)
                .shimmering()
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let response = state.response, let urlString = response.thumbnailURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color(.tertiarySystemBackground)
            }
            .frame(width: 56, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

// MARK: - Shimmer effect

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: Color(.systemBackground).opacity(0.6), location: 0.4),
                        .init(color: Color(.systemBackground).opacity(0.6), location: 0.6),
                        .init(color: .clear, location: 1)
                    ]),
                    startPoint: .init(x: phase, y: 0.5),
                    endPoint: .init(x: phase + 1, y: 0.5)
                )
                .blendMode(.plusLighter)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

private extension View {
    func shimmering() -> some View {
        modifier(ShimmerModifier())
    }
}
