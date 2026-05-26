import SwiftUI
import WebKit
import SafariServices
import CoreImage
import UIKit

// MARK: - Flippable detail container (round 9)

struct FlippableDetailContainer: View {
    let link: IngestResponse
    let categoryColor: Color
    let sourceFrame: CGRect          // global coords of the home card at tap time
    let onDismiss: () -> Void

    // Entry runs phases 0 → 1; exit runs them 1 → 0. Same spring, same timing.
    @State private var flipPhase: Double = 0   // 0 = thumbnail side, 1 = detail side
    @State private var sizePhase: Double = 0   // 0 = at sourceFrame, 1 = full screen
    // Sampled gradient from the thumbnail. nil before async load completes — fall
    // back to categoryColor gradient in that window.
    @State private var sampledColors: [Color]? = nil
    // Drives the gradient card's opacity to 0 during exit so the real home card
    // (with the actual thumbnail) shows through underneath.
    @State private var cardFadeOut: Double = 0
    @State private var isDismissing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Snappy spring: ~450ms one-way, no bounce.
    private let spring: Animation = .spring(response: 0.35, dampingFraction: 0.85)

    var body: some View {
        // Outer ZStack does NOT ignore safe area, so topControlsBar lays out below the
        // Dynamic Island automatically. Only the inner GeometryReader (backdrop + rotating
        // detail + card-front) ignores safe area, since it needs to fill the full screen.
        ZStack(alignment: .top) {
            GeometryReader { screen in
                let screenSize = screen.size

                ZStack {
                    // Dim layer — tap target, fades in with sizePhase during open.
                    Color.black.opacity(0.55 * sizePhase)
                        .onTapGesture { dismiss() }

                    LinkDetailView(link: link, categoryColor: categoryColor)
                        .opacity(flipPhase >= 0.5 ? 1 : 0)
                        .animation(nil, value: flipPhase >= 0.5)
                        .rotation3DEffect(
                            .degrees(flipPhase * 180 - 180),
                            axis: (x: 0, y: 1, z: 0),
                            perspective: 0.6
                        )

                    cardFront
                        .frame(
                            width: lerp(sourceFrame.width, screenSize.width, sizePhase),
                            height: lerp(sourceFrame.height, screenSize.height, sizePhase)
                        )
                        .position(
                            x: lerp(sourceFrame.midX, screenSize.width / 2, sizePhase),
                            y: lerp(sourceFrame.midY, screenSize.height / 2, sizePhase)
                        )
                        .opacity((flipPhase < 0.5 ? 1 : 0) * (1 - cardFadeOut))
                        .animation(nil, value: flipPhase < 0.5)
                        .rotation3DEffect(
                            .degrees(flipPhase * 180),
                            axis: (x: 0, y: 1, z: 0),
                            perspective: 0.6
                        )
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()

            topControlsBar
                .opacity(flipPhase >= 0.85 ? 1 : 0)
        }
        .onAppear {
            withAnimation(reduceMotion ? .linear(duration: 0.01) : spring) {
                flipPhase = 1
                sizePhase = 1
            }
            Task { await sampleThumbnailColors() }
        }
    }

    private var topControlsBar: some View {
        HStack {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .offset(x: -1)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
                .accessibilityLabel("Close")
                .accessibilityAddTraits(.isButton)

            Spacer()

            if let url = URL(string: link.canonicalURL) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .offset(y: -1)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        a + (b - a) * CGFloat(t)
    }

    private var cardFront: some View {
        LinearGradient(
            colors: sampledColors ?? [
                categoryColor.opacity(0.95),
                categoryColor.opacity(0.38)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func sampleThumbnailColors() async {
        guard let urlString = link.thumbnailURL,
              let url = URL(string: urlString) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let uiImage = UIImage(data: data),
                  let colors = Self.extractGradient(from: uiImage) else { return }
            await MainActor.run { sampledColors = colors }
        } catch {
            // Fall back to the categoryColor gradient; no further action needed.
        }
    }

    private static func extractGradient(from uiImage: UIImage) -> [Color]? {
        guard let cg = uiImage.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)
        let h = ci.extent.height
        // CoreImage Y increases upward, so the "top half" of the image is the upper Y range.
        let topRect = CGRect(x: ci.extent.minX,
                             y: ci.extent.minY + h / 2,
                             width: ci.extent.width,
                             height: h / 2)
        let bottomRect = CGRect(x: ci.extent.minX,
                                y: ci.extent.minY,
                                width: ci.extent.width,
                                height: h / 2)
        guard let top = averageColor(of: ci, in: topRect),
              let bottom = averageColor(of: ci, in: bottomRect) else { return nil }
        return [Color(uiColor: top), Color(uiColor: bottom)]
    }

    private static func averageColor(of image: CIImage, in rect: CGRect) -> UIColor? {
        let cropped = image.cropped(to: rect)
        let extent = CIVector(cgRect: rect)
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: cropped, "inputExtent": extent]),
              let output = filter.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull as Any])
        context.render(output,
                       toBitmap: &bitmap,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: nil)
        return UIColor(red: CGFloat(bitmap[0]) / 255,
                       green: CGFloat(bitmap[1]) / 255,
                       blue: CGFloat(bitmap[2]) / 255,
                       alpha: 1)
    }

    private func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true

        // Same spring as .onAppear but reversed, plus cardFadeOut so the gradient
        // card melts to transparent over the shrink, revealing the real home card
        // (with the actual thumbnail) underneath as the modal settles.
        withAnimation(reduceMotion ? .linear(duration: 0.01) : spring) {
            flipPhase = 0
            sizePhase = 0
            cardFadeOut = 1
        }

        // Wait for the spring to settle before tearing down the cover. spring.response
        // is 0.35; add a little buffer so the animation visually completes first.
        let teardownDelay: Double = reduceMotion ? 0.02 : 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + teardownDelay) {
            onDismiss()
        }
    }
}

struct LinkDetailView: View {
    let link: IngestResponse
    let categoryColor: Color

    @State private var presentingReader = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                mediaSection

                summaryCard
                    .padding(20)
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .sheet(isPresented: $presentingReader) {
            if let url = URL(string: link.canonicalURL) {
                SafariReaderView(url: url)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Media

    @ViewBuilder
    private var mediaSection: some View {
        if let embed = embedURL(for: link) {
            MediaEmbedView(embedURL: embed, link: link, categoryColor: categoryColor)
                .aspectRatio(mediaAspectRatio, contentMode: .fit)
                .frame(maxHeight: 540)
                .background(Color.black)
        } else {
            heroThumbnail
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        presentingReader = true
                    } label: {
                        Label("Read article", systemImage: "book")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                            .background(.ultraThinMaterial, in: Capsule())
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
        }
    }

    private var heroThumbnail: some View {
        ZStack {
            LinearGradient(
                colors: [categoryColor.opacity(0.95), categoryColor.opacity(0.38)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let urlString = link.thumbnailURL,
               let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Color.clear
                }
                .clipped()
            }
        }
    }

    private var mediaAspectRatio: CGFloat {
        switch link.sourcePlatform {
        case .youtube:
            return link.canonicalURL.contains("/shorts/") ? 9.0 / 16.0 : 16.0 / 9.0
        case .vimeo:
            return 16.0 / 9.0
        case .instagram:
            return 0.77
        case .tiktok:
            return 0.57
        case .linkedin, .reddit, .web, .x:
            return 16.0 / 9.0
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: link.sourcePlatform.sfSymbol)
                Text(link.displayDomain ?? link.sourcePlatform.rawValue.capitalized)
                Spacer()
                Text(link.ingestedAt.formatted(.dateTime.month().day().year()))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            Text(link.displayTitle)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)

            if let description = link.description, !description.isEmpty {
                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !link.categories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(link.categories) { category in
                            Text(category.name)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 11)
                                .frame(height: 30)
                                .background(categoryColor.opacity(0.18), in: Capsule())
                                .foregroundStyle(categoryColor)
                        }
                    }
                }
            }

            actionButtons
                .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let url = URL(string: link.canonicalURL) {
            VStack(spacing: 10) {
                if embedURL(for: link) == nil {
                    Button {
                        presentingReader = true
                    } label: {
                        Label("Open in reader", systemImage: "book")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .foregroundStyle(.white)
                            .background(categoryColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Link(destination: url) {
                    Label("Open original link", systemImage: "arrow.up.right.square")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .foregroundStyle(embedURL(for: link) == nil ? categoryColor : .white)
                        .background {
                            if embedURL(for: link) == nil {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(categoryColor, lineWidth: 1.5)
                            } else {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(categoryColor)
                            }
                        }
                }
            }
        }
    }
}

// MARK: - Embed state machine

private struct MediaEmbedView: View {
    let embedURL: URL
    let link: IngestResponse
    let categoryColor: Color

    private enum LoadState {
        case checking
        case ready
        case failed
    }

    @State private var state: LoadState = .checking

    var body: some View {
        Group {
            switch state {
            case .checking:
                ZStack {
                    Color.black
                    ProgressView()
                        .tint(.white)
                }
            case .ready:
                WebViewWrapper(url: embedURL)
            case .failed:
                FallbackCTA(link: link, categoryColor: categoryColor)
            }
        }
        .task(id: embedURL) {
            await preflight()
        }
    }

    private func preflight() async {
        state = .checking
        var request = URLRequest(url: embedURL, timeoutInterval: 3.0)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                state = .ready
            } else {
                state = .failed
            }
        } catch {
            state = .failed
        }
    }
}

// MARK: - Fallback CTA

private struct FallbackCTA: View {
    let link: IngestResponse
    let categoryColor: Color

    @State private var presentingReader = false

    var body: some View {
        ZStack {
            heroBackground
                .opacity(0.30)
                .blur(radius: 14)

            VStack(spacing: 14) {
                Image(systemName: "play.slash.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("Can't play here")
                    .font(.headline)

                Text("\(platformName) doesn't allow this post to play inside other apps.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Button {
                    openInNativeApp()
                } label: {
                    Label("Watch on \(platformName)", systemImage: link.sourcePlatform.sfSymbol)
                        .font(.headline)
                        .frame(maxWidth: 280)
                        .frame(height: 48)
                        .foregroundStyle(.white)
                        .background(categoryColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)

                Button {
                    presentingReader = true
                } label: {
                    Text("Open in Safari instead")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 30)
        }
        .sheet(isPresented: $presentingReader) {
            if let url = URL(string: link.canonicalURL) {
                SafariReaderView(url: url)
                    .ignoresSafeArea()
            }
        }
    }

    private var platformName: String {
        link.sourcePlatform.rawValue.capitalized
    }

    private func openInNativeApp() {
        guard let url = URL(string: link.canonicalURL) else { return }
        UIApplication.shared.open(url)
    }

    private var heroBackground: some View {
        ZStack {
            LinearGradient(
                colors: [categoryColor.opacity(0.95), categoryColor.opacity(0.38)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let urlString = link.thumbnailURL,
               let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Color.clear
                }
                .clipped()
            }
        }
    }
}

// MARK: - Embed URL helpers

private func embedURL(for link: IngestResponse) -> URL? {
    switch link.sourcePlatform {
    case .youtube:   return youtubeEmbedURL(from: link.canonicalURL)
    case .vimeo:     return vimeoEmbedURL(from: link.canonicalURL)
    case .instagram: return instagramEmbedURL(from: link.canonicalURL)
    case .tiktok:    return tiktokEmbedURL(from: link.canonicalURL)
    case .linkedin, .reddit, .web, .x: return nil
    }
}

private func youtubeEmbedURL(from urlString: String) -> URL? {
    guard let components = URLComponents(string: urlString) else { return nil }
    let params = "playsinline=1&modestbranding=1&rel=0"

    if components.host?.contains("youtu.be") == true {
        let id = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !id.isEmpty else { return nil }
        return URL(string: "https://www.youtube.com/embed/\(id)?\(params)")
    }
    let segments = components.path.split(separator: "/").map(String.init)
    if let shortsIndex = segments.firstIndex(of: "shorts"),
       segments.indices.contains(shortsIndex + 1) {
        let id = segments[shortsIndex + 1]
        return URL(string: "https://www.youtube.com/embed/\(id)?\(params)")
    }
    if let id = components.queryItems?.first(where: { $0.name == "v" })?.value, !id.isEmpty {
        return URL(string: "https://www.youtube.com/embed/\(id)?\(params)")
    }
    return nil
}

private func vimeoEmbedURL(from urlString: String) -> URL? {
    guard let components = URLComponents(string: urlString) else { return nil }
    let segments = components.path.split(separator: "/").map(String.init)
    guard let id = segments.first(where: { Int($0) != nil }) ?? segments.last else { return nil }
    return URL(string: "https://player.vimeo.com/video/\(id)")
}

private func instagramEmbedURL(from urlString: String) -> URL? {
    guard let components = URLComponents(string: urlString) else { return nil }
    let segments = components.path.split(separator: "/").map(String.init)
    guard let kindIndex = segments.firstIndex(where: { $0 == "p" || $0 == "reel" || $0 == "tv" }),
          segments.indices.contains(kindIndex + 1) else { return nil }
    let shortcode = segments[kindIndex + 1]
    return URL(string: "https://www.instagram.com/p/\(shortcode)/embed/")
}

private func tiktokEmbedURL(from urlString: String) -> URL? {
    guard let components = URLComponents(string: urlString) else { return nil }
    let segments = components.path.split(separator: "/").map(String.init)
    guard let videoIndex = segments.firstIndex(of: "video"),
          segments.indices.contains(videoIndex + 1) else { return nil }
    let id = segments[videoIndex + 1]
    return URL(string: "https://www.tiktok.com/embed/v2/\(id)")
}

// MARK: - WebView wrapper

struct WebViewWrapper: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.backgroundColor = .black
        webView.isOpaque = false
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url != url {
            uiView.load(URLRequest(url: url))
        }
    }
}

// MARK: - Safari Reader wrapper

struct SafariReaderView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = true
        config.barCollapsingEnabled = false
        return SFSafariViewController(url: url, configuration: config)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
