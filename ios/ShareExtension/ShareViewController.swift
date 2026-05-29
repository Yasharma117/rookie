import UIKit
import SwiftUI
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private var viewModel: ShareViewModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        extractURL { [weak self] url in
            DispatchQueue.main.async { self?.mount(url: url) }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The system wraps share extensions in container views with opaque
        // backgrounds. Walk up the hierarchy and clear every one so our
        // own dim layer (in the SwiftUI view) can show through.
        var ancestor = view.superview
        while let sv = ancestor {
            sv.backgroundColor = .clear
            ancestor = sv.superview
        }
    }

    // MARK: - Mount

    private func mount(url: URL?) {
        guard let url else {
            extensionContext?.cancelRequest(withError: ShareError.invalidURL)
            return
        }

        // Fall back to "rookie_dev_api_key_123" (which we seeded in your Neon DB)
        // so that the simulator is automatically authorized.
        let token = KeychainStore.shared.ingestToken() ?? "rookie_dev_api_key_123"

        let vm = ShareViewModel(url: url, token: token)
        vm.extensionContext = extensionContext
        viewModel = vm

        let hc = ClearHostingController(rootView: QuickSaveSheet(viewModel: vm))
        embed(hc)
        vm.beginSave()
    }

    private func embed(_ hc: UIViewController) {
        addChild(hc)
        view.addSubview(hc.view)
        hc.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hc.view.topAnchor.constraint(equalTo: view.topAnchor),
            hc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hc.didMove(toParent: self)
    }

    private func dismissExtension() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    // MARK: - URL extraction

    private func extractURL(_ completion: @escaping (URL?) -> Void) {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments else {
            completion(nil)
            return
        }

        // Prefer typed URL attachment
        for provider in attachments where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                completion(item as? URL)
            }
            return
        }

        // Fallback: extract URL from plain text via NSDataDetector
        for provider in attachments where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                guard let text = item as? String else { completion(nil); return }
                let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
                let range = NSRange(text.startIndex..., in: text)
                completion(detector?.firstMatch(in: text, range: range)?.url)
            }
            return
        }

        completion(nil)
    }
}

// MARK: - NotLinkedView

private struct NotLinkedView: View {
    let onOpenApp: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(.tertiaryLabel))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 24)

            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 52))
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    Text("Link your account")
                        .font(.title2.bold())
                    Text("Open LinkSaver and sign in before saving links from other apps.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button(action: onOpenApp) {
                    Text("Open LinkSaver")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button("Cancel", action: onDismiss)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)

            Spacer()
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Errors

private enum ShareError: Error {
    case invalidURL
}

// MARK: - ClearHostingController

final class ClearHostingController<Content: View>: UIHostingController<Content> {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        view.backgroundColor = .clear
    }
}

