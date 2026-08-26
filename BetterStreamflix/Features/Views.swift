import SwiftUI

struct RootView: View {
    private enum Tab: Hashable { case home, movies, series, search, library }

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
            NavigationStack { MyLibraryView() }
                .tabItem { Label("My Library", systemImage: "bookmark.fill") }
                .tag(Tab.library)
        }
        .tint(.red)
    }
}

struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var model = HomeViewModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if !library.progress.isEmpty {
                    MediaShelfView(title: "Continue Watching", items: library.progress.map(\.media), progress: library.progress)
                }
                let favoriteSeries = library.favorites.filter { $0.kind == .series }
                if !favoriteSeries.isEmpty {
                    MediaShelfView(title: "Favorite Series", items: favoriteSeries)
                }
                let favoriteMovies = library.favorites.filter { $0.kind == .movie }
                if !favoriteMovies.isEmpty {
                    MediaShelfView(title: "Favorite Movies", items: favoriteMovies)
                }
                ForEach(model.shelves) { shelf in
                    MediaShelfView(title: shelf.title, items: shelf.items)
                }
            }
            .padding(.vertical)
        }
        .background(Color.black)
        .navigationTitle("BetterStreamflix")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink(destination: SettingsView()) { Image(systemName: "gearshape") } } }
        .overlay { if model.isLoading && model.shelves.isEmpty { ProgressView("Loading StreamingCommunity…") } }
        .task { await model.load(registry: environment.registry) }
        .refreshable { await model.load(registry: environment.registry, force: true) }
        .navigationDestination(for: MediaItem.self) { DetailsView(item: $0) }
        .errorAlert($model.errorMessage)
    }
}

struct MediaShelfView: View {
    let title: String
    let items: [MediaItem]
    var progress: [WatchProgress] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold()).padding(.horizontal)
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
                    }
                }
                .padding(.horizontal)
            }
        }
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
                .frame(width: 135, height: 202)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
                if let progress {
                    GeometryReader { geometry in
                        VStack { Spacer(); Rectangle().fill(.red).frame(width: geometry.size.width * progress, height: 4) }
                    }
                }
            }
            Text(item.title).font(.caption.weight(.semibold)).lineLimit(2).frame(width: 135, alignment: .leading)
            if let progressDetail {
                Text(progressDetail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: 135, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
    }
}

struct CatalogView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var model: CatalogViewModel

    init(kind: MediaKind) { _model = StateObject(wrappedValue: CatalogViewModel(kind: kind)) }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 14)], spacing: 20) {
                ForEach(model.items) { item in
                    NavigationLink(value: item) { PosterCard(item: item) }.buttonStyle(.plain)
                        .onAppear { if item == model.items.last { Task { await model.loadNext(registry: environment.registry) } } }
                }
            }
            .padding()
            if model.isLoading { ProgressView().padding() }
        }
        .background(.black)
        .navigationTitle(model.kind == .movie ? "Movies" : "Series")
        .navigationDestination(for: MediaItem.self) { DetailsView(item: $0) }
        .task { await model.loadNext(registry: environment.registry) }
        .errorAlert($model.errorMessage)
    }
}

struct SearchView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var model = SearchViewModel()
    @Binding var isSearchPresented: Bool

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 14)], spacing: 20) {
                ForEach(model.results) { item in
                    NavigationLink(value: item) { PosterCard(item: item) }.buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(.black)
        .navigationTitle("Search")
        .searchable(
            text: $model.query,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Movies and series"
        )
        .onChange(of: model.query) { _, _ in model.search(registry: environment.registry) }
        .overlay { if model.isLoading { ProgressView() } }
        .navigationDestination(for: MediaItem.self) { DetailsView(item: $0) }
        .errorAlert($model.errorMessage)
    }
}

struct DetailsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var model: DetailsViewModel
    @State private var selectedSeason: MediaSeason?
    @State private var playback: PlaybackRequest?

    init(item: MediaItem) { _model = StateObject(wrappedValue: DetailsViewModel(item: item)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AsyncImage(url: model.item.backdropURL ?? model.item.posterURL) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { Rectangle().fill(.gray.opacity(0.2)) }
                }
                .frame(maxWidth: .infinity).frame(height: 245).clipped()

                VStack(alignment: .leading, spacing: 14) {
                    Text(model.item.title).font(.largeTitle.bold())
                    HStack(spacing: 12) {
                        if let rating = model.item.rating { Label(String(format: "%.1f", rating), systemImage: "star.fill").foregroundStyle(.yellow) }
                        if let release = model.item.releaseDate { Text(String(release.prefix(4))) }
                        if let quality = model.item.quality { Text(quality).padding(.horizontal, 7).overlay { RoundedRectangle(cornerRadius: 4).stroke(.secondary) } }
                    }.font(.subheadline)
                    if let overview = model.item.overview { Text(overview).foregroundStyle(.secondary) }
                    HStack {
                        Button {
                            guard let request = primaryPlaybackRequest else { return }
                            Task { await beginPlayback(request) }
                        } label: { Label(primaryActionTitle, systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .disabled(primaryPlaybackRequest == nil)
                        Button { library.toggleFavorite(model.item) } label: {
                            Image(systemName: library.isFavorite(model.item) ? "bookmark.fill" : "bookmark").frame(width: 44)
                        }.buttonStyle(.bordered)
                    }

                    if !model.item.seasons.isEmpty { seasonsSection }
                    if !model.item.cast.isEmpty {
                        Text("Cast").font(.title2.bold())
                        Text(model.item.cast.map(\.name).joined(separator: " · ")).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal)
            }
        }
        .background(.black)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if model.isLoading && model.item.overview == nil { ProgressView() } }
        .task {
            await model.load(registry: environment.registry)
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
                    Button {
                        Task { await beginPlayback(PlaybackRequest(media: model.item, episode: episode)) }
                    } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: episode.posterURL) { phase in
                                if let image = phase.image { image.resizable().scaledToFill() } else { Rectangle().fill(.gray.opacity(0.2)) }
                            }.frame(width: 120, height: 68).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading) {
                                Text("E\(episode.number) · \(episode.title ?? "Episode")").font(.headline)
                                if let overview = episode.overview { Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                            Spacer(); Image(systemName: "play.circle.fill").font(.title2)
                        }
                    }.buttonStyle(.plain)
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
        guard let season = selectedSeason ?? model.item.seasons.first,
              let episodes = model.episodes[season.id] else { return nil }
        let progressEpisode = library.latestProgress(for: model.item)?.episode
        let episode = episodes.first(where: { candidate in
            candidate.id == progressEpisode?.id || (
                candidate.seasonNumber == progressEpisode?.seasonNumber &&
                candidate.number == progressEpisode?.number
            )
        }) ?? episodes.first
        guard let episode else { return nil }
        return PlaybackRequest(media: model.item, episode: episode)
    }

    private var primaryActionTitle: String {
        guard let progress = library.latestProgress(for: model.item) else { return "Play" }
        if model.item.kind == .movie { return progress.resumeLabel ?? "Play" }
        guard let episode = progress.episode else { return "Play" }
        return progress.resumeLabel.map { "S\(episode.seasonNumber) E\(episode.number) · \($0)" }
            ?? "S\(episode.seasonNumber) E\(episode.number)"
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
}

struct MyLibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        List {
            if !library.progress.isEmpty {
                Section("Continue Watching") {
                    ForEach(library.progress) { progress in
                        ProgressRow(progress: progress)
                    }
                }
            }
            let favoriteSeries = library.favorites.filter { $0.kind == .series }
            if !favoriteSeries.isEmpty {
                Section("Favorite Series") {
                    ForEach(favoriteSeries) { item in
                        NavigationLink(value: item) { Text(item.title) }
                    }
                }
            }
            let favoriteMovies = library.favorites.filter { $0.kind == .movie }
            if !favoriteMovies.isEmpty {
                Section("Favorite Movies") {
                    ForEach(favoriteMovies) { item in
                        NavigationLink(value: item) { Text(item.title) }
                    }
                }
            }
            if library.favorites.isEmpty {
                Section("Favorites") {
                    Text("Your favorite movies and series will appear here.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("My Library")
        .navigationDestination(for: MediaItem.self) { DetailsView(item: $0) }
    }
}

struct ProgressRow: View {
    let progress: WatchProgress
    var body: some View {
        NavigationLink(value: progress.media) {
            VStack(alignment: .leading) {
                Text(progress.displayTitle)
                if let episodeTitle = progress.episode?.title {
                    Text(episodeTitle).font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: progress.fraction).tint(.red)
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @AppStorage("player.autoNext") private var autoNext = true
    @AppStorage("player.subtitleLanguage.primary") private var primarySubtitleLanguage = "en"
    @AppStorage("player.subtitleLanguage.secondary") private var secondarySubtitleLanguage = ""
    @AppStorage("player.audioLanguage") private var audioLanguage = "en"
    @State private var providerDomain = ""
    @State private var providerMessage: String?

    var body: some View {
        Form {
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
            }
            Section("Playback Languages") {
                languagePicker("Default subtitles", selection: $primarySubtitleLanguage)
                languagePicker("Backup subtitles", selection: $secondarySubtitleLanguage, allowsNone: true)
                languagePicker("Default audio", selection: $audioLanguage)
                Text("If the selected audio track is unavailable, English is used automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                Text("BetterStreamflix for iOS")
                Text("This app does not host media. Use it only for content you are authorized to access.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
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
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("player.autoNext") private var autoNext = true
    @AppStorage("player.subtitleLanguage.primary") private var primarySubtitleLanguage = "en"
    @AppStorage("player.subtitleLanguage.secondary") private var secondarySubtitleLanguage = ""
    @AppStorage("player.audioLanguage") private var audioLanguage = "en"
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
            qualityLimit: session.qualityLimit,
            onQualityChanged: { session.setQuality($0) },
            onDismiss: {
                saveProgress()
                dismiss()
            }
        )
        .background(.black)
        .ignoresSafeArea()
        .task { await model.load(registry: environment.registry) }
        .task(id: model.source?.url) {
            guard let source = model.source else { return }
            await session.load(
                source: source,
                resumeAt: library.resumePosition(for: model.request.contentID),
                primarySubtitleLanguage: primarySubtitleLanguage,
                secondarySubtitleLanguage: secondarySubtitleLanguage,
                audioLanguage: audioLanguage
            )
            session.onEnded = { handlePlaybackEnded() }
        }
        .onDisappear { saveProgress(); session.stop() }
        .statusBarHidden()
        .errorAlert($model.errorMessage)
    }

    private func saveProgress() {
        guard finishedContentID != model.request.contentID else { return }
        library.updateProgress(request: model.request, position: session.position, duration: session.duration)
    }

    private func handlePlaybackEnded() {
        let completedRequest = model.request
        finishedContentID = completedRequest.contentID
        library.markFinished(request: completedRequest, nextRequest: nextRequest)
        guard autoNext, let nextRequest else { return }
        session.resetProgressTracking()
        Task {
            await model.play(nextRequest, registry: environment.registry)
            finishedContentID = nil
            self.nextRequest = nil
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
