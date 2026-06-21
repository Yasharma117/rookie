import SwiftUI

// MARK: - Animation constants (from plan.md easings table)

private extension Animation {
    static let settleSpring = Animation.interactiveSpring(response: 0.45, dampingFraction: 0.86, blendDuration: 0.1)
    static let strongEaseOut = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.6)
    static let strongEaseOutShort = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.46)
    static let strongEaseOutMid = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.50)
    static let ambientCrossFade = Animation.easeInOut(duration: 0.55)
    static let metadataFadeIn = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.28)
    static let reduceMotionMount = Animation.easeInOut(duration: 0.20)
}

// MARK: - Card frame capture (round 11 Hero transition)

private struct CardFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Horizontal slide transition

private enum HorizontalDirection {
    case none
    case forward   // swipe-left → next category
    case back      // swipe-right → previous category
}

private extension AnyTransition {
    static func slideHorizontal(direction: HorizontalDirection, reduceMotion: Bool) -> AnyTransition {
        if reduceMotion || direction == .none { return .opacity }
        switch direction {
        case .forward:
            // Old wheel exits to the left, new wheel enters from the right.
            // No `.opacity` combination — both wheels stay fully opaque so the
            // slide boundary is a clean edge, not a translucent overlap.
            return .asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .leading)
            )
        case .back:
            return .asymmetric(
                insertion: .move(edge: .leading),
                removal: .move(edge: .trailing)
            )
        case .none:
            return .opacity
        }
    }
}

// MARK: - Mount choreographer

@Observable
private final class MountChoreographer {
    var ambientIn = false
    var navIn = false
    var cardIn = false
    var peeksIn = false
    var affordancesIn = false

    private var task: Task<Void, Never>?

    @MainActor
    func replay(reduceMotion: Bool) {
        task?.cancel()
        if reduceMotion {
            withAnimation(.reduceMotionMount) {
                ambientIn = true
                navIn = true
                cardIn = true
                peeksIn = true
                affordancesIn = true
            }
            return
        }
        ambientIn = false
        navIn = false
        cardIn = false
        peeksIn = false
        affordancesIn = false

        task = Task { @MainActor in
            withAnimation(.strongEaseOut) { ambientIn = true }
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.strongEaseOutShort) { navIn = true }
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.strongEaseOut) { cardIn = true }
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.strongEaseOutMid) { peeksIn = true }
            try? await Task.sleep(nanoseconds: 130_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.strongEaseOut) { affordancesIn = true }
        }
    }
}

// MARK: - InboxView

struct InboxView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var choreographer = MountChoreographer()

    @State private var links: [IngestResponse] = []
    @State private var categories: [Category] = []
    @State private var selectedCategoryID: UUID?
    @State private var searchQuery = ""
    @State private var isSearchExpanded: Bool = false
    @State private var isFilterStripOpen: Bool = false
    @FocusState private var searchFocused: Bool
    @State private var activeLinkID: UUID?
    @State private var previousThumbnailURL: String?
    @State private var detailLink: IngestResponse?
    @State private var ripplingLinkID: UUID?
    @State private var rippleCenter: CGPoint = .zero
    @State private var rippleProgress: Double = 0
    @State private var pressedScale: CGFloat = 1.0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var didSettleInitialPage = false
    @State private var suppressNextPageHaptic = false
    @State private var swipeDirection: HorizontalDirection = .none
    @State private var cardFrames: [UUID: CGRect] = [:]
    @State private var detailSourceFrame: CGRect = .zero

    var body: some View {
        NavigationStack {
            ZStack {
                dynamicBackground
                    .opacity(choreographer.ambientIn ? 1 : 0)
                    .ignoresSafeArea()

                if isLoading && links.isEmpty {
                    loadingView
                } else if links.isEmpty {
                    emptyView
                } else {
                    homeContent
                }

                if isFilterStripOpen {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { closeFilterStrip() }
                }

                bottomControls
                    .opacity(choreographer.affordancesIn ? 1 : 0)
                    .offset(y: choreographer.affordancesIn ? 0 : 12)
                    .ignoresSafeArea(edges: .bottom)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onPreferenceChange(CardFramePreferenceKey.self) { frames in
                cardFrames = frames
            }
            .fullScreenCover(item: $detailLink) { link in
                FlippableDetailContainer(
                    link: link,
                    categoryColor: color(for: link),
                    sourceFrame: detailSourceFrame,
                    onDismiss: { detailLink = nil }
                )
                .presentationBackground(.clear)
                .transaction { transaction in
                    transaction.disablesAnimations = true
                }
            }
        }
        .task { await loadHome() }
        .onAppear {
            choreographer.replay(reduceMotion: reduceMotion)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Refresh after returning from the share extension (or any background).
            if newPhase == .active {
                Task { await loadHome() }
            }
        }
        .onChange(of: activeLinkID) { old, new in
            if let oldID = old, let oldLink = links.first(where: { $0.id == oldID }) {
                previousThumbnailURL = oldLink.thumbnailURL
            }
            if !didSettleInitialPage {
                didSettleInitialPage = true
                return
            }
            if suppressNextPageHaptic {
                suppressNextPageHaptic = false
                return
            }
            if !reduceMotion && new != nil && new != old {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
        }
    }

    // MARK: - Main Content

    private var homeContent: some View {
        Group {
            if visibleLinks.isEmpty {
                noResultsView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 100)
                    .id(selectedCategoryID?.uuidString ?? "all")
                    .transition(.slideHorizontal(direction: swipeDirection, reduceMotion: reduceMotion))
            } else {
                ZStack {
                    wheelView()
                        .id(selectedCategoryID?.uuidString ?? "all")
                        .transition(.slideHorizontal(direction: swipeDirection, reduceMotion: reduceMotion))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(categorySwipeGesture)
        .onChange(of: visibleIDs) { _, ids in
            guard let first = ids.first else {
                activeLinkID = nil
                return
            }
            if activeLinkID.map({ !ids.contains($0) }) ?? true {
                activeLinkID = first
            }
        }
        .onAppear {
            activeLinkID = visibleLinks.first?.id
        }
    }

    /// Horizontal swipe that hops between categories. Lives at homeContent
    /// level (not inside wheelView) so it works over the empty "Nothing here"
    /// state too — letting the user swipe off an empty category.
    private var categorySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5 else { return }
                guard abs(dx) > 70 else { return }
                cycleCategory(forward: dx < 0)
            }
    }

    private func wheelView() -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            let reduceMotionEnabled = reduceMotion

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(visibleLinks) { link in
                        let cardW = cardWidth(for: link, in: size)
                        let cardH = canonicalCardHeight(in: size)
                        let posterAspect = posterAspectRatio(for: link, in: size)
                        let isActive = link.id == activeLinkID

                        Group {
                            if link.summarySegments != nil {
                                ArticleCard(
                                    link: link,
                                    categoryColor: color(for: link),
                                    cardWidth: cardW,
                                    cardHeight: cardH
                                )
                            } else {
                                HomeCard(
                                    link: link,
                                    categoryColor: color(for: link),
                                    isRippling: ripplingLinkID == link.id,
                                    rippleCenter: rippleCenter,
                                    rippleProgress: rippleProgress,
                                    pressedScale: pressedScale,
                                    cardWidth: cardW,
                                    posterAspectRatio: posterAspect,
                                    reduceMotion: reduceMotionEnabled
                                )
                            }
                        }
                        .opacity(detailLink?.id == link.id ? 0 : 1)
                        .frame(maxWidth: .infinity)
                        .frame(height: size.height * 0.74)
                        .id(link.id)
                        .scrollTransition(.interactive, axis: .vertical) { content, phase in
                            let phaseValue = reduceMotionEnabled ? 0.0 : Double(phase.value)
                            let absPhaseValue = abs(phaseValue)
                            let hinge: UnitPoint = phaseValue < 0 ? .bottom : .top
                            return content
                                .scaleEffect(
                                    x: 1 - absPhaseValue * 0.35,
                                    y: 1 - absPhaseValue * 0.45,
                                    anchor: hinge
                                )
                                .rotation3DEffect(
                                    .degrees(phaseValue * 30),
                                    axis: (x: 1, y: 0, z: 0),
                                    anchor: hinge,
                                    perspective: 0.55
                                )
                                .blur(radius: absPhaseValue * 8)
                                .opacity(1 - absPhaseValue * 0.55)
                        }
                        .opacity(mountOpacity(forIsActive: isActive))
                        .offset(y: mountOffset(forIsActive: isActive))
                        .scaleEffect(mountScale(forIsActive: isActive))
                        .onTapGesture(coordinateSpace: .local) { location in
                            tap(link, at: location)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollPosition(id: $activeLinkID, anchor: .center)
            // Symmetric vertical margins let EVERY card (incl. the first/last)
            // rest at the viewport center. Without these, the short 0.74-height
            // cells pin to the top — the long-standing "cards pushed up" bug.
            // Value = half the empty space the cell leaves in the viewport.
            .contentMargins(.vertical, size.height * 0.13, for: .scrollContent)
            .refreshable { await loadHome() }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: .black.opacity(0.55), location: 0.025),
                        .init(color: .black, location: 0.07),
                        .init(color: .black, location: 0.93),
                        .init(color: .black.opacity(0.55), location: 0.975),
                        .init(color: .clear, location: 1.00)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    private func mountOpacity(forIsActive isActive: Bool) -> Double {
        if isActive { return choreographer.cardIn ? 1 : 0 }
        return choreographer.peeksIn ? 1 : 0
    }

    private func mountOffset(forIsActive isActive: Bool) -> CGFloat {
        if isActive { return choreographer.cardIn ? 0 : 24 }
        return choreographer.peeksIn ? 0 : 60
    }

    private func mountScale(forIsActive isActive: Bool) -> CGFloat {
        if isActive { return choreographer.cardIn ? 1.0 : 0.96 }
        return 1.0
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            Spacer()

            if isFilterStripOpen {
                ArcCategoryScroller(
                    categories: categories,
                    selectedCategoryID: selectedCategoryID,
                    onSelect: { id in
                        selectCategory(id)
                        closeFilterStrip()
                    },
                    onAdd: { addCategoryTapped() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack {
                settingsButton
                    .opacity(isFilterStripOpen ? 0 : 1)
                    .allowsHitTesting(!isFilterStripOpen)
                Spacer()
                filterButton
                Spacer()
                searchControl
                    .opacity(isFilterStripOpen ? 0 : 1)
                    .allowsHitTesting(!isFilterStripOpen)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
        }
        .background {
            scrimGradient
                .opacity(isFilterStripOpen ? 1 : 0)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: isFilterStripOpen)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: selectedCategoryID)
    }

    private var filterButton: some View {
        Button {
            toggleFilterStrip()
        } label: {
            Group {
                if isFilterStripOpen {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 50, height: 50)
                        .contentShape(Circle().inset(by: -6))
                        .glassyBackground(in: Circle())
                } else if let category = selectedCategory,
                          let color = Color(hex: category.color) {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14, weight: .semibold))
                        Text(category.name)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 50)
                    .foregroundStyle(.white)
                    .background { Capsule().fill(color) }
                    .contentShape(Capsule().inset(by: -6))
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14, weight: .semibold))
                        Text("All")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 50)
                    .foregroundStyle(.primary)
                    .contentShape(Capsule().inset(by: -6))
                    .glassyBackground(in: Capsule())
                }
            }
            .contentTransition(.opacity)
        }
        .buttonStyle(.plain)
        .contentShape(Capsule().inset(by: -6))
        .accessibilityLabel(
            isFilterStripOpen
                ? "Close filters"
                : (selectedCategory.map { "Filtered by \($0.name). Open filters." } ?? "Open filters")
        )
    }

    private func toggleFilterStrip() {
        if !reduceMotion {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
        if isSearchExpanded { collapseSearch() }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            isFilterStripOpen.toggle()
        }
    }

    private func closeFilterStrip() {
        guard isFilterStripOpen else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            isFilterStripOpen = false
        }
    }

    private func addCategoryTapped() {
        if !reduceMotion {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
        // TODO: wire to a category-creation sheet when the flow exists.
    }

    @ViewBuilder
    private func glassGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 10) { content() }
        } else {
            content()
        }
    }

    private var searchControl: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSearchExpanded ? .secondary : .primary)

            if isSearchExpanded {
                TextField("Search saves", text: $searchQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .transition(.opacity)

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear search")
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Button {
                        collapseSearch()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .accessibilityLabel("Close search")
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, isSearchExpanded ? 18 : 0)
        .frame(width: isSearchExpanded ? nil : 50, height: 50)
        .frame(maxWidth: isSearchExpanded ? .infinity : 50)
        .glassyBackground(in: Capsule())
        .contentShape(Capsule())
        .onTapGesture {
            if !isSearchExpanded {
                expandSearch()
            }
        }
        .accessibilityLabel(isSearchExpanded ? "Search saves" : "Open search")
    }

    private func expandSearch() {
        if isFilterStripOpen { closeFilterStrip() }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            isSearchExpanded = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            searchFocused = true
        }
    }

    private func collapseSearch() {
        searchFocused = false
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            searchQuery = ""
            isSearchExpanded = false
        }
    }

    private var settingsButton: some View {
        NavigationLink {
            SettingsView()
                .environmentObject(appState)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 50, height: 50)
                .contentShape(Circle().inset(by: -6))
                .glassyBackground(in: Circle())
        }
        .buttonStyle(.plain)
        .contentShape(Circle().inset(by: -6))
        .accessibilityLabel("Settings")
    }

    private var scrimGradient: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: Color(.systemBackground).opacity(0.18), location: 0.55),
                .init(color: Color(.systemBackground).opacity(0.38), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea(edges: .bottom)
    }

    private func selectCategory(_ id: UUID?) {
        guard id != selectedCategoryID else { return }
        let options: [UUID?] = [nil] + categories.map(\.id)
        let oldIdx = options.firstIndex(of: selectedCategoryID) ?? 0
        let newIdx = options.firstIndex(of: id) ?? 0
        swipeDirection = newIdx > oldIdx ? .forward : .back

        if !reduceMotion {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
        suppressNextPageHaptic = true
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            selectedCategoryID = id
        }
    }

    private func cycleCategory(forward: Bool) {
        let options: [UUID?] = [nil] + categories.map(\.id)
        guard options.count > 1 else { return }
        let current = options.firstIndex(of: selectedCategoryID) ?? 0
        let next = (current + (forward ? 1 : -1) + options.count) % options.count
        swipeDirection = forward ? .forward : .back
        if !reduceMotion {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
        suppressNextPageHaptic = true
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            selectedCategoryID = options[next]
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 18) {
            Spacer()

            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 42, style: .continuous)
                        .fill(.thinMaterial)
                        .frame(width: 250 + CGFloat(index * 26), height: 330)
                        .offset(y: CGFloat(index - 1) * 92)
                        .scaleEffect(1 - CGFloat(abs(index - 1)) * 0.12)
                        .opacity(index == 1 ? 1 : 0.45)
                }
            }
            .shimmering()

            Spacer()
        }
        .padding(.bottom, 100)
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bookmark.slash")
                .font(.system(size: 44, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("No saved links yet")
                .font(.title3.bold())
            Text("Share links from Safari or any app to start building your feed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 90)
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Nothing here")
                .font(.headline)
            Text("Try a different category or search.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Ambient Background (two-image cross-fade + scrim)

    @ViewBuilder
    private var dynamicBackground: some View {
        let link = activeLink
        let baseColor = color(for: link)

        ZStack {
            LinearGradient(
                colors: [
                    baseColor.opacity(0.58),
                    Color(.systemBackground),
                    baseColor.opacity(0.26)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            if let prevURLString = previousThumbnailURL,
               let prevURL = URL(string: prevURLString) {
                blurredAmbient(url: prevURL)
            }

            if let currentURLString = link?.thumbnailURL,
               let currentURL = URL(string: currentURLString) {
                blurredAmbient(url: currentURL)
                    .id(activeLinkID)
                    .transition(.opacity)
            }

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.22), location: 0),
                    .init(color: .clear, location: 0.32),
                    .init(color: .clear, location: 0.68),
                    .init(color: .black.opacity(0.18), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? .linear(duration: 0.01) : .ambientCrossFade, value: activeLinkID)
    }

    private func blurredAmbient(url: URL) -> some View {
        AsyncImage(url: url) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 80)
                .scaleEffect(1.4)
                .saturation(1.05)
                .clipped()
        } placeholder: {
            Color.clear
        }
        .allowsHitTesting(false)
    }

    // MARK: - Data

    private var visibleLinks: [IngestResponse] {
        let source = links
        let categoryFiltered = source.filter { link in
            guard let selectedCategoryID else { return true }
            return link.categories.contains { $0.id == selectedCategoryID }
        }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return categoryFiltered }
        return categoryFiltered.filter { link in
            let haystack = [
                link.displayTitle,
                link.displayDomain ?? "",
                link.description ?? "",
                link.author ?? "",
                link.categories.map(\.name).joined(separator: " ")
            ]
            .joined(separator: " ")
            .lowercased()
            return haystack.contains(query)
        }
    }

    private var visibleIDs: [UUID] {
        visibleLinks.map(\.id)
    }

    private var activeLink: IngestResponse? {
        if let activeLinkID, let link = visibleLinks.first(where: { $0.id == activeLinkID }) {
            return link
        }
        return visibleLinks.first
    }

    private var selectedCategory: Category? {
        guard let id = selectedCategoryID else { return nil }
        return categories.first(where: { $0.id == id })
    }

    private func loadHome() async {
        guard let token = KeychainStore.shared.effectiveIngestToken() else {
            #if DEBUG
            loadDemoContentIfNeeded()
            #endif
            return
        }

        // Stale-while-revalidate: paint the cached library immediately so the
        // user never waits on the network. Only show the loading shimmer on a
        // true cold start (empty cache). The fetch below reconciles in place.
        let hadCache = !links.isEmpty
        if !hadCache {
            let cachedLinks = LocalCache.loadLinks()
            if !cachedLinks.isEmpty {
                let cachedCats = LocalCache.loadCategories()
                links = cachedLinks
                categories = cachedCats.isEmpty
                    ? inferredCategories(from: cachedLinks)
                    : cachedCats
                if activeLinkID == nil { activeLinkID = links.first?.id }
            }
        }

        let showSpinner = links.isEmpty
        if showSpinner { isLoading = true }
        defer { isLoading = false }
        do {
            async let fetchedLinks = APIClient.shared.fetchLinks(token: token)
            async let fetchedCategories = try? APIClient.shared.fetchCategories(token: token)
            let loadedLinks = try await fetchedLinks
            let loadedCategories = await fetchedCategories ?? inferredCategories(from: loadedLinks)

            links = loadedLinks
            categories = loadedCategories
            if activeLinkID == nil || !links.contains(where: { $0.id == activeLinkID }) {
                activeLinkID = links.first?.id
            }
        } catch {
            // Network failed — keep whatever cache we already painted.
            errorMessage = error.localizedDescription
            #if DEBUG
            if links.isEmpty { loadDemoContentIfNeeded(force: true) }
            #endif
        }
    }

    #if DEBUG
    private func loadDemoContentIfNeeded(force: Bool = false) {
        guard force || links.isEmpty else { return }
        links = HomeDemoContent.links
        categories = HomeDemoContent.categories
        if activeLinkID.map({ !links.map(\.id).contains($0) }) ?? true {
            activeLinkID = links.first?.id
        }
    }
    #endif

    private func inferredCategories(from links: [IngestResponse]) -> [Category] {
        var seen: Set<UUID> = []
        return links
            .flatMap(\.categories)
            .compactMap { ref in
                guard !seen.contains(ref.id) else { return nil }
                seen.insert(ref.id)
                return Category(id: ref.id, name: ref.name, color: nil, createdAt: Date())
            }
    }

    private func color(for link: IngestResponse?) -> Color {
        guard let link else { return Color(.systemGray5) }
        if let ref = link.categories.first,
           let category = categories.first(where: { $0.id == ref.id }),
           let color = Color(hex: category.color) {
            return color
        }
        switch link.sourcePlatform {
        case .instagram: return Color(red: 0.90, green: 0.18, blue: 0.48)
        case .linkedin: return Color(red: 0.04, green: 0.38, blue: 0.67)
        case .youtube: return Color(red: 0.88, green: 0.05, blue: 0.05)
        case .x: return Color(red: 0.10, green: 0.11, blue: 0.13)
        case .tiktok: return Color(red: 0.00, green: 0.68, blue: 0.72)
        case .vimeo: return Color(red: 0.10, green: 0.55, blue: 0.86)
        case .reddit: return Color(red: 0.95, green: 0.33, blue: 0.12)
        case .web: return Color(red: 0.30, green: 0.44, blue: 0.86)
        }
    }

    private func color(for link: IngestResponse) -> Color {
        color(for: Optional(link))
    }

    // Standardized sizing — every card (HomeCard or ArticleCard) gets the
    // same width and the same overall height, so the wheel reads as one
    // consistent stack regardless of source platform or content type.
    private func cardWidth(for link: IngestResponse, in size: CGSize) -> CGFloat {
        min(348, max(318, size.width * 0.88))
    }

    private func cardHeight(for link: IngestResponse, in size: CGSize) -> CGFloat {
        canonicalCardHeight(in: size)
    }

    /// Single source of truth for the card-content box height across types.
    /// Capped well below the wheel-cell slot so the top of the card never
    /// runs into the scroll mask gradient.
    private func canonicalCardHeight(in size: CGSize) -> CGFloat {
        min(560, size.height * 0.66)
    }

    private func posterAspectRatio(for link: IngestResponse, in size: CGSize) -> CGFloat {
        // Width / posterHeight where posterHeight = canonicalCardHeight - metadata block.
        // Derived so the entire HomeCard (poster + metadata) fills exactly canonicalCardHeight.
        let w = cardWidth(for: link, in: size)
        let h = max(1, canonicalCardHeight(in: size) - 68)
        return w / h
    }

    private func isVideoFirst(_ link: IngestResponse) -> Bool {
        switch link.sourcePlatform {
        case .instagram, .tiktok, .youtube, .vimeo:
            return true
        case .linkedin, .reddit, .web, .x:
            return false
        }
    }

    private func tap(_ link: IngestResponse, at location: CGPoint) {
        guard !reduceMotion else {
            detailSourceFrame = cardFrames[link.id] ?? .zero
            detailLink = link
            return
        }

        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        rippleCenter = location

        withAnimation(.easeOut(duration: 0.12)) {
            pressedScale = 0.97
        }

        withAnimation(.easeOut(duration: 0.48)) {
            rippleProgress = 1.0
            ripplingLinkID = link.id
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                pressedScale = 1.0
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            detailSourceFrame = cardFrames[link.id] ?? .zero
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                detailLink = link
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) {
            if ripplingLinkID == link.id {
                ripplingLinkID = nil
            }
            rippleProgress = 0
        }
    }

    private var homeSpring: Animation {
        reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.48, dampingFraction: 0.86)
    }
}

// MARK: - Arc Category Scroller
//
// Horizontal chip strip with edge falloff: chips sink and fade as they
// approach the scrollview edges. The arc tracks live scroll position via
// .visualEffect + GeometryProxy.bounds(of: .scrollView).
//
// Future: this is where a context-sensitive command-strip morph could slot
// in — same container, different chip content depending on scroll context.

private struct ArcCategoryScroller: View {
    let categories: [Category]
    let selectedCategoryID: UUID?
    let onSelect: (UUID?) -> Void
    let onAdd: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                addChip
                chip(title: "All", color: .primary, isSelected: selectedCategoryID == nil) {
                    onSelect(nil)
                }

                ForEach(categories) { category in
                    chip(
                        title: category.name,
                        color: Color(hex: category.color) ?? .accentColor,
                        isSelected: selectedCategoryID == category.id
                    ) {
                        onSelect(category.id)
                    }
                }
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 16)
        }
        .frame(height: 92)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black, location: 0.10),
                    .init(color: .black, location: 0.90),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .accessibilityElement(children: .contain)
    }

    private var addChip: some View {
        Button(action: onAdd) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 52, height: 52)
                .background {
                    Circle()
                        .fill(Color(.systemBackground).opacity(0.72))
                }
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .visualEffect { content, proxy in
            let chipFrame = proxy.frame(in: .scrollView(axis: .horizontal))
            let scrollWidth = proxy.bounds(of: .scrollView(axis: .horizontal))?.width ?? 1
            let chipCenter = chipFrame.midX
            let viewportCenter = scrollWidth / 2
            let halfWidth = max(scrollWidth / 2, 1)
            let normalized = min(1, max(0, abs(chipCenter - viewportCenter) / halfWidth))
            let curve = normalized * normalized
            return content
                .offset(y: curve * 28)
                .scaleEffect(1 - curve * 0.18, anchor: .top)
                .opacity(1 - curve * 0.7)
        }
        .accessibilityLabel("Add category")
    }

    @ViewBuilder
    private func chip(title: String, color: Color, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .padding(.horizontal, 24)
                .frame(height: 52)
                .foregroundStyle(isSelected ? .white : .primary)
                .background {
                    Capsule()
                        .fill(isSelected ? color : Color(.systemBackground).opacity(0.72))
                        .animation(
                            isSelected
                                ? .timingCurve(0.16, 1, 0.3, 1, duration: 0.20)
                                : .easeIn(duration: 0.15),
                            value: isSelected
                        )
                }
                .overlay {
                    Capsule()
                        .strokeBorder(isSelected ? .clear : Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .visualEffect { content, proxy in
            let chipFrame = proxy.frame(in: .scrollView(axis: .horizontal))
            let scrollWidth = proxy.bounds(of: .scrollView(axis: .horizontal))?.width ?? 1
            let chipCenter = chipFrame.midX
            let viewportCenter = scrollWidth / 2
            let halfWidth = max(scrollWidth / 2, 1)
            let normalized = min(1, max(0, abs(chipCenter - viewportCenter) / halfWidth))
            // Quadratic falloff: nearly flat at center, dramatic dip at edges.
            let curve = normalized * normalized
            return content
                .offset(y: curve * 28)
                .scaleEffect(1 - curve * 0.18, anchor: .top)
                .opacity(1 - curve * 0.7)
        }
        .accessibilityLabel(title == "All" ? "All categories" : "\(title) category")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Home Card

private struct HomeCard: View {
    let link: IngestResponse
    let categoryColor: Color
    let isRippling: Bool
    let rippleCenter: CGPoint
    let rippleProgress: Double
    let pressedScale: CGFloat
    let cardWidth: CGFloat
    let posterAspectRatio: CGFloat
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 14) {
            poster
                .frame(width: cardWidth)
                .aspectRatio(posterAspectRatio, contentMode: .fit)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: CardFramePreferenceKey.self,
                            value: [link.id: proxy.frame(in: .global)]
                        )
                    }
                )
                .scaleEffect(pressedScale)
                .distortionEffect(
                    ShaderLibrary.fluidRipple(
                        .float2(rippleCenter),
                        .float(rippleProgress),
                        .float(45)
                    ),
                    maxSampleOffset: CGSize(width: 56, height: 56),
                    isEnabled: isRippling && rippleProgress > 0
                )
                .shadow(color: categoryColor.opacity(0.34), radius: 32, y: 18)

            VStack(spacing: 7) {
                Text(link.displayTitle)
                    .font(.headline.weight(.semibold))
                    .lineLimit(isVideoFirst ? 1 : 2)
                    .multilineTextAlignment(.center)

                HStack(spacing: 7) {
                    if let domain = link.displayDomain {
                        Text(domain)
                    }
                    Text("•")
                    Label(link.sourcePlatform.rawValue.capitalized, systemImage: link.sourcePlatform.sfSymbol)
                        .labelStyle(.titleAndIcon)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.horizontal, 34)
            .scrollTransition(.interactive, axis: .vertical) { content, phase in
                content.opacity(reduceMotion ? 1 : max(0, 1 - Double(abs(phase.value)) * 1.4))
            }
            .animation(.metadataFadeIn, value: link.id)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(link.displayTitle), \(link.displayDomain ?? "saved link")")
    }

    private var poster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [categoryColor.opacity(0.95), categoryColor.opacity(0.38)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let urlString = link.thumbnailURL,
               let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    fallbackPoster
                }
            } else {
                fallbackPoster
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 42, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
    }

    private var fallbackPoster: some View {
        GeneratedPosterArtwork(link: link, categoryColor: categoryColor)
    }

    private var isVideoFirst: Bool {
        switch link.sourcePlatform {
        case .instagram, .tiktok, .youtube, .vimeo:
            return true
        case .linkedin, .reddit, .web, .x:
            return false
        }
    }
}

// MARK: - Helpers

#if DEBUG
private enum HomeDemoContent {
    static let moviesID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let techID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let cookingID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let travelID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    static let readingID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    static let jobsID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    static let designID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!

    static let categories: [Category] = [
        category(id: moviesID, name: "Movies", color: "#db2777"),
        category(id: techID, name: "Tech", color: "#0891b2"),
        category(id: cookingID, name: "Cooking", color: "#ea580c"),
        category(id: travelID, name: "Travel", color: "#16a34a"),
        category(id: readingID, name: "Reading", color: "#9333ea"),
        category(id: jobsID, name: "Jobs", color: "#2563eb"),
        category(id: designID, name: "Design", color: "#c026d3")
    ]

    static let links: [IngestResponse] = [
        link(
            id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1",
            url: "https://letterboxd.com/film/the-fault-in-our-stars/",
            platform: .web,
            title: "The Fault in Our Stars",
            description: "A tender movie pick for when you want something emotional, bright, and a little devastating.",
            author: "Letterboxd",
            daysAgo: 0,
            category: ref(moviesID, "Movies", 0.94)
        ),
        link(
            id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2",
            url: "https://developer.apple.com/design/human-interface-guidelines",
            platform: .web,
            title: "Apple Human Interface Guidelines",
            description: "A reference for native interaction patterns, visual hierarchy, controls, and motion.",
            author: "Apple",
            daysAgo: 1,
            category: ref(designID, "Design", 0.91)
        ),
        link(
            id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa3",
            url: "https://www.youtube.com/watch?v=demo-cacio-e-pepe",
            platform: .youtube,
            title: "Cacio e Pepe in 12 Minutes",
            description: "A fast weeknight pasta technique with pepper, pecorino, and glossy sauce.",
            author: "Kitchen Notes",
            daysAgo: 2,
            category: ref(cookingID, "Cooking", 0.89)
        ),
        link(
            id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa4",
            url: "https://www.instagram.com/reel/demo-kyoto-cafes/",
            platform: .instagram,
            title: "Quiet Kyoto Cafes Worth Saving",
            description: "Tiny lanes, paper lanterns, matcha counters, and slow mornings for the next trip.",
            author: "Travel Reel",
            daysAgo: 3,
            category: ref(travelID, "Travel", 0.88)
        ),
        link(
            id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa5",
            url: "https://stratechery.com/demo-ai-agents",
            platform: .web,
            title: "What AI Agents Change About Software",
            description: "A long-form read on workflows, distribution, and the next interface layer.",
            author: "Stratechery",
            daysAgo: 4,
            category: ref(readingID, "Reading", 0.83)
        ),
        link(
            id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa6",
            url: "https://www.linkedin.com/jobs/view/demo-product-designer",
            platform: .linkedin,
            title: "Senior Product Designer, Consumer AI",
            description: "A role focused on interaction systems, mobile product craft, and rapid prototyping.",
            author: "LinkedIn",
            daysAgo: 5,
            category: ref(jobsID, "Jobs", 0.86)
        ),
        link(
            id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa7",
            url: "https://vercel.com/blog/demo-fluid-compute",
            platform: .web,
            title: "Fluid Compute for Fast Web Apps",
            description: "Notes on serverless performance, cold starts, and making async workloads feel instant.",
            author: "Vercel",
            daysAgo: 6,
            category: ref(techID, "Tech", 0.9)
        ),
        link(
            id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa8",
            url: "https://www.reddit.com/r/ios/comments/demo-tiny-apps/",
            platform: .reddit,
            title: "Tiny iOS Apps With Ridiculous Polish",
            description: "A thread full of small apps with surprisingly thoughtful details and animations.",
            author: "Reddit",
            daysAgo: 7,
            category: ref(designID, "Design", 0.78)
        ),
        link(
            id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa9",
            url: "https://vimeo.com/demo-movie-mood-selector",
            platform: .vimeo,
            title: "Movie Mood Selector Prototype",
            description: "A soft carousel study for choosing what to watch based on emotional tone.",
            author: "Vimeo",
            daysAgo: 8,
            category: ref(moviesID, "Movies", 0.81)
        )
    ]

    private static func category(id: UUID, name: String, color: String) -> Category {
        Category(id: id, name: name, color: color, createdAt: Date(timeIntervalSince1970: 1_767_052_800))
    }

    private static func ref(_ id: UUID, _ name: String, _ confidence: Double) -> CategoryRef {
        CategoryRef(id: id, name: name, confidence: confidence)
    }

    private static func link(
        id: String,
        url: String,
        platform: SourcePlatform,
        title: String,
        description: String,
        author: String,
        daysAgo: Int,
        category: CategoryRef
    ) -> IngestResponse {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return IngestResponse(
            id: UUID(uuidString: id)!,
            sourceURL: url,
            canonicalURL: url,
            sourcePlatform: platform,
            status: .enriched,
            title: title,
            description: description,
            author: author,
            thumbnailURL: nil,
            ingestedAt: date,
            enrichedAt: date,
            categories: [category],
            summarySegments: nil
        )
    }
}
#endif

private struct GeneratedPosterArtwork: View {
    let link: IngestResponse
    let categoryColor: Color

    private var titleWords: [String] {
        let words = link.displayTitle
            .replacingOccurrences(of: ",", with: "")
            .split(separator: " ")
            .map(String.init)
        return Array(words.prefix(4))
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    categoryColor.opacity(0.98),
                    Color.black.opacity(0.72),
                    categoryColor.opacity(0.62)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(.white.opacity(0.14))
                .frame(width: 210, height: 210)
                .offset(x: -86, y: -118)

            Circle()
                .fill(.black.opacity(0.12))
                .frame(width: 250, height: 250)
                .offset(x: 102, y: 130)

            RoundedRectangle(cornerRadius: 80, style: .continuous)
                .fill(.white.opacity(0.12))
                .frame(width: 120, height: 300)
                .rotationEffect(.degrees(-24))
                .offset(x: 116, y: -28)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: link.sourcePlatform.sfSymbol)
                        .font(.system(size: 16, weight: .bold))
                    Text(link.categories.first?.name.uppercased() ?? "SAVED")
                        .font(.system(size: 12, weight: .heavy))
                    Spacer()
                }
                .foregroundStyle(.white.opacity(0.86))

                Spacer()

                VStack(alignment: .leading, spacing: -4) {
                    ForEach(Array(titleWords.enumerated()), id: \.offset) { _, word in
                        Text(word.uppercased())
                            .font(.system(size: 38, weight: .black, design: .rounded))
                            .minimumScaleFactor(0.55)
                            .lineLimit(1)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
                    }
                }

                Text(link.author ?? link.displayDomain ?? "Saved link")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.82))
            }
            .padding(26)
        }
    }
}

private extension Color {
    init?(hex: String?) {
        guard let hex else { return nil }
        let trimmed = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard let value = UInt64(trimmed, radix: 16) else { return nil }

        let red: Double
        let green: Double
        let blue: Double

        switch trimmed.count {
        case 6:
            red = Double((value & 0xFF0000) >> 16) / 255
            green = Double((value & 0x00FF00) >> 8) / 255
            blue = Double(value & 0x0000FF) / 255
        default:
            return nil
        }

        self.init(red: red, green: green, blue: blue)
    }
}

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: Color(.systemBackground).opacity(0.45), location: 0.48),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .init(x: phase, y: 0.5),
                    endPoint: .init(x: phase + 1, y: 0.5)
                )
                .blendMode(.plusLighter)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
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

