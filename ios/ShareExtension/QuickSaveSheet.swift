import SwiftUI

struct QuickSaveSheet: View {
    @ObservedObject var viewModel: ShareViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
                .contentShape(Rectangle())
                .onTapGesture { viewModel.cancel() }

            VStack(spacing: 0) {
                sheetHandle
                    .padding(.top, 12)
                    .padding(.bottom, 18)

                content
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
            }
            .background(sheetBackground)
            .cornerRadius(20, corners: [.topLeft, .topRight])
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    // MARK: - Sheet background

    @ViewBuilder
    private var sheetBackground: some View {
        if #available(iOS 26.0, *) {
            Color.clear.background(.ultraThinMaterial)
        } else {
            Color(.systemBackground)
        }
    }

    // MARK: - Sheet handle

    private var sheetHandle: some View {
        Capsule()
            .fill(Color(.tertiaryLabel))
            .frame(width: 36, height: 5)
            .modifier(GlassHandleModifier())
    }

    // MARK: - Content (stable layout, content changes per state)

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            LinkCard(state: viewModel.state)
            categorySection
            inlineStatusLine
            NoteField(text: $viewModel.noteText, isExpanded: $viewModel.isNoteExpanded)
            ReminderToggle(reminderDate: $viewModel.reminderDate, noteText: viewModel.noteText)
            SheetActions(viewModel: viewModel)
                .padding(.top, 10)

            #if DEBUG
            if let err = viewModel.debugError {
                Text("⚠️ \(err)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            #endif
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Save to Inbox")
                    .font(.title2.weight(.bold))
                if case .duplicate = viewModel.state {
                    Text("Already in your inbox")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            #if DEBUG
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    viewModel.cycleState()
                }
            } label: {
                HStack(spacing: 4) {
                    Text(debugStateLabel)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.purple, in: Capsule())
            }
            .buttonStyle(.plain)
            #endif
            if case .authExpired = viewModel.state {
                authBanner
            } else if case .offline = viewModel.state {
                offlineBanner
            }
        }
    }

    #if DEBUG
    private var debugStateLabel: String {
        switch viewModel.state {
        case .idle: return "idle"
        case .fetching: return "fetching"
        case .ready: return "ready"
        case .partial: return "partial"
        case .duplicate: return "duplicate"
        case .offline: return "offline"
        case .authExpired: return "authExpired"
        case .saved: return "saved"
        }
    }
    #endif

    // MARK: - Category section

    @ViewBuilder
    private var categorySection: some View {
        let categories = viewModel.state.response?.categories ?? []
        CategoryChipRow(
            categories: categories,
            isLoading: viewModel.state.isLoading,
            selectedID: $viewModel.selectedCategoryID
        )
    }

    // MARK: - Inline status line

    @ViewBuilder
    private var inlineStatusLine: some View {
        switch viewModel.state {
        case .ready(let response):
            if let top = response.categories.max(by: { ($0.confidence ?? 0) < ($1.confidence ?? 0) }),
               let confidence = top.confidence {
                HStack(spacing: 5) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("Auto-categorised · \(Int(confidence * 100))% confidence")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .partial:
            HStack(spacing: 5) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Preview is loading — we'll fetch it after saving")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .duplicate(let response):
            HStack(spacing: 5) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                let daysAgo = Calendar.current.dateComponents([.day], from: response.ingestedAt, to: Date()).day ?? 0
                Text(daysAgo == 0 ? "Saved today" : "Saved \(daysAgo) day\(daysAgo == 1 ? "" : "s") ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Status banners

    private var authBanner: some View {
        Label("Open app to re-link", systemImage: "exclamationmark.circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassyBackground(in: Capsule())
    }

    private var offlineBanner: some View {
        Label("Offline", systemImage: "wifi.slash")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassyBackground(in: Capsule())
    }
}

// MARK: - Glass handle modifier

/// Applies Liquid Glass to the sheet handle on iOS 26+, no-op on older.
private struct GlassHandleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .hidden()
                .overlay {
                    Capsule()
                        .fill(.clear)
                        .frame(width: 36, height: 5)
                        .glassEffect(.regular, in: Capsule())
                }
        } else {
            content
        }
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func previewSheet(state: SheetState) -> some View {
    QuickSaveSheet(viewModel: ShareViewModel(previewState: state))
        .frame(width: 390, height: 600)
        .background(Color(.systemBackground))
}

#Preview("1. Idle") {
    previewSheet(state: .idle)
}

#Preview("2. Fetching") {
    previewSheet(state: .fetching)
}

#Preview("3. Ready (AI categorised)") {
    previewSheet(state: .ready(.mock()))
}

#Preview("4. Partial (pending enrichment)") {
    previewSheet(state: .partial(.mock(status: .pending, title: nil)))
}

#Preview("5. Duplicate") {
    previewSheet(state: .duplicate(.mock(ingestedAt: Date().addingTimeInterval(-86400 * 3))))
}

#Preview("6. Offline") {
    previewSheet(state: .offline(URL(string: "https://example.com")!))
}

#Preview("7. Auth expired") {
    previewSheet(state: .authExpired)
}

#Preview("8. Saved") {
    previewSheet(state: .saved)
}
#endif

// MARK: - Glass helpers

@ViewBuilder
func glassContainer<Content: View>(spacing: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
    if #available(iOS 26.0, *) {
        GlassEffectContainer(spacing: spacing) { content() }
    } else {
        content()
    }
}

extension View {
    @ViewBuilder
    func glassyBackground<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

// MARK: - Rounded Corner Shape
struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

