import SwiftUI

// MARK: - Article Card
//
// Renders a structured-summary article: one composed sentence broken into
// segments where three load-bearing phrases are emphasized (bold serif +
// warm underline + an inline numbered badge). Mirrors the reference design.
//
// Drawn instead of HomeCard when `link.summarySegments != nil`. Sizing and
// tap handling are wired to match HomeCard so the wheel behaves identically.

struct ArticleCard: View {
    let link: IngestResponse
    let categoryColor: Color
    let cardWidth: CGFloat
    let cardHeight: CGFloat

    @Environment(\.openURL) private var openURL

    private static let cardCorner: CGFloat = 28
    private static let cardFill = Color(red: 0.969, green: 0.949, blue: 0.918)  // warm cream
    private static let emphasisColor = Color(red: 0.92, green: 0.55, blue: 0.18)  // amber/orange
    private static let connectiveColor = Color(white: 0.45)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 26)
                .padding(.top, 22)
                .padding(.bottom, 14)

            sentence
                .padding(.horizontal, 26)

            Spacer(minLength: 18)

            Divider()
                .opacity(0.35)

            readFullArticleButton
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
        }
        .frame(width: cardWidth, height: cardHeight)
        .background {
            RoundedRectangle(cornerRadius: Self.cardCorner, style: .continuous)
                .fill(Self.cardFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.cardCorner, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: categoryColor.opacity(0.22), radius: 28, y: 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Header (domain · reading-time placeholder)

    private var header: some View {
        HStack(spacing: 8) {
            if let domain = link.displayDomain {
                Text(domain.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(link.displayTitle)
                .font(.system(size: 11, weight: .regular, design: .serif))
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: Sentence — the hero

    private var sentence: some View {
        // Concatenate every segment as a Text so wrapping is native and the
        // numbered badges sit on the baseline as inline glyph attachments.
        var composed: Text = Text("")
        let segments = link.summarySegments ?? []
        for (idx, seg) in segments.enumerated() {
            if let emphasis = seg.emphasis, (1...3).contains(emphasis) {
                // Inline numbered badge (uses SF Symbols 1/2/3 .circle.fill).
                let badge = Text(Image(systemName: "\(emphasis).circle.fill"))
                    .foregroundColor(Self.emphasisColor)
                let leadingSpace = idx == 0 ? Text("") : Text(" ")
                let phrase = Text(seg.text)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .underline(true, color: Self.emphasisColor)
                composed = composed + leadingSpace + badge + Text(" ") + phrase
            } else {
                composed = composed + Text(seg.text).foregroundColor(Self.connectiveColor)
            }
        }
        return composed
            .font(.system(.title3, design: .serif))
            .lineSpacing(6)
            .multilineTextAlignment(.leading)
            .minimumScaleFactor(0.85)
    }

    // MARK: Read-full-article pill

    private var readFullArticleButton: some View {
        Button {
            if let url = URL(string: link.canonicalURL) {
                openURL(url)
            }
        } label: {
            HStack(spacing: 6) {
                Text("Read full article")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(Color.black.opacity(0.05))
            }
            .contentShape(Capsule().inset(by: -6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Read full article in browser")
    }

    // MARK: Accessibility

    private var accessibilityText: String {
        let stitched = (link.summarySegments ?? []).map(\.text).joined()
        return "\(link.displayTitle). Summary: \(stitched)"
    }
}
