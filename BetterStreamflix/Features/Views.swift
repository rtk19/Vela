import SwiftUI
import UIKit

private enum MediaArtworkLayout {
    static let shelfPosterWidth: CGFloat = 112
    static let gridSpacing: CGFloat = 12
    static let gridHorizontalPadding: CGFloat = 20
    static let gridColumns = Array(
        repeating: GridItem(.flexible(), spacing: gridSpacing),
        count: 3
    )
}

struct RootView: View {
    private enum Tab: Hashable { case home, movies, series, search, settings }

    @State private var selectedTab: Tab = .home
    @State private var searchIsPresented = false

    var body: some View {
        TabView(selection: Binding(
            get: { selectedTab },
            set: { tab in
                selectedTab = tab
                searchIsPresented = tab == .search
            }
        )) {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)
            NavigationStack { CatalogView(kind: .movie) }
                .tabItem { Label("Movies", systemImage: "film.fill") }
                .tag(Tab.movies)
            NavigationStack { CatalogView(kind: .series) }
                .tabItem { Label("Series", systemImage: "tv.fill") }
                .tag(Tab.series)
            NavigationStack { SearchView(isSearchPresented: $searchIsPresented) }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(.red)
        .overlay(alignment: .top) {
            SourceLookupStatusOverlay()
                .safeAreaPadding(.top, 8)
                .zIndex(100)
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sourceLookup: SourceLookupCoordinator
    @StateObject private var model = HomeViewModel()
    @State private var selectedDetails: MediaItem?
    @State private var playback: PlaybackRequest?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if !model.trendingTitles.isEmpty {
                    TrendingHeroCarousel(
                        titles: model.trendingTitles,
                        resolvingKeys: sourceLookup.activeKeys,
                        onPlay: openForPlayback,
                        onDetails: openDetails
                    )
                } else if model.isTrendingLoading {
                    TrendingHeroLoadingView()
                } else if let message = model.trendingMessage {
                    TrendingHeroUnavailableView(message: message)
                }
                if !library.continueWatching.isEmpty {
                    ContinueWatchingShelfView(
                        progress: library.continueWatching,
                        onDetails: { selectedDetails = $0 },
                        onResume: { value in
                            playback = PlaybackRequest(media: value.media, episode: value.episode)
                        },
                        onMarkAsWatched: { value in markAsWatched(value) },
                        onRemoveFromContinueWatching: { library.removeProgress($0) }
                    )
                }
                let watchlistSeries = library.watchlist.filter { $0.kind == .series }
                if !watchlistSeries.isEmpty {
                    MediaShelfView(title: "Watchlist Series", items: watchlistSeries)
                }
                let watchlistMovies = library.watchlist.filter { $0.kind == .movie }
                if !watchlistMovies.isEmpty {
                    MediaShelfView(title: "Watchlist Movies", items: watchlistMovies)
                }
                ForEach([TMDBCollection.trending(.series), .trending(.movie)]) { collection in
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
                    MediaShelfView(title: shelf.title, items: shelf.items)
                }
            }
            .padding(.bottom)
        }
        .background(Color.black)
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .overlay { if model.isLoading && model.shelves.isEmpty { ProgressView("Loading StreamingCommunity…") } }
        .task {
            async let shelves: Void = model.load(registry: environment.registry)
            async let trending: Void = model.loadTrending(environment: environment)
            _ = await (shelves, trending)
        }
        .refreshable {
            async let shelves: Void = model.load(registry: environment.registry, force: true)
            async let trending: Void = model.loadTrending(environment: environment, force: true)
            _ = await (shelves, trending)
        }
        .navigationDestination(for: MediaItem.self) { DetailsView(item: $0) }
        .navigationDestination(item: $selectedDetails) { DetailsView(item: $0) }
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
        Task {
            selectedDetails = await sourceLookup.resolve(trending, registry: environment.registry)
        }
    }

    private func openForPlayback(_ trending: TrendingTitle) {
        Task {
            guard let item = await sourceLookup.resolve(trending, registry: environment.registry) else { return }
            if item.kind == .movie {
                playback = PlaybackRequest(media: item, episode: nil)
            } else {
                selectedDetails = item
            }
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

    let titles: [TrendingTitle]
    let resolvingKeys: Set<String>
    let onPlay: (TrendingTitle) -> Void
    let onDetails: (TrendingTitle) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var currentIndex = 0
    @State private var slideStartedAt = Date()
    @State private var isInteracting = false
    @State private var timerVersion = 0

    private var currentTitle: TrendingTitle { titles[currentIndex % titles.count] }
    private var isCurrentTitleResolving: Bool { resolvingKeys.contains(currentTitle.lookupKey) }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                ForEach(Array(titles.enumerated()), id: \.element.id) { index, title in
                    CenteredHeroArtwork(url: title.posterURL ?? title.backdropURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .opacity(index == currentIndex ? 1 : 0)
                    .animation(crossfadeAnimation, value: currentIndex)
                    .accessibilityHidden(index != currentIndex)
                }
            }

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.28),
                    .init(color: .black.opacity(0.15), location: 0.48),
                    .init(color: .black.opacity(0.82), location: 0.76),
                    .init(color: .black, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            heroContent
                .opacity(isInteracting ? 0 : 1)
                .padding(.horizontal, 22)
                .padding(.bottom, 44)

            CarouselPageIndicator(
                count: titles.count,
                selectedIndex: currentIndex,
                startedAt: slideStartedAt,
                interval: interval,
                isPaused: isInteracting || scenePhase != .active
            )
            .padding(.bottom, 18)

            PageTitleOverlay(title: "Home")
        }
        .containerRelativeFrame(.horizontal, alignment: .center)
        .frame(height: 690)
        .clipped()
        .contentShape(Rectangle())
        .background {
            HorizontalCarouselPanRecognizer(
                onBegan: beginHorizontalInteraction,
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
            Text("TRENDING NOW")
                .font(.caption2.weight(.bold))
                .tracking(1.8)
                .foregroundStyle(.white.opacity(0.74))

            Text(currentTitle.title)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .contentTransition(.opacity)
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

            HStack(spacing: 12) {
                Button {
                    onPlay(currentTitle)
                } label: {
                    Group {
                        if isCurrentTitleResolving {
                            ProgressView().tint(.black)
                        } else {
                            Label("Watch Now", systemImage: "play.fill")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .clipShape(Capsule())
                .allowsHitTesting(!isCurrentTitleResolving)

                Button {
                    onDetails(currentTitle)
                } label: {
                    Image(systemName: "info")
                        .font(.title3.weight(.semibold))
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.18))
                .clipShape(Circle())
                .allowsHitTesting(!isCurrentTitleResolving)
                .accessibilityLabel("More information")
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

    private func beginHorizontalInteraction() {
        guard !isInteracting else { return }
        timerVersion += 1
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            isInteracting = true
        }
    }

    private func endHorizontalInteraction(translation: CGFloat) {
        guard isInteracting else { return }
        if abs(translation) > 34 {
            select(index: translation < 0 ? nextIndex : previousIndex)
        } else {
            restartTimer()
        }
        withAnimation(reduceMotion ? nil : .easeIn(duration: 0.28).delay(0.12)) {
            isInteracting = false
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

private struct CenteredHeroArtwork: View {
    let url: URL?

    var body: some View {
        Color.clear
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else {
                        Rectangle()
                            .fill(.gray.opacity(0.16))
                            .overlay { ProgressView().tint(.white.opacity(0.7)) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .clipped()
    }
}

private struct CarouselPageIndicator: View {
    let count: Int
    let selectedIndex: Int
    let startedAt: Date
    let interval: TimeInterval
    let isPaused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: isPaused)) { context in
            let progress = min(max(context.date.timeIntervalSince(startedAt) / interval, 0), 1)
            HStack(spacing: 8) {
                ForEach(0..<count, id: \.self) { index in
                    if index == selectedIndex {
                        GeometryReader { geometry in
                            Capsule()
                                .fill(.white.opacity(0.28))
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(.white)
                                        .frame(width: geometry.size.width * progress)
                                }
                                .clipShape(Capsule())
                        }
                        .frame(width: 42, height: 7)
                    } else {
                        Circle()
                            .fill(.white.opacity(0.48))
                            .frame(width: 7, height: 7)
                    }
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
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
        .frame(height: 690)
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
    let onEnded: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onEnded: onEnded)
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
        var onEnded: (CGFloat) -> Void
        private weak var host: UIView?
        private weak var marker: AttachmentView?
        private lazy var pan: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            return recognizer
        }()

        init(onBegan: @escaping () -> Void, onEnded: @escaping (CGFloat) -> Void) {
            self.onBegan = onBegan
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
    let progress: [WatchProgress]
    let onDetails: (MediaItem) -> Void
    let onResume: (WatchProgress) -> Void
    let onMarkAsWatched: (WatchProgress) -> Void
    let onRemoveFromContinueWatching: (WatchProgress) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue Watching")
                .font(.title2.bold())
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(progress) { value in
                        Button { onResume(value) } label: {
                            ContinueWatchingCard(progress: value)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { onDetails(value.media) } label: {
                                Label("Details", systemImage: "info.circle")
                            }
                            .tint(.white)
                            Button { onResume(value) } label: {
                                Label(value.isNextUp ? "Play Next" : "Resume", systemImage: "play.fill")
                            }
                            .tint(.white)
                            if value.episode != nil {
                                Button { onMarkAsWatched(value) } label: {
                                    Label("Mark as Watched", systemImage: "checkmark.circle")
                                }
                                .tint(.white)
                            }
                            Button(role: .destructive) {
                                onRemoveFromContinueWatching(value)
                            } label: {
                                Label("Remove from Continue Watching", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

private struct ContinueWatchingCard: View {
    let progress: WatchProgress
    private let width: CGFloat = 276
    private let imageHeight: CGFloat = 158

    private var imageURL: URL? {
        progress.episode?.posterURL ?? progress.media.backdropURL ?? progress.media.posterURL
    }

    private var episodeTitle: String? {
        guard let episode = progress.episode else { return nil }
        return episode.title ?? "Episode \(episode.number)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottom) {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Rectangle()
                            .fill(.gray.opacity(0.22))
                            .overlay {
                                Image(systemName: progress.media.kind == .movie ? "film" : "tv")
                                    .font(.title)
                            }
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
                    if let episodeTitle {
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
                        .tint(.white)
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
        }
        .frame(width: width, alignment: .leading)
        .foregroundStyle(.white)
        .contentShape(Rectangle())
    }
}

struct MediaShelfView: View {
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
                        onResume: onResume,
                        onRemoveFromContinueWatching: onRemoveFromContinueWatching
                    )
                } label: {
                    Text("Show All")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { item in
                        let itemProgress = progress.first(where: {
                            $0.media.id == item.id && $0.providerID == item.providerID
                        })
                        NavigationLink(value: item) {
                            PosterCard(
                                item: item,
                                progress: itemProgress?.fraction,
                                progressDetail: itemProgress?.shelfProgressLabel
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let itemProgress {
                                Button {
                                    onDetails?(item)
                                } label: {
                                    Label("Details", systemImage: "info.circle")
                                }
                                Button {
                                    onResume?(itemProgress)
                                } label: {
                                    Label("Resume", systemImage: "play.fill")
                                }
                                Button(role: .destructive) {
                                    onRemoveFromContinueWatching?(itemProgress)
                                } label: {
                                    Label("Remove from Continue Watching", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

private struct MediaGridView: View {
    let title: String
    let items: [MediaItem]
    let progress: [WatchProgress]
    let onResume: ((WatchProgress) -> Void)?
    let onRemoveFromContinueWatching: ((WatchProgress) -> Void)?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: MediaArtworkLayout.gridColumns, alignment: .leading, spacing: 16) {
                ForEach(items) { item in
                    let itemProgress = progress.first {
                        $0.media.id == item.id && $0.providerID == item.providerID
                    }
                    NavigationLink(value: item) {
                        PosterGridCard(
                            item: item,
                            progress: itemProgress?.fraction,
                            progressDetail: itemProgress?.shelfProgressLabel
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let itemProgress {
                            Button { onResume?(itemProgress) } label: {
                                Label("Resume", systemImage: "play.fill")
                            }
                            Button(role: .destructive) {
                                onRemoveFromContinueWatching?(itemProgress)
                            } label: {
                                Label("Remove from Continue Watching", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, MediaArtworkLayout.gridHorizontalPadding)
            .padding(.vertical)
        }
        .background(.black)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PosterCard: View {
    let item: MediaItem
    var progress: Double?
    var progressDetail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottom) {
                AsyncImage(url: item.posterURL) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { Rectangle().fill(.gray.opacity(0.22)).overlay { Image(systemName: item.kind == .movie ? "film" : "tv") } }
                }
                .frame(
                    width: MediaArtworkLayout.shelfPosterWidth,
                    height: MediaArtworkLayout.shelfPosterWidth * 1.5
                )
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
                if let progress {
                    GeometryReader { geometry in
                        VStack { Spacer(); Rectangle().fill(.red).frame(width: geometry.size.width * progress, height: 4) }
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
                AsyncImage(url: item.posterURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.gray.opacity(0.22))
                            .overlay { Image(systemName: item.kind == .movie ? "film" : "tv") }
                    }
                }
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                if let progress {
                    ProgressView(value: progress)
                        .tint(.red)
                        .background(.black.opacity(0.5))
                }
            }
            Text(item.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
            if let progressDetail {
                Text(progressDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
    }
}

private struct TMDBShelfView: View {
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
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(titles) { title in
                        Button { onSelect(title) } label: {
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
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(!resolvingKeys.contains(title.lookupKey))
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

private struct TMDBPosterCard: View {
    let title: TrendingTitle
    let width: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: title.posterURL ?? title.backdropURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(.gray.opacity(0.22))
                        .overlay { Image(systemName: title.kind == .movie ? "film" : "tv") }
                }
            }
            .aspectRatio(2 / 3, contentMode: .fit)
            .frame(width: width)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(title.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .frame(width: width, alignment: .leading)
        }
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
    @StateObject private var model = TMDBCollectionGridViewModel()
    @State private var selectedDetails: MediaItem?
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
        .background(.black)
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedDetails) { DetailsView(item: $0) }
        .task { await model.loadNext(collection: collection, environment: environment) }
        .errorAlert($model.errorMessage)
    }

    private func open(_ title: TrendingTitle) {
        Task { selectedDetails = await sourceLookup.resolve(title, registry: environment.registry) }
    }
}

struct CatalogView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sourceLookup: SourceLookupCoordinator
    @StateObject private var model: TMDBCollectionsViewModel
    @State private var selectedDetails: MediaItem?
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
        .background(.black)
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .overlay { if model.isLoading && model.titles.isEmpty { ProgressView("Loading TMDB…") } }
        .navigationDestination(item: $selectedDetails) { DetailsView(item: $0) }
        .task { await model.load(environment: environment) }
        .refreshable { await model.load(environment: environment, force: true) }
        .errorAlert($model.errorMessage)
    }

    private func open(_ title: TrendingTitle) {
        Task { selectedDetails = await sourceLookup.resolve(title, registry: environment.registry) }
    }
}

struct SearchView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sourceLookup: SourceLookupCoordinator
    @StateObject private var model = SearchViewModel()
    @StateObject private var discovery = TMDBCollectionsViewModel(
        collections: [.trending(.series), .trending(.movie)]
    )
    @State private var selectedDetails: MediaItem?
    @FocusState private var searchFieldIsFocused: Bool
    @Binding var isSearchPresented: Bool

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
                            NavigationLink(value: item) {
                                PosterGridCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, MediaArtworkLayout.gridHorizontalPadding)
                }
            }
            .padding(.bottom)
        }
        .background(.black)
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: model.query) { _, _ in model.search(registry: environment.registry) }
        .onChange(of: isSearchPresented) { _, presented in
            if presented { searchFieldIsFocused = true }
        }
        .overlay {
            if model.isLoading || (discovery.isLoading && discovery.titles.isEmpty) { ProgressView() }
        }
        .navigationDestination(for: MediaItem.self) { DetailsView(item: $0) }
        .navigationDestination(item: $selectedDetails) { DetailsView(item: $0) }
        .task {
            await discovery.load(environment: environment)
            if isSearchPresented { searchFieldIsFocused = true }
        }
        .errorAlert($model.errorMessage)
        .errorAlert($discovery.errorMessage)
    }

    private func open(_ title: TrendingTitle) {
        Task { selectedDetails = await sourceLookup.resolve(title, registry: environment.registry) }
    }
}

struct DetailsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sourceLookup: SourceLookupCoordinator
    @StateObject private var model: DetailsViewModel
    @State private var selectedSeason: MediaSeason?
    @State private var playback: PlaybackRequest?
    @State private var episodeInfo: MediaEpisode?
    @State private var tmdbHeroArtworkData: Data?

    init(item: MediaItem) { _model = StateObject(wrappedValue: DetailsViewModel(item: item)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                detailsHero

                VStack(alignment: .leading, spacing: 18) {
                    detailsTitle
                    detailsMetadata
                    if let overview = model.item.overview { Text(overview).foregroundStyle(.secondary) }
                    HStack {
                        Button {
                            guard let request = primaryPlaybackRequest else { return }
                            Task { await beginPlayback(request) }
                        } label: { Label(primaryActionTitle, systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .disabled(primaryPlaybackRequest == nil)
                        Button { library.toggleWatchlist(model.item) } label: {
                            Image(systemName: library.isInWatchlist(model.item) ? "bookmark.fill" : "bookmark")
                                .frame(width: 44)
                        }
                        .buttonStyle(.bordered)
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
                .padding(.top, -56)
                .padding(.bottom, 32)
                .zIndex(1)
            }
        }
        .background(.black)
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
            async let initialArtwork = sourceLookup.resolveArtwork(
                for: initialItem,
                environment: environment
            )
            await model.load(registry: environment.registry)
            guard !Task.isCancelled else { return }
            tmdbHeroArtworkData = await initialArtwork
            if tmdbHeroArtworkData == nil,
               model.item.tmdbID != initialItem.tmdbID {
                tmdbHeroArtworkData = await sourceLookup.resolveArtwork(
                    for: model.item,
                    environment: environment
                )
            }
            guard !Task.isCancelled else { return }
            if let episode = library.latestProgress(for: model.item)?.episode,
               let season = model.item.seasons.first(where: { $0.number == episode.seasonNumber }) {
                selectedSeason = season
                await model.loadEpisodes(season, registry: environment.registry)
            } else {
                selectedSeason = selectedSeason ?? model.item.seasons.first
            }
        }
        .fullScreenCover(isPresented: Binding(get: { playback != nil }, set: { if !$0 { playback = nil } })) {
            if let playback {
                PlayerScreen(request: playback, nextRequest: nextRequest(after: playback.episode))
            }
        }
        .errorAlert($model.errorMessage)
    }

    private var detailsHero: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let tmdbHeroArtworkData,
                   let image = UIImage(data: tmdbHeroArtworkData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.gray.opacity(0.18))
                        .overlay {
                            Image(systemName: model.item.kind == .movie ? "film" : "tv")
                                .font(.system(size: 44))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.28),
                    .init(color: .black.opacity(0.15), location: 0.48),
                    .init(color: .black.opacity(0.82), location: 0.76),
                    .init(color: .black, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

        }
        .frame(height: 570)
        .clipped()
    }

    private var detailsTitle: some View {
        Text(model.item.title)
            .font(.system(size: 36, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.55), radius: 12, y: 4)
            .lineLimit(3)
            .minimumScaleFactor(0.72)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var detailsMetadata: some View {
        HStack(spacing: 10) {
            Text(model.item.kind == .movie ? "Movie" : "TV Show")
            if let rating = model.item.rating {
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
                Picker("Season", selection: Binding(get: { selectedSeason ?? firstSeason }, set: { season in
                    selectedSeason = season
                    Task { await model.loadEpisodes(season, registry: environment.registry) }
                })) {
                    ForEach(model.item.seasons) { Text($0.title ?? "Season \($0.number)").tag($0) }
                }
                .pickerStyle(.menu)

                let season = selectedSeason ?? firstSeason
                ForEach(model.episodes[season.id] ?? []) { episode in
                    let episodeProgress = library.progress(for: episode, in: model.item)
                    let isWatched = library.isWatched(episode, in: model.item)
                    Button {
                        Task { await beginPlayback(PlaybackRequest(media: model.item, episode: episode)) }
                    } label: {
                        HStack(spacing: 12) {
                            ZStack(alignment: .bottom) {
                                AsyncImage(url: episode.posterURL) { phase in
                                    if let image = phase.image { image.resizable().scaledToFill() } else { Rectangle().fill(.gray.opacity(0.2)) }
                                }
                                .frame(width: 120, height: 68)
                                .clipped()

                                if let episodeProgress {
                                    ProgressView(value: episodeProgress.fraction)
                                        .tint(.red)
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

        guard let season = selectedSeason ?? model.item.seasons.first,
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
            await model.loadEpisodes(model.item.seasons[seasonIndex + 1], registry: environment.registry)
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

                ScrollView {
                    Text(synopsis)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 100, idealHeight: 140, maxHeight: 260, alignment: .top)
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

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @AppStorage("player.autoNext") private var autoNext = true
    @AppStorage("player.defaultQualityHeight") private var defaultQualityHeight = 0
    @AppStorage("player.defaultPlaybackRate") private var defaultPlaybackRate = 1.0
    @AppStorage("player.subtitleLanguage.primary") private var primarySubtitleLanguage = "en"
    @AppStorage("player.subtitleLanguage.secondary") private var secondarySubtitleLanguage = ""
    @AppStorage("player.audioLanguage") private var audioLanguage = "en"
    @AppStorage("subtitle.provider.wizdom.enabled") private var wizdomSubtitlesEnabled = true
    @AppStorage("subtitle.provider.ktuvit.enabled") private var ktuvitSubtitlesEnabled = true
    @State private var providerDomain = ""
    @State private var providerMessage: String?

    var body: some View {
        Form {
            PageTitleHeader(title: "Settings")
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.black)
                .listRowSeparator(.hidden)

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
            Section("Player") {
                Toggle("Automatically play next episode", isOn: $autoNext)
                Picker("Default quality", selection: $defaultQualityHeight) {
                    Text("Auto").tag(0)
                    Text("480p").tag(480)
                    Text("720p").tag(720)
                    Text("1080p").tag(1080)
                }
                Picker("Default speed", selection: $defaultPlaybackRate) {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { speed in
                        Text("\(speed, specifier: "%.2g")×").tag(speed)
                    }
                }
                Text("If the preferred quality is unavailable, the closest lower resolution is selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Playback Languages") {
                languagePicker("Default subtitles", selection: $primarySubtitleLanguage)
                languagePicker("Backup subtitles", selection: $secondarySubtitleLanguage, allowsNone: true)
                languagePicker("Default audio", selection: $audioLanguage)
                Text("If the selected audio track is unavailable, English is used automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Third-party Subtitles") {
                Toggle("Wizdom", isOn: $wizdomSubtitlesEnabled)
                Toggle("Ktuvit", isOn: $ktuvitSubtitlesEnabled)
                Text("Enabled sources are added to the player's built-in subtitle list and remain available in Picture in Picture. Third-party availability depends on the title and provider service.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                Text("BetterStreamflix for iOS")
                LabeledContent("Version", value: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "Unknown")
                Link(destination: URL(string: "https://github.com/rtk19/BetterStreamflix-iOS-port")!) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://github.com/rtk19/BetterStreamflix-iOS-port/releases")!) {
                    Label("Check for updates", systemImage: "arrow.triangle.2.circlepath")
                }
                Text("This app does not host media. Use it only for content you are authorized to access.").font(.caption).foregroundStyle(.secondary)
                Text("Trending data and images are provided by TMDB. This product uses the TMDB API but is not endorsed or certified by TMDB.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(.black)
        .contentMargins(.top, 0, for: .scrollContent)
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if providerDomain.isEmpty { providerDomain = environment.providerDomain }
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
        let provider = try await environment.registry.provider(id: request.media.providerID)
        let show = request.media.seasons.isEmpty
            ? try await provider.details(for: request.media)
            : request.media
        guard let startingSeasonIndex = show.seasons.firstIndex(where: {
            $0.number == currentEpisode.seasonNumber
        }) else { return nil }

        for seasonIndex in startingSeasonIndex..<show.seasons.count {
            let season = show.seasons[seasonIndex]
            let episodes = try await provider.episodes(for: season, show: show)
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

struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("player.autoNext") private var autoNext = true
    @AppStorage("player.defaultQualityHeight") private var defaultQualityHeight = 0
    @AppStorage("player.defaultPlaybackRate") private var defaultPlaybackRate = 1.0
    @AppStorage("player.subtitleLanguage.primary") private var primarySubtitleLanguage = "en"
    @AppStorage("player.subtitleLanguage.secondary") private var secondarySubtitleLanguage = ""
    @AppStorage("player.audioLanguage") private var audioLanguage = "en"
    @AppStorage("subtitle.provider.wizdom.enabled") private var wizdomSubtitlesEnabled = true
    @AppStorage("subtitle.provider.ktuvit.enabled") private var ktuvitSubtitlesEnabled = true
    @StateObject private var model: PlayerViewModel
    @StateObject private var session = PlayerSession()
    @State private var nextRequest: PlaybackRequest?
    @State private var finishedContentID: String?

    init(request: PlaybackRequest, nextRequest: PlaybackRequest?) {
        _model = StateObject(wrappedValue: PlayerViewModel(request: request))
        _nextRequest = State(initialValue: nextRequest)
    }

    var body: some View {
        NativePlayerController(
            player: session.player,
            availableQualities: session.availableQualities,
            selectedQuality: session.selectedQuality,
            subtitleTimingOffset: session.subtitleTimingOffset,
            canAdjustSubtitleTiming: session.canAdjustSubtitleTiming,
            onQualityChanged: { session.setQuality($0) },
            onAdjustSubtitleTiming: { session.adjustSubtitleTiming(by: $0) },
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
                subtitleRegistry: environment.subtitleRegistry,
                enabledSubtitleProviderIDs: enabledSubtitleProviderIDs
            )
        }
        .task(id: model.source?.url) {
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
            if phase != .active { saveProgress() }
        }
        .onChange(of: session.playbackRate) { _, rate in
            library.updatePlaybackRate(rate, for: model.request)
        }
        .onDisappear { saveProgress(markNearEndFinished: true); session.stop() }
        .statusBarHidden()
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
        var providerIDs: Set<String> = []
        if wizdomSubtitlesEnabled { providerIDs.insert("wizdom") }
        if ktuvitSubtitlesEnabled { providerIDs.insert("ktuvit") }
        return providerIDs
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
