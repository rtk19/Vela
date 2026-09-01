import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct VelaScreenBackground: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        environment.theme.backgroundGradient
            .ignoresSafeArea()
    }
}

private struct VelaSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                VelaTheme.surface,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(VelaTheme.border, lineWidth: 1)
            }
    }
}

private struct VelaPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let glow: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(hex: 0x11141C))
            .background {
                LinearGradient(
                    colors: [Color(hex: 0xF7F9FF), Color(hex: 0xCBD3E1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.65), lineWidth: 0.8)
            }
            .shadow(color: glow.opacity(configuration.isPressed ? 0.2 : 0.5), radius: 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.46)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct VelaHeroFade: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.28),
                .init(color: environment.theme.heroTransition.opacity(0.15), location: 0.48),
                .init(color: environment.theme.heroTransition.opacity(0.82), location: 0.76),
                .init(color: environment.theme.heroTransition, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct VelaHeroPageTransition: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: environment.theme.heroTransition, location: 0),
                .init(color: environment.theme.heroTransition.opacity(0.78), location: 0.24),
                .init(color: environment.theme.heroTransition.opacity(0.3), location: 0.62),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct HeroArtworkBoundaryClip: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.clipped()
        } else {
            content
        }
    }
}

private enum MediaArtworkLayout {
    static let shelfPosterWidth: CGFloat = 112
    static let gridSpacing: CGFloat = 12
    static let gridHorizontalPadding: CGFloat = 20
    static let gridColumns = Array(
        repeating: GridItem(.flexible(), spacing: gridSpacing),
        count: 3
    )
}

private extension TrendingTitle {
    var titleTransitionID: String {
        "tmdb:\(kind.rawValue):\(id)"
    }
}

private struct TitleTransitionNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

private final class TitleTransitionSelection: ObservableObject, @unchecked Sendable {
    var titleID: String?
    var sourceID: String?

    func select(titleID: String, sourceID: String) {
        self.titleID = titleID
        self.sourceID = sourceID
    }
}

private struct TitleTransitionSelectionKey: EnvironmentKey {
    static let defaultValue: TitleTransitionSelection? = nil
}

private extension EnvironmentValues {
    var titleTransitionNamespace: Namespace.ID? {
        get { self[TitleTransitionNamespaceKey.self] }
        set { self[TitleTransitionNamespaceKey.self] = newValue }
    }

    var titleTransitionSelection: TitleTransitionSelection? {
        get { self[TitleTransitionSelectionKey.self] }
        set { self[TitleTransitionSelectionKey.self] = newValue }
    }
}

private struct TitleTransitionSourceModifier: ViewModifier {
    @Environment(\.titleTransitionNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var occurrenceID = UUID().uuidString
    let id: String
    let explicitSourceID: String?

    private var sourceID: String {
        explicitSourceID ?? "\(id):occurrence:\(occurrenceID)"
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), !reduceMotion, let namespace {
            content
                .matchedTransitionSource(id: sourceID, in: namespace)
        } else {
            content
        }
    }
}

private struct TitleNavigationTransitionModifier: ViewModifier {
    @Environment(\.titleTransitionNamespace) private var namespace
    @Environment(\.titleTransitionSelection) private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let id: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *),
           !reduceMotion,
           let namespace,
           selection?.titleID == id,
           let sourceID = selection?.sourceID {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            content
        }
    }
}

private extension View {
    func titleTransitionSource(id: String, sourceID: String? = nil) -> some View {
        modifier(TitleTransitionSourceModifier(id: id, explicitSourceID: sourceID))
    }

    func titleNavigationTransition(id: String) -> some View {
        modifier(TitleNavigationTransitionModifier(id: id))
    }

    func velaSurface(cornerRadius: CGFloat = 16) -> some View {
        modifier(VelaSurfaceModifier(cornerRadius: cornerRadius))
    }

    /// Continues the hero's black endpoint below its fixed frame, then reveals
    /// the active theme background without affecting hero layout or interaction.
    func velaHeroPageTransition(height: CGFloat = 140) -> some View {
        overlay(alignment: .bottom) {
            VelaHeroPageTransition()
                .frame(height: height)
                .offset(y: height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

}

private struct DestructiveTrashLabel: View {
    let title: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if let image = UIImage(systemName: "trash")?.withTintColor(
                .systemRed,
                renderingMode: .alwaysOriginal
            ) {
                Image(uiImage: image)
            }
        }
    }
}

private struct MediaTitlePosterActions: View {
    let item: MediaItem
    let onDetails: () -> Void

    var body: some View {
        Button(action: onDetails) {
            Label("Details", systemImage: "info.circle")
        }
        MediaTitleWatchlistAction(item: item)
    }
}

private struct MediaTitleWatchlistAction: View {
    @EnvironmentObject private var library: LibraryStore
    let item: MediaItem

    private var existingWatchlistItem: MediaItem? {
        if let tmdbID = item.tmdbID,
           let match = library.watchlist.first(where: {
               $0.kind == item.kind && $0.tmdbID == tmdbID
           }) {
            return match
        }
        return library.watchlist.first {
            $0.id == item.id && $0.providerID == item.providerID
        }
    }

    var body: some View {
        Button {
            library.toggleWatchlist(existingWatchlistItem ?? item)
        } label: {
            Label(
                existingWatchlistItem == nil ? "Add to Watchlist" : "Remove from Watchlist",
                systemImage: existingWatchlistItem == nil ? "bookmark" : "bookmark.slash"
            )
        }
    }
}

private struct TMDBTitlePosterActions: View {
    @EnvironmentObject private var library: LibraryStore
    let title: TrendingTitle
    let onDetails: () -> Void

    private var existingWatchlistItem: MediaItem? {
        library.watchlist.first {
            $0.kind == title.kind && $0.tmdbID == title.id
        }
    }

    var body: some View {
        Button(action: onDetails) {
            Label("Details", systemImage: "info.circle")
        }
        Button {
            if let existingWatchlistItem {
                library.toggleWatchlist(existingWatchlistItem)
            } else {
                library.toggleWatchlist(.tmdbCatalogItem(from: title))
            }
        } label: {
            Label(
                existingWatchlistItem == nil ? "Add to Watchlist" : "Remove from Watchlist",
                systemImage: existingWatchlistItem == nil ? "bookmark" : "bookmark.slash"
            )
        }
    }
}

struct RootView: View {
    private enum Tab: Hashable { case home, movies, series, search, settings }

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var homeTitleTransitionNamespace
    @Namespace private var movieTitleTransitionNamespace
    @Namespace private var seriesTitleTransitionNamespace
    @Namespace private var searchTitleTransitionNamespace
    @StateObject private var homeTitleTransitionSelection = TitleTransitionSelection()
    @StateObject private var movieTitleTransitionSelection = TitleTransitionSelection()
    @StateObject private var seriesTitleTransitionSelection = TitleTransitionSelection()
    @StateObject private var searchTitleTransitionSelection = TitleTransitionSelection()
    @State private var selectedTab: Tab = .home
    @State private var searchIsPresented = false
    @State private var searchFocusRequest = 0
    @State private var isHomeReady = false
    @State private var pendingAutomaticUpdate: GitHubRelease?
    @State private var automaticUpdateRelease: GitHubRelease?
    @AppStorage("updates.skippedReleaseTag") private var skippedUpdateTag = ""

    var body: some View {
        ZStack {
            VelaScreenBackground()

            TabView(selection: Binding(
                get: { selectedTab },
                set: { tab in
                    selectedTab = tab
                    searchIsPresented = tab == .search
                    if tab == .search { searchFocusRequest += 1 }
                }
            )) {
                NavigationStack { HomeView(onInitialLoadCompleted: showHome) }
                    .environment(\.titleTransitionNamespace, homeTitleTransitionNamespace)
                    .environment(\.titleTransitionSelection, homeTitleTransitionSelection)
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .tag(Tab.home)
                NavigationStack { CatalogView(kind: .movie) }
                    .environment(\.titleTransitionNamespace, movieTitleTransitionNamespace)
                    .environment(\.titleTransitionSelection, movieTitleTransitionSelection)
                    .tabItem { Label("Movies", systemImage: "film.fill") }
                    .tag(Tab.movies)
                NavigationStack { CatalogView(kind: .series) }
                    .environment(\.titleTransitionNamespace, seriesTitleTransitionNamespace)
                    .environment(\.titleTransitionSelection, seriesTitleTransitionSelection)
                    .tabItem { Label("Series", systemImage: "tv.fill") }
                    .tag(Tab.series)
                NavigationStack {
                    SearchView(
                        isSearchPresented: $searchIsPresented,
                        focusRequest: searchFocusRequest
                    )
                }
                    .environment(\.titleTransitionNamespace, searchTitleTransitionNamespace)
                    .environment(\.titleTransitionSelection, searchTitleTransitionSelection)
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(Tab.search)
                NavigationStack { SettingsView() }
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                    .tag(Tab.settings)
            }
            .tint(environment.theme.accent)
            .background {
                TabBarTapObserver(tabIndex: 3) {
                    guard selectedTab == .search else { return }
                    searchFocusRequest += 1
                }
            }
            .overlay(alignment: .top) {
                SourceLookupStatusOverlay()
                    .safeAreaPadding(.top, 8)
                    .zIndex(100)
            }

            if !isHomeReady {
                SplashScreen()
                    .transition(.opacity)
                    .zIndex(200)
            }
        }
        .task { await environment.refreshContinueWatchingForNewEpisodes() }
        .task(id: isHomeReady) {
            guard isHomeReady else { return }
            await environment.preloadPrimaryNavigationArtwork()
        }
        .task { await checkForUpdatesAtLaunch() }
        .task {
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            showHome()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await environment.refreshContinueWatchingForNewEpisodes() }
        }
        .onChange(of: isHomeReady) { _, isReady in
            guard isReady, let release = pendingAutomaticUpdate else { return }
            pendingAutomaticUpdate = nil
            automaticUpdateRelease = release
        }
        .sheet(item: $automaticUpdateRelease) { release in
            UpdateCheckSheet(
                result: .updateAvailable(release),
                onSkipUpdate: {
                    skippedUpdateTag = release.tagName
                    automaticUpdateRelease = nil
                },
                onRemindLater: {
                    automaticUpdateRelease = nil
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func showHome() {
        guard !isHomeReady else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
            isHomeReady = true
        }
    }

    private func checkForUpdatesAtLaunch() async {
        do {
            let release = try await GitHubReleaseClient().latestRelease()
            let currentVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0"
            guard GitHubReleaseClient.shouldOfferUpdate(
                tagName: release.tagName,
                currentVersion: currentVersion,
                skippedTagName: skippedUpdateTag
            ) else { return }

            if isHomeReady {
                automaticUpdateRelease = release
            } else {
                pendingAutomaticUpdate = release
            }
        } catch {
            // Launch should continue normally when the update service is unavailable.
        }
    }
}

private struct SplashScreen: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            environment.theme.backgroundGradient
                .ignoresSafeArea()

            RadialGradient(
                colors: [environment.theme.glow, environment.theme.glow.opacity(0.08), .clear],
                center: .center,
                startRadius: 12,
                endRadius: 180
            )
            .frame(width: 360, height: 360)
            .scaleEffect(isPulsing ? 1.06 : 0.92)
            .opacity(isVisible ? 1 : 0)

            VStack(spacing: 18) {
                Image("VelaLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 172, height: 172)
                    .shadow(color: environment.theme.glow, radius: 22)

                Text("VELA")
                    .font(.system(size: 21, weight: .light, design: .rounded))
                    .tracking(8)
                    .foregroundStyle(VelaTheme.primaryText.opacity(0.9))

                ProgressView()
                    .tint(environment.theme.accentBright)
                    .controlSize(.small)
                    .padding(.top, 10)
            }
            .scaleEffect(isVisible ? (isPulsing ? 1.015 : 1) : 0.9)
            .opacity(isVisible ? 1 : 0)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                value: isPulsing
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading Vela")
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.65)) {
                isVisible = true
            }
            isPulsing = true
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sourceLookup: SourceLookupCoordinator
    let onInitialLoadCompleted: () -> Void
    @StateObject private var model = HomeViewModel()
    @State private var selectedDetails: ResolvedMediaItem?
    @State private var playback: PlaybackRequest?

    init(onInitialLoadCompleted: @escaping () -> Void = {}) {
        self.onInitialLoadCompleted = onInitialLoadCompleted
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if !model.trendingTitles.isEmpty {
                    TrendingHeroCarousel(
                        titles: model.trendingTitles,
                        assets: model.carouselAssets,
                        resolvingKeys: sourceLookup.activeKeys,
                        onDetails: openDetails,
                        onToggleWatchlist: toggleWatchlist
                    )
                    .velaHeroPageTransition()
                } else if model.isTrendingLoading {
                    TrendingHeroLoadingView()
                } else if let message = model.trendingMessage {
                    TrendingHeroUnavailableView(message: message)
                }
                if !library.continueWatching.isEmpty {
                    ContinueWatchingShelfView(
                        progress: library.continueWatching,
                        onDetails: {
                            selectedDetails = ResolvedMediaItem(media: $0, tmdbMetadata: nil)
                        },
                        onResume: { value in
                            playback = PlaybackRequest(media: value.media, episode: value.episode)
                        },
                        onMarkAsWatched: { value in markAsWatched(value) },
                        onRemoveFromContinueWatching: { library.removeProgress($0) }
                    )
                }
                let watchlistSeries = library.watchlist.filter { $0.kind == .series }
                if !watchlistSeries.isEmpty {
                    MediaShelfView(
                        title: "Watchlist Series",
                        items: watchlistSeries,
                        onDetails: openDetails
                    )
                }
                let watchlistMovies = library.watchlist.filter { $0.kind == .movie }
                if !watchlistMovies.isEmpty {
                    MediaShelfView(
                        title: "Watchlist Movies",
                        items: watchlistMovies,
                        onDetails: openDetails
                    )
                }
                ForEach(TMDBCollection.homeSections) { collection in
                    if let titles = model.tmdbShelves[collection], !titles.isEmpty {
                        TMDBShelfView(
                            collection: collection,
                            titles: titles,
                            resolvingKeys: sourceLookup.activeKeys,
                            onSelect: openDetails
                        )
                    }
                }
                ForEach(model.shelves) { shelf in
                    MediaShelfView(title: shelf.title, items: shelf.items, onDetails: openDetails)
                }
            }
            .padding(.bottom)
        }
        .coordinateSpace(name: HeroArtworkScrollEffect.homeCoordinateSpace)
        .background { VelaScreenBackground() }
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await model.loadTrending(environment: environment)
            onInitialLoadCompleted()
        }
        .navigationDestination(for: MediaItem.self) { DetailsView(item: $0) }
        .navigationDestination(item: $selectedDetails) {
            DetailsView(item: $0.media, tmdbMetadata: $0.tmdbMetadata)
        }
        .fullScreenCover(isPresented: Binding(
            get: { playback != nil },
            set: { if !$0 { playback = nil } }
        )) {
            if let playback {
                PlayerScreen(request: playback, nextRequest: nil)
            }
        }
        .errorAlert($model.errorMessage)
    }

    private func openDetails(_ trending: TrendingTitle) {
        selectedDetails = ResolvedMediaItem(
            media: .tmdbCatalogItem(from: trending),
            tmdbMetadata: trending
        )


    }

    private func openDetails(_ item: MediaItem) {
        selectedDetails = ResolvedMediaItem(media: item, tmdbMetadata: nil)
    }

    private func toggleWatchlist(_ trending: TrendingTitle) {
        if let existingItem = library.watchlist.first(where: {
            $0.kind == trending.kind && $0.tmdbID == trending.id
        }) {
            library.toggleWatchlist(existingItem)
            return
        }

        let item = MediaItem.tmdbCatalogItem(from: trending)
        if !library.isInWatchlist(item) {
            library.toggleWatchlist(item)
        }
    }

    private func markAsWatched(_ value: WatchProgress) {
        guard value.episode != nil else { return }
        let request = PlaybackRequest(media: value.media, episode: value.episode)
        library.markWatched(request: request)
        Task {
            if let next = await nextUnwatchedPlaybackRequest(
                after: request,
                environment: environment,
                library: library
            ) {
                library.promoteToContinueWatching(next)
            }
        }
    }
}

private struct TrendingHeroCarousel: View {
    private let interval: TimeInterval = 5

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.titleTransitionSelection) private var transitionSelection
    let titles: [TrendingTitle]
    let assets: TMDBCarouselAssets
    let resolvingKeys: Set<String>
    let onDetails: (TrendingTitle) -> Void
    let onToggleWatchlist: (TrendingTitle) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var currentIndex = 0
    @State private var slideStartedAt = Date()
    @State private var isInteracting = false
    @State private var timerVersion = 0
    @State private var titleContentOffset: CGFloat = 0
    @State private var titleContentOpacity = 1.0
    @State private var indicatorDragProgress: CGFloat = 0

    private var currentTitle: TrendingTitle { titles[currentIndex % titles.count] }
    private var isCurrentTitleResolving: Bool { resolvingKeys.contains(currentTitle.lookupKey) }
    private var isCurrentTitleInWatchlist: Bool {
        library.watchlist.contains {
            $0.kind == currentTitle.kind && $0.tmdbID == currentTitle.id
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let minY = proxy.frame(in: .named(HeroArtworkScrollEffect.homeCoordinateSpace)).minY
            let metrics = HeroArtworkScrollEffect.metrics(minY: minY, reduceMotion: reduceMotion)

            ZStack(alignment: .bottom) {
                ZStack {
                    ForEach(Array(titles.enumerated()), id: \.element.id) { index, title in
                        CenteredHeroArtwork(data: assets.artworkDataByKey[title.lookupKey])
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .opacity(index == currentIndex ? 1 : 0)
                            .animation(crossfadeAnimation, value: currentIndex)
                            .accessibilityHidden(index != currentIndex)
                    }

                    Color.black
                        .opacity(HeroArtworkScrollEffect.maximumDimming * metrics.recessionProgress)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(metrics.scale, anchor: .top)
                .offset(y: metrics.parallaxOffset)
                .modifier(HeroArtworkBoundaryClip(isEnabled: metrics.clipsToHeroBounds))
                .offset(y: metrics.verticalOffset)
                .opacity(metrics.opacity)

                VelaHeroFade()

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: openCurrentDetails)
                    .contextMenu {
                        TMDBTitlePosterActions(title: currentTitle) {
                            openCurrentDetails()
                        }
                    }
                    .accessibilityHidden(true)

                heroContent
                    .padding(.horizontal, 22)
                    .padding(.bottom, 44)

                CarouselPageIndicator(
                    count: titles.count,
                    selectedIndex: currentIndex,
                    startedAt: slideStartedAt,
                    interval: interval,
                    isPaused: isInteracting || scenePhase != .active,
                    dragProgress: indicatorDragProgress
                )
                .padding(.bottom, 18)

                PageTitleOverlay(title: "Home")
                    .offset(y: metrics.verticalOffset)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .containerRelativeFrame(.horizontal, alignment: .center)
        .frame(height: HeroArtworkScrollEffect.heroHeight)
        .titleTransitionSource(
            id: currentTitle.titleTransitionID,
            sourceID: heroTransitionSourceID
        )
        .contentShape(Rectangle())
        .background {
            HorizontalCarouselPanRecognizer(
                onBegan: beginHorizontalInteraction,
                onChanged: updateHorizontalInteraction,
                onEnded: endHorizontalInteraction
            )
        }
        .task(id: timerVersion) {
            guard scenePhase == .active, !isInteracting, titles.count > 1 else { return }
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            select(index: nextIndex)
        }
        .onChange(of: scenePhase) { _, _ in restartTimer() }
        .onChange(of: titles.map(\.id)) { _, _ in
            currentIndex = min(currentIndex, max(titles.count - 1, 0))
            restartTimer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trending: \(currentTitle.title)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: select(index: nextIndex)
            case .decrement: select(index: previousIndex)
            @unknown default: break
            }
        }
    }

    private var heroContent: some View {
        VStack(spacing: 13) {
            Spacer()
            VStack(spacing: 13) {
                Text("TRENDING NOW")
                    .font(.caption2.weight(.bold))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.74))

                TitleLogoView(
                    title: currentTitle.title,
                    logoData: assets.logoDataByKey[currentTitle.lookupKey],
                    showsFallback: true
                ) {
                    Text(currentTitle.title)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                        .contentTransition(.opacity)
                }
                .id(currentTitle.id)

                metadata

                if !currentTitle.overview.isEmpty {
                    Text(currentTitle.overview)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.78))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                }
            }
            .offset(x: titleContentOffset)
            .opacity(titleContentOpacity)

            HStack(spacing: 12) {
                Button {
                    openCurrentDetails()
                } label: {
                    Group {
                        if isCurrentTitleResolving {
                            ProgressView().tint(.black)
                        } else {
                            Text("View Details")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .clipShape(Capsule())
                .allowsHitTesting(!isCurrentTitleResolving)

                Button {
                    onToggleWatchlist(currentTitle)
                } label: {
                    Image(systemName: isCurrentTitleInWatchlist ? "checkmark" : "plus")
                        .font(.title3.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.18))
                .clipShape(Circle())
                .allowsHitTesting(!isCurrentTitleResolving)
                .accessibilityLabel(
                    isCurrentTitleInWatchlist ? "Remove from Watchlist" : "Add to Watchlist"
                )
            }
            .padding(.horizontal, 22)

        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.55), radius: 12, y: 4)
    }

    private var metadata: some View {
        HStack(spacing: 7) {
            Text(currentTitle.kind == .movie ? "Movie" : "TV Show")
            if let year = currentTitle.year {
                Text("·")
                Text(year)
            }
            if let genre = currentTitle.genreNames.first {
                Text("·")
                Text(genre)
            }
            if let rating = currentTitle.rating, rating > 0 {
                Text("·")
                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                    .labelStyle(.titleAndIcon)
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private func openCurrentDetails() {
        guard !isInteracting, !isCurrentTitleResolving else { return }
        transitionSelection?.select(
            titleID: currentTitle.titleTransitionID,
            sourceID: heroTransitionSourceID
        )
        onDetails(currentTitle)
    }

    private var heroTransitionSourceID: String {
        "\(currentTitle.titleTransitionID):home-hero"
    }

    private func beginHorizontalInteraction() {
        guard !isInteracting else { return }
        timerVersion += 1
        isInteracting = true
    }

    private func updateHorizontalInteraction(translation: CGFloat) {
        guard isInteracting else { return }
        let progress = min(abs(translation) / 72, 1)
        indicatorDragProgress = min(max(translation / 72, -1), 1)
        titleContentOffset = reduceMotion ? 0 : translation * 0.34
        titleContentOpacity = 1 - progress
    }

    private func endHorizontalInteraction(translation: CGFloat) {
        guard isInteracting else { return }
        if abs(translation) > 34 {
            let direction: CGFloat = translation < 0 ? -1 : 1
            slideStartedAt = Date()
            withAnimation(nil) {
                currentIndex = direction < 0 ? nextIndex : previousIndex
                indicatorDragProgress = 0
                titleContentOffset = reduceMotion ? 0 : -direction * 28
                titleContentOpacity = reduceMotion ? 1 : 0
                isInteracting = false
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                titleContentOffset = 0
                titleContentOpacity = 1
            }
            timerVersion += 1
        } else {
            isInteracting = false
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
                indicatorDragProgress = 0
                titleContentOffset = 0
                titleContentOpacity = 1
            }
            restartTimer()
        }
    }

    private var nextIndex: Int { (currentIndex + 1) % titles.count }
    private var previousIndex: Int { (currentIndex - 1 + titles.count) % titles.count }
    private var crossfadeAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.72) }

    private func select(index: Int) {
        slideStartedAt = Date()
        withAnimation(crossfadeAnimation) { currentIndex = index }
        timerVersion += 1
    }

    private func restartTimer() {
        slideStartedAt = Date()
        timerVersion += 1
    }

}

private struct TitleLogoView<Fallback: View>: View {
    private let maximumLogoWidth: CGFloat = 300
    private let maximumLogoHeight: CGFloat = 88

    let title: String
    let logoData: Data?
    let showsFallback: Bool
    let fallback: Fallback

    init(
        title: String,
        logoData: Data?,
        showsFallback: Bool,
        @ViewBuilder fallback: () -> Fallback
    ) {
        self.title = title
        self.logoData = logoData
        self.showsFallback = showsFallback
        self.fallback = fallback()
    }

    var body: some View {
        let logoImage = logoData.flatMap(UIImage.init(data:))

        Group {
            if let logoImage {
                Image(uiImage: logoImage)
                    .resizable()
                    .scaledToFit()
                    .frame(
                        maxWidth: maximumLogoWidth,
                        maxHeight: maximumLogoHeight
                    )
                    .accessibilityHidden(true)
            } else if showsFallback {
                fallback
            } else {
                Color.clear
            }
        }
            // Reserve one consistent, generously sized logo region. The old
            // overlay inherited the fallback title's intrinsic width, making a
            // short title such as "Silo" much smaller than longer title logos.
            .frame(maxWidth: maximumLogoWidth, minHeight: maximumLogoHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }
}

private struct CenteredHeroArtwork: View {
    let data: Data?

    var body: some View {
        Color.clear
            .overlay {
                Group {
                    if let data, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else {
                        Rectangle().fill(.gray.opacity(0.16))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .clipped()
    }
}

private struct CarouselPageIndicator: View {
    private let collapsedWidth: CGFloat = 7
    private let expandedWidth: CGFloat = 42

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let count: Int
    let selectedIndex: Int
    let startedAt: Date
    let interval: TimeInterval
    let isPaused: Bool
    let dragProgress: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: isPaused)) { context in
            let progress = min(max(context.date.timeIntervalSince(startedAt) / interval, 0), 1)
            HStack(spacing: 8) {
                ForEach(0..<count, id: \.self) { index in
                    let emphasis = emphasis(for: index)
                    GeometryReader { geometry in
                        Capsule()
                            .fill(.white.opacity(inactiveOpacity(for: emphasis)))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(.white)
                                    .frame(
                                        width: geometry.size.width * fillProgress(
                                            for: index,
                                            timerProgress: progress
                                        )
                                    )
                            }
                            .clipShape(Capsule())
                    }
                    .frame(width: width(for: emphasis), height: collapsedWidth)
                    .animation(settleAnimation, value: selectedIndex)
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private var dragAmount: CGFloat {
        min(abs(dragProgress), 1)
    }

    private var dragTargetIndex: Int? {
        guard count > 1, dragAmount > 0 else { return nil }
        return dragProgress < 0
            ? (selectedIndex + 1) % count
            : (selectedIndex - 1 + count) % count
    }

    private func emphasis(for index: Int) -> CGFloat {
        if index == selectedIndex { return 1 - dragAmount }
        if index == dragTargetIndex { return dragAmount }
        return 0
    }

    private func width(for emphasis: CGFloat) -> CGFloat {
        collapsedWidth + ((expandedWidth - collapsedWidth) * emphasis)
    }

    private func inactiveOpacity(for emphasis: CGFloat) -> Double {
        0.48 - (0.20 * Double(emphasis))
    }

    private func fillProgress(for index: Int, timerProgress: CGFloat) -> CGFloat {
        index == selectedIndex ? timerProgress : 0
    }

    private var settleAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.38)
    }
}

private struct TrendingHeroLoadingView: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(.gray.opacity(0.12))
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
            ProgressView("Loading trends from TMDB…")
                .tint(.white)
                .foregroundStyle(.white.opacity(0.72))
                .padding(.bottom, 54)
            PageTitleOverlay(title: "Home")
        }
        .containerRelativeFrame(.horizontal, alignment: .center)
        .frame(height: HeroArtworkScrollEffect.heroHeight)
    }
}

private struct PageTitleOverlay: View {
    let title: String

    var body: some View {
        VStack {
            PageTitleText(title: title)
                .padding(.top, 58)
            Spacer()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PageTitleHeader: View {
    let title: String

    var body: some View {
        PageTitleText(title: title)
            .padding(.top, 58)
            .padding(.bottom, 12)
    }
}

private struct PageTitleText: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 12, y: 3)
            Spacer()
        }
        .padding(.horizontal, 20)
    }
}

private struct HorizontalCarouselPanRecognizer: UIViewRepresentable {
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onChanged: onChanged, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.onWindowChanged = { [weak coordinator = context.coordinator] marker in
            coordinator?.install(marker: marker)
        }
        return view
    }

    func updateUIView(_ uiView: AttachmentView, context: Context) {
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.install(marker: uiView)
    }

    static func dismantleUIView(_ uiView: AttachmentView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class AttachmentView: UIView {
        var onWindowChanged: ((AttachmentView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChanged?(self)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBegan: () -> Void
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat) -> Void
        private weak var host: UIView?
        private weak var marker: AttachmentView?
        private lazy var pan: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            return recognizer
        }()

        init(
            onBegan: @escaping () -> Void,
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat) -> Void
        ) {
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func install(marker: AttachmentView) {
            self.marker = marker
            guard let window = marker.window, host !== window else { return }
            uninstall()
            self.marker = marker
            host = window
            window.addGestureRecognizer(pan)
        }

        func uninstall() {
            host?.removeGestureRecognizer(pan)
            host = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let marker,
                  marker.window != nil,
                  marker.bounds.contains(pan.location(in: marker)) else { return false }
            let velocity = pan.velocity(in: marker)
            return abs(velocity.x) > abs(velocity.y) * 1.1
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                onBegan()
            case .changed:
                onChanged(recognizer.translation(in: recognizer.view).x)
            case .ended:
                onEnded(recognizer.translation(in: recognizer.view).x)
            case .cancelled, .failed:
                onEnded(0)
            default:
                break
            }
        }
    }
}

private struct TabBarTapObserver: UIViewRepresentable {
    let tabIndex: Int
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(tabIndex: tabIndex, onTap: onTap)
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.onWindowChanged = { [weak coordinator = context.coordinator] marker in
            coordinator?.install(marker: marker)
        }
        return view
    }

    func updateUIView(_ uiView: AttachmentView, context: Context) {
        context.coordinator.tabIndex = tabIndex
        context.coordinator.onTap = onTap
        context.coordinator.install(marker: uiView)
    }

    static func dismantleUIView(_ uiView: AttachmentView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class AttachmentView: UIView {
        var onWindowChanged: ((AttachmentView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChanged?(self)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var tabIndex: Int
        var onTap: () -> Void
        private weak var tabBar: UITabBar?
        private weak var marker: AttachmentView?
        private lazy var tap: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            return recognizer
        }()

        init(tabIndex: Int, onTap: @escaping () -> Void) {
            self.tabIndex = tabIndex
            self.onTap = onTap
        }

        func install(marker: AttachmentView) {
            self.marker = marker
            guard let window = marker.window,
                  let candidate = findTabBarController(in: window.rootViewController)?.tabBar,
                  tabBar !== candidate else { return }
            uninstall()
            self.marker = marker
            tabBar = candidate
            candidate.addGestureRecognizer(tap)
        }

        func uninstall() {
            tabBar?.removeGestureRecognizer(tap)
            tabBar = nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let tabBar,
                  let items = tabBar.items,
                  items.indices.contains(tabIndex),
                  tappedTabIndex(in: tabBar, itemCount: items.count, recognizer: recognizer) == tabIndex
            else { return }
            onTap()
        }

        private func tappedTabIndex(
            in tabBar: UITabBar,
            itemCount: Int,
            recognizer: UITapGestureRecognizer
        ) -> Int? {
            let location = recognizer.location(in: tabBar)
            let controls = tabBar.subviews
                .compactMap { $0 as? UIControl }
                .filter { !$0.isHidden && $0.alpha > 0 && $0.frame.contains(location) }

            if let tappedControl = controls.first {
                let orderedControls = tabBar.subviews
                    .compactMap { $0 as? UIControl }
                    .filter { !$0.isHidden && $0.alpha > 0 }
                    .sorted { $0.frame.minX < $1.frame.minX }
                guard let visualIndex = orderedControls.firstIndex(where: { $0 === tappedControl }) else {
                    return nil
                }
                return logicalIndex(forVisualIndex: visualIndex, itemCount: itemCount, in: tabBar)
            }

            guard itemCount > 0, tabBar.bounds.width > 0 else { return nil }
            let visualIndex = min(
                Int(location.x / (tabBar.bounds.width / CGFloat(itemCount))),
                itemCount - 1
            )
            return logicalIndex(forVisualIndex: visualIndex, itemCount: itemCount, in: tabBar)
        }

        private func logicalIndex(forVisualIndex visualIndex: Int, itemCount: Int, in view: UIView) -> Int {
            view.effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? itemCount - visualIndex - 1
                : visualIndex
        }

        private func findTabBarController(in viewController: UIViewController?) -> UITabBarController? {
            guard let viewController else { return nil }
            if let tabBarController = viewController as? UITabBarController {
                return tabBarController
            }
            for child in viewController.children {
                if let match = findTabBarController(in: child) { return match }
            }
            if let presented = viewController.presentedViewController {
                return findTabBarController(in: presented)
            }
            return nil
        }
    }
}

private struct TrendingHeroUnavailableView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 34))
            Text("Trending on TMDB")
                .font(.title3.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("TMDB is temporarily unavailable. Pull to refresh and try again.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal)
    }
}

private struct ContinueWatchingShelfView: View {
    @Environment(\.titleTransitionSelection) private var transitionSelection
    let progress: [WatchProgress]
    let onDetails: (MediaItem) -> Void
    let onResume: (WatchProgress) -> Void
    let onMarkAsWatched: (WatchProgress) -> Void
    let onRemoveFromContinueWatching: (WatchProgress) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Continue Watching")
                    .font(.title2.bold())
                Spacer()
                NavigationLink {
                    ContinueWatchingListView(
                        onResume: onResume,
                        onMarkAsWatched: onMarkAsWatched,
                        onRemoveFromContinueWatching: onRemoveFromContinueWatching
                    )
                } label: {
                    Text("Show All")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(progress) { value in
                        Button { onResume(value) } label: {
                            ContinueWatchingCard(progress: value)
                                .titleTransitionSource(
                                    id: value.media.artworkIdentityKey,
                                    sourceID: transitionSourceID(for: value)
                                )
                                .contextMenu {
                                    ContinueWatchingActions(
                                        progress: value,
                                        onDetails: { _ in showDetails(value) },
                                        onResume: onResume,
                                        onMarkAsWatched: onMarkAsWatched,
                                        onRemoveFromContinueWatching: onRemoveFromContinueWatching
                                    )
                                } preview: {
                                    ContinueWatchingMenuPreview(progress: value)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func transitionSourceID(for progress: WatchProgress) -> String {
        "\(progress.media.artworkIdentityKey):continue-watching-shelf:\(progress.id)"
    }

    private func showDetails(_ progress: WatchProgress) {
        transitionSelection?.select(
            titleID: progress.media.artworkIdentityKey,
            sourceID: transitionSourceID(for: progress)
        )
        onDetails(progress.media)
    }
}

private struct ContinueWatchingListView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var selectedDetails: ResolvedMediaItem?
    let onResume: (WatchProgress) -> Void
    let onMarkAsWatched: (WatchProgress) -> Void
    let onRemoveFromContinueWatching: (WatchProgress) -> Void

    var body: some View {
        Group {
            if library.continueWatching.isEmpty {
                ContentUnavailableView(
                    "Nothing to Continue",
                    systemImage: "play.rectangle",
                    description: Text("Movies and episodes you start will appear here.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(library.continueWatching) { value in
                            ContinueWatchingRow(
                                progress: value,
                                onDetails: {
                                    selectedDetails = ResolvedMediaItem(
                                        media: $0,
                                        tmdbMetadata: nil
                                    )
                                },
                                onResume: onResume,
                                onMarkAsWatched: onMarkAsWatched,
                                onRemoveFromContinueWatching: onRemoveFromContinueWatching
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { VelaScreenBackground() }
        .navigationTitle("Continue Watching")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedDetails) {
            DetailsView(item: $0.media, tmdbMetadata: $0.tmdbMetadata)
        }
    }
}

private struct ContinueWatchingRow: View {
    @Environment(\.titleTransitionSelection) private var transitionSelection
    @State private var transitionOccurrenceID = UUID().uuidString
    let progress: WatchProgress
    let onDetails: (MediaItem) -> Void
    let onResume: (WatchProgress) -> Void
    let onMarkAsWatched: (WatchProgress) -> Void
    let onRemoveFromContinueWatching: (WatchProgress) -> Void

    private var transitionSourceID: String {
        "\(progress.media.artworkIdentityKey):continue-watching-list:\(transitionOccurrenceID)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { onResume(progress) } label: {
                HStack(spacing: 14) {
                    ContinueWatchingRowArtwork(progress: progress)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(progress.media.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let episodeTitle = progress.episodeDisplayTitle {
                            Text(episodeTitle)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.78))
                                .lineLimit(1)
                        }
                        Text(progress.shelfProgressLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.58))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .contextMenu {
                    ContinueWatchingActions(
                        progress: progress,
                        onDetails: { _ in showDetails() },
                        onResume: onResume,
                        onMarkAsWatched: onMarkAsWatched,
                        onRemoveFromContinueWatching: onRemoveFromContinueWatching
                    )
                } preview: {
                    ContinueWatchingMenuPreview(progress: progress)
                }
            }
            .buttonStyle(.plain)

            Menu {
                ContinueWatchingActions(
                    progress: progress,
                    onDetails: { _ in showDetails() },
                    onResume: onResume,
                    onMarkAsWatched: onMarkAsWatched,
                    onRemoveFromContinueWatching: onRemoveFromContinueWatching
                )
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Options for \(progress.media.title)")
        }
        .padding(12)
        .velaSurface(cornerRadius: 16)
        .contentShape(Rectangle())
        .titleTransitionSource(
            id: progress.media.artworkIdentityKey,
            sourceID: transitionSourceID
        )
    }

    private func showDetails() {
        transitionSelection?.select(
            titleID: progress.media.artworkIdentityKey,
            sourceID: transitionSourceID
        )
        onDetails(progress.media)
    }
}

private struct ContinueWatchingRowArtwork: View {
    @EnvironmentObject private var environment: AppEnvironment
    let progress: WatchProgress

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedRemoteImage(url: progress.continueWatchingArtworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle()
                    .fill(.gray.opacity(0.22))
                    .overlay {
                        Image(systemName: progress.media.kind == .movie ? "film" : "tv")
                    }
            }
            .frame(width: 128, height: 74)
            .clipped()

            ProgressView(value: progress.fraction)
                .tint(environment.theme.accent)
                .background(.white.opacity(0.28))
                .frame(maxWidth: .infinity)
        }
        .frame(width: 128, height: 74)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ContinueWatchingActions: View {
    let progress: WatchProgress
    let onDetails: (MediaItem) -> Void
    let onResume: (WatchProgress) -> Void
    let onMarkAsWatched: (WatchProgress) -> Void
    let onRemoveFromContinueWatching: (WatchProgress) -> Void

    var body: some View {
        Button { onDetails(progress.media) } label: {
            Label("Details", systemImage: "info.circle")
        }
        MediaTitleWatchlistAction(item: progress.media)
        Button { onResume(progress) } label: {
            Label(progress.isNextUp ? "Play Next" : "Resume", systemImage: "play.fill")
        }
        if progress.episode != nil {
            Button { onMarkAsWatched(progress) } label: {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }
        }
        Button(role: .destructive) {
            onRemoveFromContinueWatching(progress)
        } label: {
            DestructiveTrashLabel(title: "Remove from Continue Watching")
        }
        .tint(.red)
    }
}

private struct ContinueWatchingMenuPreview: View {
    let progress: WatchProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AsyncImage(url: progress.continueWatchingArtworkURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.gray.opacity(0.22))
                        .overlay {
                            if phase.error == nil {
                                ProgressView()
                            } else {
                                Image(systemName: progress.media.kind == .movie ? "film" : "tv")
                                    .font(.largeTitle)
                            }
                        }
                }
            }
            .frame(width: 300, height: 169)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(progress.media.title)
                .font(.headline)
                .lineLimit(1)
            if let episodeTitle = progress.episodeDisplayTitle {
                Text(episodeTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(progress.shelfProgressLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 328, alignment: .leading)
        .background(VelaTheme.surface)
    }
}

private struct ContinueWatchingCard: View {
    @EnvironmentObject private var environment: AppEnvironment
    let progress: WatchProgress
    private let width: CGFloat = 276
    private let imageHeight: CGFloat = 158

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottom) {
                CachedRemoteImage(url: progress.continueWatchingArtworkURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle()
                        .fill(.gray.opacity(0.22))
                        .overlay {
                            Image(systemName: progress.media.kind == .movie ? "film" : "tv")
                                .font(.title)
                        }
                }
                .frame(width: width, height: imageHeight)
                .clipped()

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.28),
                        .init(color: .black.opacity(0.35), location: 0.58),
                        .init(color: .black.opacity(0.92), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 3) {
                    Spacer()
                    Text(progress.media.title)
                        .font(.headline.bold())
                        .lineLimit(1)
                    if let episodeTitle = progress.episodeDisplayTitle {
                        Text(episodeTitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                    }
                    Text(progress.shelfProgressLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(1)
                    ProgressView(value: progress.fraction)
                        .tint(environment.theme.accent)
                        .background(.white.opacity(0.25))
                        .clipShape(Capsule())
                        .padding(.top, 5)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 9)

                if progress.isNextUp {
                    VStack {
                        HStack {
                            Spacer()
                            Text("Next Up")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
                        }
                        Spacer()
                    }
                    .padding(10)
                }
            }
            .frame(width: width, height: imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(VelaTheme.border, lineWidth: 1)
            }
            .shadow(color: environment.theme.glow.opacity(0.24), radius: 10, y: 4)
        }
        .frame(width: width, alignment: .leading)
        .foregroundStyle(.white)
        .contentShape(Rectangle())
    }
}

private extension WatchProgress {
    var continueWatchingArtworkURL: URL? {
        episode?.posterURL ?? media.backdropURL ?? media.posterURL
    }

    var episodeDisplayTitle: String? {
        guard let episode else { return nil }
        let title = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : "Episode \(episode.number)"
    }
}

struct MediaShelfView: View {
    @Environment(\.titleTransitionSelection) private var transitionSelection
    let title: String
    let items: [MediaItem]
    var progress: [WatchProgress] = []
    var onDetails: ((MediaItem) -> Void)?
    var onResume: ((WatchProgress) -> Void)?
    var onRemoveFromContinueWatching: ((WatchProgress) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                NavigationLink {
                    MediaGridView(
                        title: title,
                        items: items,
                        progress: progress,
                        onDetails: onDetails,
                        onResume: onResume,
                        onRemoveFromContinueWatching: onRemoveFromContinueWatching
                    )
                } label: {
                    Text("Show All")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { item in
                        let itemProgress = progress.first(where: {
                            $0.media.id == item.id && $0.providerID == item.providerID
                        })
                        Button { open(item) } label: {
                            PosterCard(
                                item: item,
                                progress: itemProgress?.fraction,
                                progressDetail: itemProgress?.shelfProgressLabel
                            )
                            .titleTransitionSource(
                                id: item.artworkIdentityKey,
                                sourceID: transitionSourceID(for: item)
                            )
                            .contextMenu {
                                MediaTitlePosterActions(item: item) {
                                    open(item)
                                }
                                if let itemProgress {
                                    Button {
                                        onResume?(itemProgress)
                                    } label: {
                                        Label("Resume", systemImage: "play.fill")
                                    }
                                    Button(role: .destructive) {
                                        onRemoveFromContinueWatching?(itemProgress)
                                    } label: {
                                        DestructiveTrashLabel(title: "Remove from Continue Watching")
                                    }
                                    .tint(.red)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func transitionSourceID(for item: MediaItem) -> String {
        "\(item.artworkIdentityKey):media-shelf:\(title)"
    }

    private func open(_ item: MediaItem) {
        transitionSelection?.select(
            titleID: item.artworkIdentityKey,
            sourceID: transitionSourceID(for: item)
        )
        onDetails?(item)
    }
}

private struct MediaGridView: View {
    @Environment(\.titleTransitionSelection) private var transitionSelection
    let title: String
    let items: [MediaItem]
    let progress: [WatchProgress]
    let onDetails: ((MediaItem) -> Void)?
    let onResume: ((WatchProgress) -> Void)?
    let onRemoveFromContinueWatching: ((WatchProgress) -> Void)?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: MediaArtworkLayout.gridColumns, alignment: .leading, spacing: 16) {
                ForEach(items) { item in
                    let itemProgress = progress.first {
                        $0.media.id == item.id && $0.providerID == item.providerID
                    }
                    Button { open(item) } label: {
                        PosterGridCard(
                            item: item,
                            progress: itemProgress?.fraction,
                            progressDetail: itemProgress?.shelfProgressLabel
                        )
                        .titleTransitionSource(
                            id: item.artworkIdentityKey,
                            sourceID: transitionSourceID(for: item)
                        )
                        .contextMenu {
                            MediaTitlePosterActions(item: item) {
                                open(item)
                            }
                            if let itemProgress {
                                Button { onResume?(itemProgress) } label: {
                                    Label("Resume", systemImage: "play.fill")
                                }
                                Button(role: .destructive) {
                                    onRemoveFromContinueWatching?(itemProgress)
                                } label: {
                                    DestructiveTrashLabel(title: "Remove from Continue Watching")
                                }
                                .tint(.red)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, MediaArtworkLayout.gridHorizontalPadding)
            .padding(.vertical)
        }
        .background { VelaScreenBackground() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func transitionSourceID(for item: MediaItem) -> String {
        "\(item.artworkIdentityKey):media-grid:\(title)"
    }

    private func open(_ item: MediaItem) {
        transitionSelection?.select(
            titleID: item.artworkIdentityKey,
            sourceID: transitionSourceID(for: item)
        )
        onDetails?(item)
    }
}

struct PosterCard: View {
    let item: MediaItem
    var progress: Double?
    var progressDetail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottom) {
                CanonicalPosterArtwork(item: item)
                .frame(
                    width: MediaArtworkLayout.shelfPosterWidth,
                    height: MediaArtworkLayout.shelfPosterWidth * 1.5
                )
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
                if let progress {
                    GeometryReader { geometry in
                        VStack { Spacer(); Rectangle().fill(.tint).frame(width: geometry.size.width * progress, height: 4) }
                    }
                }
            }
            Text(item.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .frame(width: MediaArtworkLayout.shelfPosterWidth, alignment: .leading)
            if let progressDetail {
                Text(progressDetail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: MediaArtworkLayout.shelfPosterWidth, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
    }
}

private struct PosterGridCard: View {
    let item: MediaItem
    var progress: Double?
    var progressDetail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                CanonicalPosterArtwork(item: item)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if let progress {
                    ProgressView(value: progress)
                        .background(.black.opacity(0.5))
                }
            }
            Text(item.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let progressDetail {
                Text(progressDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
    }
}

private struct CachedRemoteImage<Content: View, Placeholder: View>: View {
    @EnvironmentObject private var environment: AppEnvironment
    let url: URL?
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder
    @State private var loadedURL: URL?
    @State private var image: UIImage?

    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let displayedImage {
                content(Image(uiImage: displayedImage))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            if loadedURL != url {
                loadedURL = nil
                image = nil
            }
            guard let url else { return }
            if let cached = environment.cachedImageIfAvailable(for: url) {
                image = cached
                loadedURL = url
                return
            }
            guard let loadedImage = try? await environment.cachedImage(for: url),
                  !Task.isCancelled else { return }
            image = loadedImage
            loadedURL = url
        }
    }

    private var displayedImage: UIImage? {
        if loadedURL == url, let image { return image }
        return environment.cachedImageIfAvailable(for: url)
    }
}

private struct CanonicalPosterArtwork: View {
    @EnvironmentObject private var environment: AppEnvironment
    let item: MediaItem
    @State private var posterURL: URL?

    var body: some View {
        CachedRemoteImage(url: posterURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.gray.opacity(0.22))
                .overlay { Image(systemName: item.kind == .movie ? "film" : "tv") }
        }
        .task(id: item.artworkIdentityKey) {
            posterURL = await environment.canonicalPosterURL(for: item)
        }
    }
}

private struct TMDBShelfView: View {
    @Environment(\.titleTransitionSelection) private var transitionSelection
    let collection: TMDBCollection
    let titles: [TrendingTitle]
    let resolvingKeys: Set<String>
    let onSelect: (TrendingTitle) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(collection.title).font(.title3.bold())
                Spacer()
                NavigationLink {
                    TMDBCollectionGridView(collection: collection)
                } label: {
                    Text("Show All")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(titles) { title in
                        Button { open(title) } label: {
                            TMDBPosterCard(title: title, width: MediaArtworkLayout.shelfPosterWidth)
                                .overlay {
                                    if resolvingKeys.contains(title.lookupKey) {
                                        ProgressView()
                                            .tint(.white)
                                            .controlSize(.large)
                                            .padding(12)
                                            .background(.black.opacity(0.72), in: Circle())
                                    }
                                }
                                .titleTransitionSource(
                                    id: title.titleTransitionID,
                                    sourceID: transitionSourceID(for: title)
                                )
                                .contextMenu {
                                    TMDBTitlePosterActions(title: title) {
                                        open(title)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(!resolvingKeys.contains(title.lookupKey))
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func transitionSourceID(for title: TrendingTitle) -> String {
        "\(title.titleTransitionID):tmdb-shelf:\(collection.id)"
    }

    private func open(_ title: TrendingTitle) {
        transitionSelection?.select(
            titleID: title.titleTransitionID,
            sourceID: transitionSourceID(for: title)
        )
        onSelect(title)
    }
}

private struct TMDBPosterCard: View {
    let title: TrendingTitle
    let width: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedRemoteImage(url: title.posterURL ?? title.backdropURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(.gray.opacity(0.22))
                    .overlay { Image(systemName: title.kind == .movie ? "film" : "tv") }
            }
            .aspectRatio(2 / 3, contentMode: .fit)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : width)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(title.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .frame(width: width, alignment: .leading)
                .frame(maxWidth: width == nil ? .infinity : width, alignment: .leading)
        }
        .frame(maxWidth: width == nil ? .infinity : width, alignment: .leading)
        .foregroundStyle(.white)
    }
}

private struct SourceLookupStatusOverlay: View {
    @EnvironmentObject private var sourceLookup: SourceLookupCoordinator

    var body: some View {
        VStack(spacing: 8) {
            if let failure = sourceLookup.failure {
                SourceLookupFailureBanner(failure: failure)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if sourceLookup.activeCount > 0 {
                SourceLookupProgressBanner(count: sourceLookup.activeCount) {
                    sourceLookup.cancelAll()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: sourceLookup.failure?.id)
        .animation(.easeInOut(duration: 0.22), value: sourceLookup.activeCount)
    }
}

private struct SourceLookupProgressBanner: View {
    let count: Int
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            ProgressView()
                .tint(.white)
                .controlSize(.large)

            VStack(alignment: .leading, spacing: 3) {
                Text("Please wait, looking for sources…")
                    .font(.subheadline.weight(.semibold))
                Text(count > 1 ? String(count) + " searches in progress. This can take up to a minute." : "This can take up to a minute.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            }

            Spacer(minLength: 8)

            Button(count > 1 ? "Cancel All" : "Cancel", action: onCancel)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
    }
}

private struct SourceLookupFailureBanner: View {
    let failure: SourceLookupFailure

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                Text(failure.title)
                    .font(.subheadline.weight(.semibold))
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(3)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .padding(.horizontal, 12)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

private struct TMDBCollectionGridView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sourceLookup: SourceLookupCoordinator
    @Environment(\.titleTransitionSelection) private var transitionSelection
    @StateObject private var model = TMDBCollectionGridViewModel()
    @State private var selectedDetails: ResolvedMediaItem?
    let collection: TMDBCollection

    var body: some View {
        ScrollView {
            LazyVGrid(columns: MediaArtworkLayout.gridColumns, alignment: .leading, spacing: 16) {
                ForEach(model.titles) { title in
                    Button { open(title) } label: {
                        TMDBPosterCard(title: title, width: nil)
                            .overlay {
                                if sourceLookup.activeKeys.contains(title.lookupKey) {
                                    ProgressView()
                                        .tint(.white)
                                        .controlSize(.large)
                                        .padding(10)
                                        .background(.black.opacity(0.72), in: Circle())
                                }
                            }
                            .titleTransitionSource(
                                id: title.titleTransitionID,
                                sourceID: transitionSourceID(for: title)
                            )
                            .contextMenu {
                                TMDBTitlePosterActions(title: title) {
                                    open(title)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(!sourceLookup.activeKeys.contains(title.lookupKey))
                    .onAppear {
                        if title == model.titles.last {
                            Task { await model.loadNext(collection: collection, environment: environment) }
                        }
                    }
                }
            }
            .padding(.horizontal, MediaArtworkLayout.gridHorizontalPadding)
            .padding(.vertical)
            if model.isLoading { ProgressView().padding() }
        }
        .background { VelaScreenBackground() }
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedDetails) {
            DetailsView(item: $0.media, tmdbMetadata: $0.tmdbMetadata)
        }
        .task { await model.loadNext(collection: collection, environment: environment) }
        .errorAlert($model.errorMessage)
    }

    private func open(_ title: TrendingTitle) {
        transitionSelection?.select(
            titleID: title.titleTransitionID,
            sourceID: transitionSourceID(for: title)
        )
        selectedDetails = ResolvedMediaItem(media: .tmdbCatalogItem(from: title), tmdbMetadata: title)
    }

    private func transitionSourceID(for title: TrendingTitle) -> String {
        "\(title.titleTransitionID):tmdb-grid:\(collection.id)"
    }
}

struct CatalogView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sourceLookup: SourceLookupCoordinator
    @StateObject private var model: TMDBCollectionsViewModel
    @State private var selectedDetails: ResolvedMediaItem?
    let kind: MediaKind

    init(kind: MediaKind) {
        self.kind = kind
        _model = StateObject(wrappedValue: TMDBCollectionsViewModel(
            collections: TMDBCollection.catalogSections(for: kind)
        ))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                PageTitleHeader(title: kind == .movie ? "Movies" : "Series")
                ForEach(model.collections) { collection in
                    if let titles = model.titles[collection], !titles.isEmpty {
                        TMDBShelfView(
                            collection: collection,
                            titles: titles,
                            resolvingKeys: sourceLookup.activeKeys,
                            onSelect: open
                        )
                    }
                }
            }
            .padding(.bottom)
        }
        .background { VelaScreenBackground() }
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .overlay { if model.isLoading && model.titles.isEmpty { ProgressView("Loading TMDB…") } }
        .navigationDestination(item: $selectedDetails) {
            DetailsView(item: $0.media, tmdbMetadata: $0.tmdbMetadata)
        }
        .task { await model.load(environment: environment) }
        .refreshable { await model.load(environment: environment, force: true) }
        .errorAlert($model.errorMessage)
    }

    private func open(_ title: TrendingTitle) {
        selectedDetails = ResolvedMediaItem(media: .tmdbCatalogItem(from: title), tmdbMetadata: title)
    }
}

struct SearchView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sourceLookup: SourceLookupCoordinator
    @Environment(\.titleTransitionSelection) private var transitionSelection
    @StateObject private var model = SearchViewModel()
    @StateObject private var discovery = TMDBCollectionsViewModel(
        collections: [.trending(.series), .trending(.movie)]
    )
    @State private var selectedDetails: ResolvedMediaItem?
    @FocusState private var searchFieldIsFocused: Bool
    @Binding var isSearchPresented: Bool
    let focusRequest: Int

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                PageTitleHeader(title: "Search")

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Movies and series", text: $model.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($searchFieldIsFocused)
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 20)

                if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Discover")
                        .font(.title2.bold())
                        .padding(.horizontal, 20)
                    ForEach(discovery.collections) { collection in
                        if let titles = discovery.titles[collection], !titles.isEmpty {
                            TMDBShelfView(
                                collection: collection,
                                titles: titles,
                                resolvingKeys: sourceLookup.activeKeys,
                                onSelect: open
                            )
                        }
                    }
                } else {
                    LazyVGrid(
                        columns: MediaArtworkLayout.gridColumns,
                        alignment: .leading,
                        spacing: 16
                    ) {
                        ForEach(model.results) { item in
                            Button { open(item) } label: {
                                PosterGridCard(item: item)
                                    .titleTransitionSource(
                                        id: item.artworkIdentityKey,
                                        sourceID: transitionSourceID(for: item)
                                    )
                                    .contextMenu {
                                        MediaTitlePosterActions(item: item) {
                                            open(item)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, MediaArtworkLayout.gridHorizontalPadding)
                }
            }
            .padding(.bottom)
        }
        .scrollDismissesKeyboard(.interactively)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background { VelaScreenBackground() }
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: model.query) { _, _ in model.search(environment: environment) }
        .onChange(of: isSearchPresented) { _, presented in
            if presented { searchFieldIsFocused = true }
        }
        .onChange(of: focusRequest) { _, _ in
            searchFieldIsFocused = true
        }
        .overlay {
            if model.isLoading || (
                model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && discovery.isLoading
                    && discovery.titles.isEmpty
            ) {
                ProgressView()
            }
        }
        .navigationDestination(for: MediaItem.self) { DetailsView(item: $0) }
        .navigationDestination(item: $selectedDetails) {
            DetailsView(item: $0.media, tmdbMetadata: $0.tmdbMetadata)
        }
        .task {
            if isSearchPresented { searchFieldIsFocused = true }
            await discovery.load(environment: environment)
        }
        .errorAlert($model.errorMessage)
        .errorAlert($discovery.errorMessage)
    }

    private func open(_ title: TrendingTitle) {
        selectedDetails = ResolvedMediaItem(media: .tmdbCatalogItem(from: title), tmdbMetadata: title)
    }

    private func open(_ item: MediaItem) {
        transitionSelection?.select(
            titleID: item.artworkIdentityKey,
            sourceID: transitionSourceID(for: item)
        )
        selectedDetails = ResolvedMediaItem(media: item, tmdbMetadata: nil)
    }

    private func transitionSourceID(for item: MediaItem) -> String {
        "\(item.artworkIdentityKey):search-grid"
    }
}

struct DetailsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sourceLookup: SourceLookupCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model: DetailsViewModel
    @State private var selectedSeasonNumber: Int?
    @State private var playback: PlaybackRequest?
    @State private var episodeInfo: MediaEpisode?
    @State private var tmdbHeroArtworkData: Data?
    @State private var tmdbTitleLogoData: Data?
    @State private var isHeroArtworkLoading = true
    @State private var isTitleLogoResolved = false

    init(item: MediaItem, tmdbMetadata: TrendingTitle? = nil) {
        _model = StateObject(wrappedValue: DetailsViewModel(
            item: item,
            tmdbMetadataSnapshot: tmdbMetadata
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                detailsHero
                    .velaHeroPageTransition()

                VStack(alignment: .leading, spacing: 18) {
                    detailsTitle
                    detailsMetadata
                    if let overview = model.item.overview { Text(overview).foregroundStyle(.secondary) }
                    HStack(spacing: 12) {
                        Button {
                            guard let request = primaryPlaybackRequest else { return }
                            Task { await beginPlayback(request) }
                        } label: {
                            Label(primaryActionTitle, systemImage: "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                        }
                        .buttonStyle(VelaPrimaryButtonStyle(glow: environment.theme.glow))
                        .disabled(primaryPlaybackRequest == nil)

                        Button { library.toggleWatchlist(model.item) } label: {
                            Image(systemName: library.isInWatchlist(model.item) ? "checkmark" : "plus")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(environment.theme.accent)
                                .frame(width: 36, height: 36)
                                .background(VelaTheme.elevatedSurface, in: Circle())
                                .overlay {
                                    Circle().stroke(environment.theme.accent.opacity(0.34), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .shadow(color: environment.theme.glow.opacity(0.35), radius: 8)
                        .accessibilityLabel(
                            library.isInWatchlist(model.item) ? "Remove from Watchlist" : "Add to Watchlist"
                        )
                    }

                    if !model.item.seasons.isEmpty { seasonsSection }
                    if !model.item.cast.isEmpty {
                        Text("Cast").font(.title2.bold())
                        Text(model.item.cast.map(\.name).joined(separator: " · ")).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                // Pull the details content into the hero so its clear logo sits
                // at the same vertical position as the Home carousel logo.
                .padding(.top, -HeroArtworkScrollEffect.detailsContentOverlap)
                .padding(.bottom, 32)
                .zIndex(1)
            }
        }
        .coordinateSpace(name: HeroArtworkScrollEffect.detailsCoordinateSpace)
        .background { VelaScreenBackground() }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .overlay { if model.isLoading && model.item.overview == nil { ProgressView() } }
        .overlay {
            if let episodeInfo {
                EpisodeInfoOverlay(
                    showTitle: model.item.title,
                    episode: episodeInfo,
                    onDismiss: { withAnimation(.easeOut(duration: 0.18)) { self.episodeInfo = nil } }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: episodeInfo?.id)
        .task {
            let initialItem = model.item
            let preferredSeasonNumber = library.latestProgress(for: initialItem)?.episode?.seasonNumber

            // Season selection is playback state, so establish it before any artwork
            // or network request can delay what the picker presents.
            selectedSeasonNumber = preferredSeasonNumber ?? initialItem.seasons.first?.number

            let artworkTask = Task { @MainActor in
                let artwork = await sourceLookup.resolveArtwork(
                    for: initialItem,
                    environment: environment
                )
                guard !Task.isCancelled else { return }
                tmdbHeroArtworkData = artwork
                isHeroArtworkLoading = false
            }
            let logoTask = Task { @MainActor in
                let logo = await loadTitleLogo(for: initialItem)
                guard !Task.isCancelled else { return }
                tmdbTitleLogoData = logo
                isTitleLogoResolved = true
            }
            defer {
                artworkTask.cancel()
                logoTask.cancel()
            }

            await model.load(
                environment: environment,
                preferredSeasonNumber: preferredSeasonNumber
            )
            await artworkTask.value
            await logoTask.value
            guard !Task.isCancelled else { return }

            if model.item.tmdbID != initialItem.tmdbID {
                async let correctedArtwork = sourceLookup.resolveArtwork(
                    for: model.item,
                    environment: environment
                )
                async let correctedLogo = loadTitleLogo(for: model.item)
                if let logo = await correctedLogo {
                    tmdbTitleLogoData = logo
                }
                if let artwork = await correctedArtwork {
                    tmdbHeroArtworkData = artwork
                }
            }
            guard !Task.isCancelled else { return }
            let selectionIsStillAvailable = selectedSeasonNumber.map { selectedNumber in
                model.item.seasons.contains { $0.number == selectedNumber }
            } ?? false
            if !selectionIsStillAvailable {
                selectedSeasonNumber = model.item.seasons.first {
                    $0.number == preferredSeasonNumber
                }?.number ?? model.item.seasons.first?.number
            }
        }
        .fullScreenCover(isPresented: Binding(get: { playback != nil }, set: { if !$0 { playback = nil } })) {
            if let playback {
                PlayerScreen(request: playback, nextRequest: nextRequest(after: playback.episode))
            }
        }
        .errorAlert($model.errorMessage)
        .titleNavigationTransition(id: model.item.artworkIdentityKey)
    }

    private var detailsHero: some View {
        GeometryReader { proxy in
            let minY = proxy.frame(in: .named(HeroArtworkScrollEffect.detailsCoordinateSpace)).minY
            let metrics = HeroArtworkScrollEffect.metrics(minY: minY, reduceMotion: reduceMotion)

            ZStack(alignment: .bottom) {
                ZStack {
                    // Keep details artwork identical to the home carousel: the
                    // image is centered and uniformly fill-cropped inside the
                    // same fixed-size hero frame.
                    CenteredHeroArtwork(data: tmdbHeroArtworkData)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .overlay {
                            if tmdbHeroArtworkData == nil {
                                if isHeroArtworkLoading {
                                    ProgressView()
                                        .controlSize(.large)
                                        .tint(.white)
                                        .accessibilityLabel("Loading artwork")
                                } else {
                                    Image(systemName: model.item.kind == .movie ? "film" : "tv")
                                        .font(.system(size: 44))
                                        .foregroundStyle(.white.opacity(0.45))
                                }
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()

                    Color.black
                        .opacity(HeroArtworkScrollEffect.maximumDimming * metrics.recessionProgress)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(metrics.scale, anchor: .top)
                .offset(y: metrics.parallaxOffset)
                .modifier(HeroArtworkBoundaryClip(isEnabled: metrics.clipsToHeroBounds))
                .offset(y: metrics.verticalOffset)
                .opacity(metrics.opacity)

                // This gradient deliberately remains in the scrolling layer so it
                // continues to sit behind the title as the artwork recedes.
                VelaHeroFade()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)

        }
        // The Home carousel intentionally locks to its scroll container. The
        // details hero instead follows the current proposal so a landscape
        // player presentation cannot leave a stale width behind in portrait.
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: HeroArtworkScrollEffect.heroHeight)
    }

    private var detailsTitle: some View {
        TitleLogoView(
            title: model.item.title,
            logoData: tmdbTitleLogoData,
            showsFallback: isTitleLogoResolved
        ) {
            Text(model.item.title)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .shadow(color: .black.opacity(0.55), radius: 12, y: 4)
    }

    private func loadTitleLogo(for item: MediaItem) async -> Data? {
        enum Event: Sendable {
            case loaded(Data?)
            case timeout
        }

        return await withTaskGroup(of: Event.self) { group in
            group.addTask {
                .loaded(try? await environment.tmdbLogoData(for: item))
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return .timeout
            }

            while let event = await group.next() {
                switch event {
                case .loaded(let data):
                    group.cancelAll()
                    return data
                case .timeout:
                    group.cancelAll()
                    return nil
                }
            }
            return nil
        }
    }

    private var detailsMetadata: some View {
        HStack(spacing: 10) {
            Text(model.item.kind == .movie ? "Movie" : "TV Show")
            if let rating = model.item.rating, rating > 0 {
                Text("·")
                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                    .foregroundStyle(.yellow)
            }
            if let release = model.item.releaseDate {
                Text("·")
                Text(String(release.prefix(4)))
            }
            if let quality = model.item.quality {
                Text("·")
                Text(quality)
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white.opacity(0.82))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private var seasonsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let firstSeason = model.item.seasons.first {
                Picker("Season", selection: Binding(get: { selectedSeasonNumber ?? firstSeason.number }, set: { seasonNumber in
                    selectedSeasonNumber = seasonNumber
                    guard let season = model.item.seasons.first(where: { $0.number == seasonNumber }) else { return }
                    Task { await model.loadEpisodes(season, environment: environment) }
                })) {
                    ForEach(model.item.seasons) { Text($0.title ?? "Season \($0.number)").tag($0.number) }
                }
                .pickerStyle(.menu)

                let season = model.item.seasons.first {
                    $0.number == selectedSeasonNumber
                } ?? firstSeason
                ForEach(model.episodes[season.id] ?? []) { episode in
                    let episodeProgress = library.progress(for: episode, in: model.item)
                    let isWatched = library.isWatched(episode, in: model.item)
                    Button {
                        Task { await beginPlayback(PlaybackRequest(media: model.item, episode: episode)) }
                    } label: {
                        HStack(spacing: 12) {
                            ZStack(alignment: .bottom) {
                                CachedRemoteImage(url: episode.posterURL) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Rectangle().fill(.gray.opacity(0.2))
                                }
                                .frame(width: 120, height: 68)
                                .clipped()

                                if let episodeProgress {
                                    ProgressView(value: episodeProgress.fraction)
                                        .tint(environment.theme.accent)
                                        .background(.white.opacity(0.28))
                                }

                                if isWatched {
                                    VStack {
                                        HStack {
                                            Spacer()
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.title3)
                                                .foregroundStyle(.white, .green)
                                                .padding(6)
                                                .background(.black.opacity(0.68), in: Circle())
                                        }
                                        Spacer()
                                    }
                                    .padding(4)
                                }
                            }
                            .frame(width: 120, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading) {
                                Text("E\(episode.number) · \(episode.title ?? "Episode")").font(.headline)
                                if let overview = episode.overview { Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                            Spacer(); Image(systemName: "play.circle.fill").font(.title2)
                        }
                        .padding(10)
                        .velaSurface(cornerRadius: 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            Task { await beginPlayback(PlaybackRequest(media: model.item, episode: episode)) }
                        } label: {
                            Label(episodeProgress?.resumeLabel == nil ? "Play" : "Resume", systemImage: "play.fill")
                        }

                        Button {
                            let request = PlaybackRequest(media: model.item, episode: episode)
                            if isWatched {
                                library.markUnwatched(request: request)
                            } else {
                                markEpisodeAsWatched(request)
                            }
                        } label: {
                            Label(
                                isWatched ? "Mark as Unwatched" : "Mark as Watched",
                                systemImage: isWatched ? "circle" : "checkmark.circle"
                            )
                        }

                        if hasPreviousEpisodes(before: episode) {
                            Button {
                                markPreviousEpisodesAsWatched(before: episode)
                            } label: {
                                Label(
                                    "Mark Previous Episodes as Watched",
                                    systemImage: "checkmark.rectangle.stack.fill"
                                )
                            }
                        }

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { episodeInfo = episode }
                        } label: {
                            Label("Show Episode Info", systemImage: "info.circle")
                        }
                    }
                }
            }
        }
    }

    private func nextRequest(after episode: MediaEpisode?) -> PlaybackRequest? {
        guard let episode,
              let season = model.item.seasons.first(where: { $0.number == episode.seasonNumber }),
              let list = model.episodes[season.id],
              let index = list.firstIndex(of: episode) else { return nil }
        if list.indices.contains(index + 1) {
            return PlaybackRequest(media: model.item, episode: list[index + 1])
        }
        guard let seasonIndex = model.item.seasons.firstIndex(of: season),
              model.item.seasons.indices.contains(seasonIndex + 1),
              let firstEpisode = model.episodes[model.item.seasons[seasonIndex + 1].id]?.first else { return nil }
        return PlaybackRequest(media: model.item, episode: firstEpisode)
    }

    private var primaryPlaybackRequest: PlaybackRequest? {
        if model.item.kind == .movie { return PlaybackRequest(media: model.item, episode: nil) }

        if let progressEpisode = library.latestProgress(for: model.item)?.episode,
           let progressSeason = model.item.seasons.first(where: { $0.number == progressEpisode.seasonNumber }),
           let progressEpisodes = model.episodes[progressSeason.id],
           let episode = progressEpisodes.first(where: { candidate in
               candidate.id == progressEpisode.id || (
                   candidate.seasonNumber == progressEpisode.seasonNumber &&
                   candidate.number == progressEpisode.number
               )
           }) {
            return PlaybackRequest(media: model.item, episode: episode)
        }

        guard let season = model.item.seasons.first(where: {
            $0.number == selectedSeasonNumber
        }) ?? model.item.seasons.first,
              let episodes = model.episodes[season.id] else { return nil }
        guard let episode = episodes.first(where: { !library.isWatched($0, in: model.item) })
            ?? episodes.first else { return nil }
        return PlaybackRequest(media: model.item, episode: episode)
    }

    private var primaryActionTitle: String {
        guard let progress = library.latestProgress(for: model.item) else { return "Play" }
        if model.item.kind == .movie { return progress.resumeLabel ?? "Play" }
        guard let episode = progress.episode else { return "Play" }
        return "S\(episode.seasonNumber) E\(episode.number) · \(progress.positionLabel)"
    }

    private func beginPlayback(_ request: PlaybackRequest) async {
        if let episode = request.episode,
           let season = model.item.seasons.first(where: { $0.number == episode.seasonNumber }),
           let episodes = model.episodes[season.id],
           episodes.last == episode,
           let seasonIndex = model.item.seasons.firstIndex(of: season),
           model.item.seasons.indices.contains(seasonIndex + 1) {
            await model.loadEpisodes(model.item.seasons[seasonIndex + 1], environment: environment)
        }
        guard !Task.isCancelled else { return }
        playback = request
    }

    private func markEpisodeAsWatched(_ request: PlaybackRequest) {
        let currentEpisode = library.latestProgress(for: request.media)?.episode
        let shouldAdvanceContinueWatching = currentEpisode.map {
            $0.id == request.episode?.id || (
                $0.seasonNumber == request.episode?.seasonNumber &&
                    $0.number == request.episode?.number
            )
        } ?? false
        library.markWatched(request: request)
        guard shouldAdvanceContinueWatching else { return }
        Task {
            if let next = await nextUnwatchedPlaybackRequest(
                after: request,
                environment: environment,
                library: library
            ) {
                library.promoteToContinueWatching(next)
            }
        }
    }

    private func hasPreviousEpisodes(before episode: MediaEpisode) -> Bool {
        model.item.seasons.contains { $0.number < episode.seasonNumber }
            || model.episodes.values.joined().contains {
                $0.seasonNumber == episode.seasonNumber && $0.number < episode.number
            }
    }

    private func markPreviousEpisodesAsWatched(before episode: MediaEpisode) {
        Task {
            let relevantSeasons = model.item.seasons.filter { $0.number <= episode.seasonNumber }
            for season in relevantSeasons where model.episodes[season.id] == nil {
                await model.loadEpisodes(season, environment: environment)
            }
            guard !Task.isCancelled,
                  relevantSeasons.allSatisfy({ model.episodes[$0.id] != nil }) else { return }

            let previousEpisodes = relevantSeasons
                .flatMap { model.episodes[$0.id] ?? [] }
                .filter {
                    ($0.seasonNumber, $0.number) < (episode.seasonNumber, episode.number)
                }
            guard !previousEpisodes.isEmpty else { return }

            let currentEpisode = library.latestProgress(for: model.item)?.episode
            let shouldPromoteSelectedEpisode = currentEpisode.map {
                ($0.seasonNumber, $0.number) < (episode.seasonNumber, episode.number)
            } ?? false
            library.markWatched(requests: previousEpisodes.map {
                PlaybackRequest(media: model.item, episode: $0)
            })
            if shouldPromoteSelectedEpisode {
                library.promoteToContinueWatching(
                    PlaybackRequest(media: model.item, episode: episode)
                )
            }
        }
    }
}

private enum HeroArtworkScrollEffect {
    struct Metrics {
        let recessionProgress: CGFloat
        let scale: CGFloat
        let parallaxOffset: CGFloat
        let verticalOffset: CGFloat
        let opacity: Double
        let clipsToHeroBounds: Bool
    }

    static let homeCoordinateSpace = "home-hero-scroll"
    static let detailsCoordinateSpace = "details-hero-scroll"
    static let heroHeight: CGFloat = 690
    static let detailsContentOverlap: CGFloat = 274
    static let recessionDistance: CGFloat = 360
    static let disappearanceDistance: CGFloat = 500
    static let maximumDimming: Double = 0.64
    static let upwardParallaxCompensation: CGFloat = 0.35

    static func metrics(minY: CGFloat, reduceMotion: Bool) -> Metrics {
        let upwardScroll = max(0, -minY)
        let overscroll = max(0, minY)
        let recessionProgress = min(upwardScroll / recessionDistance, 1)
        let disappearanceProgress = min(upwardScroll / disappearanceDistance, 1)
        let scale = reduceMotion
            ? 1
            : 1 + (overscroll / heroHeight)

        return Metrics(
            recessionProgress: recessionProgress,
            scale: scale,
            parallaxOffset: reduceMotion ? 0 : upwardScroll * upwardParallaxCompensation,
            // Pin the artwork's top while its exact overscroll scale keeps the
            // bottom attached to the stretched hero instead of exposing a gap.
            verticalOffset: -overscroll,
            opacity: 1 - Double(disappearanceProgress),
            // Pull-down zoom needs to render above the hero's layout bounds.
            // During regular scrolling, restore the boundary so the artwork
            // cannot bleed behind the page's shelves or detail content.
            clipsToHeroBounds: overscroll == 0
        )
    }
}

private struct EpisodeInfoOverlay: View {
    let showTitle: String
    let episode: MediaEpisode
    let onDismiss: () -> Void

    private var synopsis: String {
        let value = episode.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "No episode synopsis is available." : value
    }

    var body: some View {
        ZStack {
            Button(action: onDismiss) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(.black.opacity(0.45))
                    .ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close episode info")

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(showTitle)
                            .font(.title2.bold())
                        Text("Season \(episode.seasonNumber) • Episode \(episode.number)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close")
                }

                Text(episode.title ?? "Episode \(episode.number)")
                    .font(.headline)

                Text(synopsis)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            .padding(22)
            .frame(maxWidth: 520, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
            .padding(24)
            .onTapGesture { }
        }
        .zIndex(200)
    }
}

private struct VelaThemePicker: View {
    @Binding var selection: VelaTheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(VelaTheme.allCases) { theme in
                        Button {
                            selection = theme
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 0) {
                                    Circle()
                                        .fill(theme.accent)
                                        .frame(width: 28, height: 28)
                                    Circle()
                                        .fill(theme.accentBright)
                                        .frame(width: 28, height: 28)
                                        .offset(x: -7)
                                    Spacer(minLength: 2)
                                    if selection == theme {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(theme.accentBright, theme.accent)
                                    }
                                }

                                Text(theme.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(VelaTheme.primaryText)
                                    .lineLimit(1)
                            }
                            .padding(12)
                            .frame(width: 126, alignment: .leading)
                            .background(VelaTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 15))
                            .overlay {
                                RoundedRectangle(cornerRadius: 15)
                                    .stroke(
                                        selection == theme ? theme.accentBright.opacity(0.9) : VelaTheme.border,
                                        lineWidth: selection == theme ? 1.5 : 1
                                    )
                            }
                            .shadow(
                                color: selection == theme ? theme.glow.opacity(0.4) : .clear,
                                radius: 9,
                                y: 3
                            )
                        }
                        .buttonStyle(.plain)
                        .id(theme.id)
                        .accessibilityLabel(theme.name)
                        .accessibilityValue(selection == theme ? "Selected" : "")
                        .accessibilityAddTraits(selection == theme ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }
            .onAppear {
                proxy.scrollTo(selection.id, anchor: anchor(for: selection))
            }
            .onChange(of: selection) { _, selectedTheme in
                withAnimation(.smooth) {
                    proxy.scrollTo(selectedTheme.id, anchor: anchor(for: selectedTheme))
                }
            }
        }
        .scrollClipDisabled()
    }

    private func anchor(for theme: VelaTheme) -> UnitPoint {
        let themes = VelaTheme.allCases
        guard themes.count > 1, let index = themes.firstIndex(of: theme) else {
            return .center
        }
        return UnitPoint(x: CGFloat(index) / CGFloat(themes.count - 1), y: 0.5)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @AppStorage("player.autoNext") private var autoNext = true
    @AppStorage("player.defaultQualityHeight") private var defaultQualityHeight = 0
    @AppStorage("player.defaultPlaybackRate") private var defaultPlaybackRate = 1.0
    @AppStorage("player.orientation") private var playerOrientationRawValue = PlayerOrientationPreference.autoRotate.rawValue
    @AppStorage("player.subtitleLanguage.primary") private var primarySubtitleLanguage = "en"
    @AppStorage("player.subtitleLanguage.secondary") private var secondarySubtitleLanguage = ""
    @AppStorage("player.audioLanguage") private var audioLanguage = "en"
    @AppStorage("subtitle.thirdParty.enabled") private var thirdPartySubtitlesEnabled = true
    @AppStorage("player.subtitleSync.autoSelectLatest") private var autoSelectLatestSubtitleSync = true
    @State private var providerDomain = ""
    @State private var providerMessage: String?
    @State private var isCheckingForUpdates = false
    @State private var updateCheckResult: UpdateCheckResult?
    @State private var exportDocument: UserDataJSONDocument?
    @State private var isExportingUserData = false
    @State private var isImportingUserData = false
    @State private var pendingImport: PendingUserDataImport?
    @State private var backupNotice: UserDataBackupNotice?

    var body: some View {
        VStack(spacing: 0) {
            PageTitleHeader(title: "Settings")

            Form {
                Section("Appearance") {
                    VelaThemePicker(selection: $environment.theme)
                    Text("Themes color only Vela's accents, progress, selection, and glow. Text and graphite surfaces stay consistent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(VelaTheme.surface)

                Section("Provider") {
                    LabeledContent("Active", value: "StreamingCommunity (EN)")
                    TextField("Domain", text: $providerDomain)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Apply domain") {
                        Task {
                            do {
                                try await environment.applyProviderDomain(providerDomain)
                                providerDomain = environment.providerDomain
                                providerMessage = "Provider updated."
                            } catch {
                                providerMessage = error.localizedDescription
                            }
                        }
                    }
                    .disabled(providerDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let providerMessage {
                        Text(providerMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Change this only when the provider moves to a new domain.").font(.caption).foregroundStyle(.secondary)
                }
                .listRowBackground(VelaTheme.surface)
                Section("Player") {
                    Toggle("Automatically play next episode", isOn: $autoNext)
                    Picker("Default quality", selection: $defaultQualityHeight) {
                        Text("Auto").tag(0)
                        Text("1080p").tag(1080)
                        Text("720p").tag(720)
                        Text("480p").tag(480)
                    }
                    .tint(environment.theme.accent)
                    Picker("Default speed", selection: $defaultPlaybackRate) {
                        ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { speed in
                            Text("\(speed, specifier: "%.2g")×").tag(speed)
                        }
                    }
                    .tint(environment.theme.accent)
                    Picker("Player orientation", selection: playerOrientation) {
                        ForEach(PlayerOrientationPreference.allCases) { option in
                            Text(option.name).tag(option)
                        }
                    }
                    .tint(environment.theme.accent)
                    Text("Auto-Rotate follows the device while the player is open. Landscape Only uses either landscape direction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("If the preferred quality is unavailable, the closest lower resolution is selected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(VelaTheme.surface)
                Section("Playback Languages") {
                    languagePicker("Default subtitles", selection: $primarySubtitleLanguage)
                    languagePicker("Backup subtitles", selection: $secondarySubtitleLanguage, allowsNone: true)
                    languagePicker("Default audio", selection: $audioLanguage)
                    Text("If the selected audio track is unavailable, English is used automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(VelaTheme.surface)
                Section("Third-party Subtitles") {
                    Toggle("Enabled", isOn: $thirdPartySubtitlesEnabled)
                    Toggle("Use latest saved sync automatically", isOn: $autoSelectLatestSubtitleSync)
                    Text("Third-party availability depends on the title and provider service.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Saved subtitle timing versions stay available alongside the original and are stored separately for each movie or episode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(VelaTheme.surface)
                Section("Backup & Restore") {
                    Button {
                        prepareExport()
                    } label: {
                        Label("Export progress and settings", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        isImportingUserData = true
                    } label: {
                        Label("Import progress and settings", systemImage: "square.and.arrow.down")
                    }
                    Text("A backup includes all settings, watchlist entries, watched history, resume positions, Continue Watching selections, saved subtitle sync versions, and title playback speeds. Importing replaces the current app data with the backup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(VelaTheme.surface)
                Section("About") {
                    HStack(spacing: 14) {
                        Image("VelaLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .accessibilityHidden(true)
                        Text("Vela for iOS")
                            .font(.headline)
                    }
                    LabeledContent("Version", value: Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "Unknown")
                    Link(destination: URL(string: "https://github.com/rtk19/Vela")!) {
                        Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Button {
                        Task { await checkForUpdates() }
                    } label: {
                        if isCheckingForUpdates {
                            HStack {
                                ProgressView()
                                Text("Checking for updates…")
                            }
                        } else {
                            Label("Check for updates", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(isCheckingForUpdates)
                    Link(destination: URL(string: "https://buymeacoffee.com/refaelbar")!) {
                        Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                            .font(.headline)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(red: 1, green: 0.87, blue: 0), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens Buy Me a Coffee in your browser")
                    Text("This app does not host media. Use it only for content you are authorized to access.").font(.caption).foregroundStyle(.secondary)
                    Text("Trending data and images are provided by TMDB. This product uses the TMDB API but is not endorsed or certified by TMDB.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(VelaTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)
        }
        .tint(environment.theme.accent)
        .background { VelaScreenBackground() }
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if providerDomain.isEmpty { providerDomain = environment.providerDomain }
        }
        .sheet(item: $updateCheckResult) { result in
            UpdateCheckSheet(result: result)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fileExporter(
            isPresented: $isExportingUserData,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            exportDocument = nil
            switch result {
            case .success:
                backupNotice = UserDataBackupNotice(
                    title: "Backup exported",
                    message: "Your progress, history, watchlist, playback speeds, and settings were saved."
                )
            case let .failure(error):
                backupNotice = UserDataBackupNotice(title: "Export failed", message: error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $isImportingUserData,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            prepareImport(from: result)
        }
        .alert(
            "Replace current app data?",
            isPresented: Binding(
                get: { pendingImport != nil },
                set: { if !$0 { pendingImport = nil } }
            ),
            presenting: pendingImport
        ) { pending in
            Button("Import", role: .destructive) {
                restore(pending)
            }
            Button("Cancel", role: .cancel) {
                pendingImport = nil
            }
        } message: { pending in
            Text("This backup was exported with Vela \(pending.summary.appVersion) on \(pending.summary.exportedAt.formatted(date: .abbreviated, time: .shortened)). Your current progress, history, watchlist, playback speeds, and settings will be replaced.")
        }
        .alert(item: $backupNotice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }

    private var exportFilename: String {
        "Vela-Backup-\(Date.now.formatted(.iso8601.year().month().day()))"
    }

    private func prepareExport() {
        do {
            exportDocument = UserDataJSONDocument(data: try environment.library.exportUserData())
            isExportingUserData = true
        } catch {
            backupNotice = UserDataBackupNotice(title: "Export failed", message: error.localizedDescription)
        }
    }

    private func prepareImport(from result: Result<[URL], any Error>) {
        do {
            guard let url = try result.get().first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let summary = try environment.library.backupSummary(for: data)
            pendingImport = PendingUserDataImport(data: data, summary: summary)
        } catch {
            backupNotice = UserDataBackupNotice(title: "Import failed", message: error.localizedDescription)
        }
    }

    private func restore(_ pending: PendingUserDataImport) {
        pendingImport = nil
        do {
            try environment.library.importUserData(pending.data)
            Task {
                await environment.reloadAfterUserDataImport()
                providerDomain = environment.providerDomain
                backupNotice = UserDataBackupNotice(
                    title: "Backup imported",
                    message: "All progress, history, watchlist entries, playback speeds, and settings were restored."
                )
            }
        } catch {
            backupNotice = UserDataBackupNotice(title: "Import failed", message: error.localizedDescription)
        }
    }

    private func languagePicker(
        _ title: String,
        selection: Binding<String>,
        allowsNone: Bool = false
    ) -> some View {
        Picker(title, selection: selection) {
            if allowsNone { Text("None").tag("") }
            ForEach(PlaybackLanguages.options) { option in
                Text(option.name).tag(option.code)
            }
        }
        .tint(environment.theme.accent)
    }

    private var playerOrientation: Binding<PlayerOrientationPreference> {
        Binding(
            get: {
                PlayerOrientationPreference(rawValue: playerOrientationRawValue) ?? .autoRotate
            },
            set: { playerOrientationRawValue = $0.rawValue }
        )
    }

    private func checkForUpdates() async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        do {
            let release = try await GitHubReleaseClient().latestRelease()
            let currentVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0"
            updateCheckResult = GitHubReleaseClient.isNewer(
                tagName: release.tagName,
                than: currentVersion
            ) ? .updateAvailable(release) : .upToDate(currentVersion)
        } catch where error.isCancellation {
            return
        } catch {
            updateCheckResult = .failed
        }
    }
}

private struct UserDataJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw UserDataBackupError.invalidFile
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct PendingUserDataImport {
    let data: Data
    let summary: UserDataBackupSummary
}

private struct UserDataBackupNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum UpdateCheckResult: Identifiable {
    case updateAvailable(GitHubRelease)
    case upToDate(String)
    case failed

    var id: String {
        switch self {
        case .updateAvailable(let release): "available-\(release.tagName)"
        case .upToDate(let version): "current-\(version)"
        case .failed: "failed"
        }
    }
}

private struct UpdateCheckSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var environment: AppEnvironment

    let result: UpdateCheckResult
    let onSkipUpdate: (() -> Void)?
    let onRemindLater: (() -> Void)?

    init(
        result: UpdateCheckResult,
        onSkipUpdate: (() -> Void)? = nil,
        onRemindLater: (() -> Void)? = nil
    ) {
        self.result = result
        self.onSkipUpdate = onSkipUpdate
        self.onRemindLater = onRemindLater
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch result {
                    case .updateAvailable(let release):
                        updateAvailableContent(release)
                    case .upToDate(let version):
                        statusContent(
                            icon: "checkmark.circle.fill",
                            title: "You're up to date",
                            message: "Vela \(version) is the newest available version."
                        )
                    case .failed:
                        statusContent(
                            icon: "exclamationmark.triangle.fill",
                            title: "Unable to check for updates",
                            message: "Check your internet connection and try again."
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .background { VelaScreenBackground() }
            .navigationTitle("Check for Updates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(accentColor)
                }
            }
        }
        .tint(accentColor)
    }

    @ViewBuilder
    private func updateAvailableContent(_ release: GitHubRelease) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(accentColor)
            Text("A new version was found")
                .foregroundStyle(.primary)
        }
        .font(.title2.bold())

        Text(release.name.flatMap { $0.isEmpty ? nil : $0 } ?? release.tagName)
            .font(.headline)
            .foregroundStyle(accentColor)

        Divider()

        ReleaseNotesMarkdownView(source: release.body, accentColor: accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)

        Button {
            dismiss()
            openURL(release.htmlURL)
        } label: {
            Label("Download", systemImage: "arrow.down.circle.fill")
                .font(.headline)
                .foregroundStyle(environment.theme == .silver ? VelaTheme.background : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(downloadButtonColor, in: Capsule())
                .overlay { Capsule().stroke(.white.opacity(0.22), lineWidth: 1) }
        }
        .buttonStyle(.plain)

        if let onRemindLater, let onSkipUpdate {
            Button {
                dismiss()
                onRemindLater()
            } label: {
                Text("Remind Me Later")
                    .font(.headline)
                    .foregroundStyle(accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(accentColor.opacity(0.12), in: Capsule())
                    .overlay {
                        Capsule().stroke(accentColor.opacity(0.75), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)

            Button {
                dismiss()
                onSkipUpdate()
            } label: {
                Text("Skip This Update")
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(accentColor.opacity(0.7))
        }
    }

    private func statusContent(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(accentColor)
            Text(title)
                .font(.title2.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var accentColor: Color { environment.theme.accent }

    private var downloadButtonColor: Color { accentColor }
}

private struct ReleaseNotesMarkdownView: View {
    let blocks: [ReleaseNotesMarkdownBlock]
    let accentColor: Color

    init(source: String, accentColor: Color) {
        blocks = ReleaseNotesMarkdownParser.parse(source)
        self.accentColor = accentColor
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ReleaseNotesMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let source):
            VStack(alignment: .leading, spacing: 8) {
                inlineText(source)
                    .font(headingFont(for: level))
                    .fontWeight(.bold)
                if level <= 2 { Divider() }
            }
        case .paragraph(let source):
            inlineText(source)
                .font(.body)
                .lineSpacing(3)
        case .unorderedItem(let indentation, let source):
            listRow(marker: "•", source: source, indentation: indentation)
        case .orderedItem(let indentation, let marker, let source):
            listRow(marker: marker, source: source, indentation: indentation)
        case .quote(let source):
            inlineText(source)
                .italic()
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(accentColor)
                        .frame(width: 4)
                }
        case .code(let source):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: source)
                    .font(.system(.callout, design: .monospaced))
                    .padding(12)
            }
            .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 10))
        case .divider:
            Divider()
        }
    }

    private func listRow(marker: String, source: String, indentation: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .fontWeight(.semibold)
                .foregroundStyle(accentColor)
                .frame(minWidth: 18, alignment: .trailing)
            inlineText(source)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(indentation) * 18)
    }

    private func inlineText(_ source: String) -> Text {
        let attributed = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
        return Text(attributed)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: .title
        case 2: .title2
        case 3: .title3
        default: .headline
        }
    }
}

@MainActor
private func nextUnwatchedPlaybackRequest(
    after request: PlaybackRequest,
    environment: AppEnvironment,
    library: LibraryStore
) async -> PlaybackRequest? {
    guard request.media.kind == .series, let currentEpisode = request.episode else { return nil }
    do {
        let show = request.media.seasons.isEmpty
            ? try await environment.tmdbDetails(for: request.media)
            : request.media
        guard let startingSeasonIndex = show.seasons.firstIndex(where: {
            $0.number == currentEpisode.seasonNumber
        }) else { return nil }

        for seasonIndex in startingSeasonIndex..<show.seasons.count {
            let season = show.seasons[seasonIndex]
            let episodes = try await environment.tmdbEpisodes(for: season, show: show)
            let candidates: ArraySlice<MediaEpisode>

            if seasonIndex == startingSeasonIndex {
                guard let currentIndex = episodes.firstIndex(where: {
                    $0.id == currentEpisode.id || (
                        $0.seasonNumber == currentEpisode.seasonNumber &&
                            $0.number == currentEpisode.number
                    )
                }) else { return nil }
                candidates = episodes.dropFirst(currentIndex + 1)
            } else {
                candidates = episodes[...]
            }

            if let episode = candidates.first(where: { !library.isWatched($0, in: show) }) {
                return PlaybackRequest(media: show, episode: episode)
            }
        }
        return nil
    } catch where error.isCancellation {
        return nil
    } catch {
        return nil
    }
}

private enum PlaybackLanguages {
    struct Option: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    static let options: [Option] = Locale.LanguageCode.isoLanguageCodes
        .map(\.identifier)
        .filter { $0.count == 2 }
        .compactMap { code in
            Locale.current.localizedString(forLanguageCode: code).map { Option(code: code, name: $0) }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

private struct SubtitleSyncStudioView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    let session: PlayerSession
    let request: PlaybackRequest
    let initialContext: SubtitleStudioContext

    @State private var selectedTrackID: String
    @State private var offsetTenths: Int
    @State private var selectedVersionID: UUID?
    @State private var isSaving = false

    init(
        session: PlayerSession,
        request: PlaybackRequest,
        initialContext: SubtitleStudioContext
    ) {
        self.session = session
        self.request = request
        self.initialContext = initialContext
        _selectedTrackID = State(initialValue: initialContext.selectedTrackID)
        _offsetTenths = State(initialValue: Int((initialContext.offset * 10).rounded()))
        _selectedVersionID = State(initialValue: initialContext.selectedVersionID)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                studioHeader
                SubtitleStudioPreview(
                    session: session,
                    selectedTrack: selectedTrack,
                    offsetTenths: offsetTenths
                )
                    .frame(maxHeight: max(240, proxy.size.height * 0.62))
                controls(isCompact: proxy.size.width < 600)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
        .interactiveDismissDisabled()
        .preferredColorScheme(.dark)
    }

    private var studioHeader: some View {
        HStack {
            Button("Cancel") { cancel() }
                .disabled(isSaving)
            Spacer()
            VStack(spacing: 2) {
                Text("Subtitle Sync Studio")
                    .font(.headline)
                Text(request.displayTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Save") { save() }
                .fontWeight(.semibold)
                .disabled(isSaving || offsetTenths == 0 || selectedTrack == nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func controls(isCompact: Bool) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                Group {
                    if isCompact {
                        VStack(spacing: 10) {
                            subtitleTrackMenu
                            subtitleVersionMenu
                        }
                    } else {
                        HStack(spacing: 12) {
                            subtitleTrackMenu
                                .layoutPriority(1)
                            subtitleVersionMenu
                        }
                    }
                }

                HStack(spacing: 16) {
                    timingButton(systemImage: "minus", change: -1, accessibilityLabel: "Move subtitles earlier")
                    Text(offsetText)
                        .font(.system(.title2, design: .monospaced, weight: .bold))
                        .frame(maxWidth: isCompact ? .infinity : 220)
                    timingButton(systemImage: "plus", change: 1, accessibilityLabel: "Move subtitles later")
                }
                .frame(maxWidth: .infinity)

                SubtitleStudioPlaybackControls(
                    session: session,
                    isCompact: isCompact
                ) {
                    selectedVersionID = nil
                    offsetTenths = 0
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var subtitleTrackMenu: some View {
        Menu {
            ForEach(session.subtitleStudioTracks) { track in
                Button {
                    selectedTrackID = track.id
                    selectedVersionID = nil
                    offsetTenths = 0
                } label: {
                    if track.id == selectedTrackID {
                        Label(track.displayName, systemImage: "checkmark")
                    } else {
                        Text(track.displayName)
                    }
                }
            }
        } label: {
            studioMenuLabel(
                selectedTrack?.displayName ?? "Subtitle",
                systemImage: "captions.bubble"
            )
        }
        .buttonStyle(.plain)
    }

    private var subtitleVersionMenu: some View {
        Menu {
            Button {
                selectedVersionID = nil
                offsetTenths = 0
            } label: {
                Label("Original · 0.0s", systemImage: selectedVersionID == nil ? "checkmark" : "captions.bubble")
            }
            ForEach(versionsForSelectedTrack) { version in
                Button {
                    selectedVersionID = version.id
                    offsetTenths = version.offsetTenths
                } label: {
                    Label(
                        versionName(version),
                        systemImage: selectedVersionID == version.id ? "checkmark" : "clock.arrow.circlepath"
                    )
                }
            }
        } label: {
            studioMenuLabel(selectedVersionName, systemImage: "square.stack.3d.up")
        }
        .buttonStyle(.plain)
    }

    private func studioMenuLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Color.accentColor.opacity(0.2), in: Capsule())
        .contentShape(Capsule())
    }

    private var selectedTrack: SubtitleStudioTrack? {
        session.subtitleStudioTracks.first { $0.id == selectedTrackID }
    }

    private var versionsForSelectedTrack: [SubtitleSyncVersion] {
        library.subtitleSyncVersions(for: request)
            .filter { $0.subtitleKey == selectedTrackID }
    }

    private var selectedVersionName: String {
        guard let selectedVersionID,
              let version = versionsForSelectedTrack.first(where: { $0.id == selectedVersionID }) else {
            return "Original"
        }
        return versionName(version)
    }

    private var offsetText: String {
        String(format: "%+.1f seconds", Double(offsetTenths) / 10)
    }

    private func timingButton(
        systemImage: String,
        change: Int,
        accessibilityLabel: String
    ) -> some View {
        Button {
            offsetTenths = min(300, max(-300, offsetTenths + change))
            selectedVersionID = nil
        } label: {
            Image(systemName: systemImage)
                .frame(width: 44, height: 28)
        }
        .buttonStyle(.borderedProminent)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Moves subtitles by 0.1 seconds")
    }

    private func versionName(_ version: SubtitleSyncVersion) -> String {
        let date = version.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "\(String(format: "%+.1fs", version.offset)) · \(date)"
    }

    private func cancel() {
        Task {
            await session.cancelSubtitleStudio()
            dismiss()
        }
    }

    private func save() {
        guard let subtitle = selectedTrack?.source else { return }
        isSaving = true
        guard let version = library.saveSubtitleSyncVersion(
            subtitle: subtitle,
            offset: Double(offsetTenths) / 10,
            for: request
        ) else {
            isSaving = false
            return
        }
        Task {
            await session.applySubtitleSyncVersions(
                library.subtitleSyncVersions(for: request),
                selecting: version.id
            )
            dismiss()
        }
    }
}

private struct SubtitleStudioPreview: View {
    @ObservedObject var session: PlayerSession
    let selectedTrack: SubtitleStudioTrack?
    let offsetTenths: Int

    var body: some View {
        VideoPlayer(player: session.player) {
            ZStack {
                VStack {
                    Spacer()
                    if let previewText {
                        Text(previewText)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
                            .shadow(color: .black.opacity(0.8), radius: 3)
                            .padding(.horizontal, 30)
                            .padding(.bottom, 44)
                    }
                }

                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .padding(18)
                        .background(.black.opacity(0.62), in: Circle())
                        .accessibilityLabel("Loading video preview")
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var isLoading: Bool {
        session.isBuffering || session.isSubtitleStudioSeeking
    }

    private var previewText: String? {
        guard let selectedTrack,
              let text = selectedTrack.text(
                at: session.subtitleStudioPosition,
                offset: Double(offsetTenths) / 10
              ) else { return nil }
        return SubtitleDirectionFormatter.displayText(
            text,
            languageCode: selectedTrack.source.languageCode
        )
    }
}

private struct SubtitleStudioPlaybackControls: View {
    @ObservedObject var session: PlayerSession
    let isCompact: Bool
    let onReset: () -> Void

    var body: some View {
        Group {
            if isCompact {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        playbackButton
                        Text(timeText(session.subtitleStudioPosition))
                            .font(.caption.monospacedDigit())
                        Spacer(minLength: 0)
                        Text(timeText(session.duration))
                            .font(.caption.monospacedDigit())
                        resetButton
                    }
                    playbackSlider
                }
            } else {
                HStack(spacing: 12) {
                    playbackButton
                    Text(timeText(session.subtitleStudioPosition))
                        .font(.caption.monospacedDigit())
                    playbackSlider
                    Text(timeText(session.duration))
                        .font(.caption.monospacedDigit())
                    resetButton
                }
            }
        }
    }

    private var playbackButton: some View {
        Button {
            session.toggleStudioPlayback()
        } label: {
            Image(systemName: session.player.timeControlStatus == .paused ? "play.fill" : "pause.fill")
                .frame(width: 28)
        }
        .buttonStyle(.borderedProminent)
    }

    private var playbackSlider: some View {
        Slider(
            value: Binding(
                get: { min(session.subtitleStudioPosition, max(session.duration, 0)) },
                set: { session.seek(to: $0) }
            ),
            in: 0...max(session.duration, 1)
        )
    }

    private var resetButton: some View {
        Button("Reset", action: onReset)
            .buttonStyle(.bordered)
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("player.autoNext") private var autoNext = true
    @AppStorage("player.defaultQualityHeight") private var defaultQualityHeight = 0
    @AppStorage("player.defaultPlaybackRate") private var defaultPlaybackRate = 1.0
    @AppStorage("player.orientation") private var playerOrientationRawValue = PlayerOrientationPreference.autoRotate.rawValue
    @AppStorage("player.subtitleLanguage.primary") private var primarySubtitleLanguage = "en"
    @AppStorage("player.subtitleLanguage.secondary") private var secondarySubtitleLanguage = ""
    @AppStorage("player.audioLanguage") private var audioLanguage = "en"
    @AppStorage("subtitle.thirdParty.enabled") private var thirdPartySubtitlesEnabled = true
    @AppStorage("player.subtitleSync.autoSelectLatest") private var autoSelectLatestSubtitleSync = true
    @StateObject private var model: PlayerViewModel
    @StateObject private var session = PlayerSession()
    @State private var nextRequest: PlaybackRequest?
    @State private var finishedContentID: String?
    @State private var subtitleStudioContext: SubtitleStudioContext?

    init(request: PlaybackRequest, nextRequest: PlaybackRequest?) {
        _model = StateObject(wrappedValue: PlayerViewModel(request: request))
        _nextRequest = State(initialValue: nextRequest)
    }

    var body: some View {
        NativePlayerController(
            player: session.player,
            isBuffering: session.isBuffering || model.isLoading,
            playbackErrorMessage: session.playbackErrorMessage,
            availableQualities: session.availableQualities,
            selectedQuality: session.selectedQuality,
            subtitleTimingOffset: session.subtitleTimingOffset,
            canAdjustSubtitleTiming: session.canOpenSubtitleStudio,
            onQualityChanged: { session.setQuality($0) },
            onAdjustSubtitleTiming: { session.adjustSubtitleTiming(by: $0) },
            onOpenSubtitleSync: { openSubtitleStudio() },
            onRetryPlayback: { session.retryPlayback() },
            onWillDismiss: {
                AppOrientationController.shared.endPlayback()
            },
            onDismiss: {
                saveProgress(markNearEndFinished: true)
                dismiss()
            }
        )
        .background(.black)
        .ignoresSafeArea()
        .task {
            library.markPlaybackStarted(request: model.request)
            await model.load(
                registry: environment.registry,
                sourceLookup: environment.sourceLookup,
                subtitleRegistry: environment.subtitleRegistry,
                enabledSubtitleProviderIDs: enabledSubtitleProviderIDs
            )
        }
        .task(id: model.sourceRevision) {
            guard let source = model.source else { return }
            let initialPlaybackRate = library.playbackRate(
                for: model.request,
                defaultRate: defaultPlaybackRate
            )
            library.updatePlaybackRate(initialPlaybackRate, for: model.request)
            await session.load(
                request: model.request,
                source: source,
                resumeAt: library.resumePosition(for: model.request),
                primarySubtitleLanguage: primarySubtitleLanguage,
                secondarySubtitleLanguage: secondarySubtitleLanguage,
                audioLanguage: audioLanguage,
                externalSubtitles: (source.subtitles + model.thirdPartySubtitles),
                subtitleSyncVersions: library.subtitleSyncVersions(for: model.request),
                automaticallySelectLatestSubtitleSync: autoSelectLatestSubtitleSync,
                defaultQualityHeight: defaultQualityHeight,
                defaultPlaybackRate: Float(initialPlaybackRate)
            )
            session.onEnded = { handlePlaybackEnded() }
        }
        .task(id: model.request.contentID) {
            if let nextRequest, !library.isWatched(nextRequest) { return }
            nextRequest = await resolveNextRequest(after: model.request)
        }
        .task { await saveProgressEverySecond() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                session.prepareForForegroundResume()
            case .background:
                saveProgress()
                session.prepareForBackground()
            case .inactive:
                saveProgress()
            @unknown default:
                saveProgress()
            }
        }
        .onChange(of: session.playbackRate) { _, rate in
            library.updatePlaybackRate(rate, for: model.request)
        }
        .onAppear {
            session.onSourceRefreshNeeded = {
                saveProgress()
                return await model.refreshPlaybackSource(
                    registry: environment.registry,
                    sourceLookup: environment.sourceLookup
                )
            }
            AppOrientationController.shared.beginPlayback(using: playerOrientation)
        }
        .onDisappear {
            session.onSourceRefreshNeeded = nil
            saveProgress(markNearEndFinished: true)
            session.stop()
            AppOrientationController.shared.endPlayback()
        }
        .statusBarHidden()
        .fullScreenCover(item: $subtitleStudioContext) { context in
            SubtitleSyncStudioView(
                session: session,
                request: model.request,
                initialContext: context
            )
        }
        .errorAlert($model.errorMessage)
    }

    private func saveProgress(markNearEndFinished: Bool = false) {
        guard finishedContentID != model.request.contentID else { return }
        if markNearEndFinished,
           PlaybackCompletionPolicy.shouldFinishEpisodeOnExit(
               request: model.request,
               position: session.position,
               duration: session.duration
           ) {
            completeCurrentPlayback(autoPlayNext: false)
            return
        }
        library.updateProgress(request: model.request, position: session.position, duration: session.duration)
    }

    private func saveProgressEverySecond() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            saveProgress()
        }
    }

    private func handlePlaybackEnded() {
        completeCurrentPlayback(autoPlayNext: autoNext)
    }

    private func completeCurrentPlayback(autoPlayNext: Bool) {
        let completedRequest = model.request
        let queuedNextRequest = nextRequest
        finishedContentID = completedRequest.contentID
        library.markFinished(request: completedRequest, nextRequest: queuedNextRequest)

        if let queuedNextRequest {
            guard autoPlayNext else { return }
            playNext(queuedNextRequest)
            return
        }

        Task {
            let resolvedNextRequest = await resolveNextRequest(after: completedRequest)
            library.markFinished(request: completedRequest, nextRequest: resolvedNextRequest)
            guard autoPlayNext,
                  let resolvedNextRequest,
                  model.request.contentID == completedRequest.contentID else { return }
            playNext(resolvedNextRequest)
        }
    }

    private func playNext(_ request: PlaybackRequest) {
        session.resetProgressTracking()
        nextRequest = nil
        library.markPlaybackStarted(request: request)
        Task {
            await model.play(
                request,
                registry: environment.registry,
                sourceLookup: environment.sourceLookup,
                subtitleRegistry: environment.subtitleRegistry,
                enabledSubtitleProviderIDs: enabledSubtitleProviderIDs
            )
            finishedContentID = nil
        }
    }

    private func resolveNextRequest(after request: PlaybackRequest) async -> PlaybackRequest? {
        await nextUnwatchedPlaybackRequest(
            after: request,
            environment: environment,
            library: library
        )
    }

    private var enabledSubtitleProviderIDs: Set<String> {
        thirdPartySubtitlesEnabled ? ["wizdom", "ktuvit"] : []
    }

    private var playerOrientation: PlayerOrientationPreference {
        PlayerOrientationPreference(rawValue: playerOrientationRawValue) ?? .autoRotate
    }

    private func openSubtitleStudio() {
        Task {
            subtitleStudioContext = await session.beginSubtitleStudio()
        }
    }
}

private extension View {
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert("Something went wrong", isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { _ in }
        )) {
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: { Text(message.wrappedValue ?? "Unknown error") }
    }
}
