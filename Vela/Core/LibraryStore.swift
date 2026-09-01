import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var watchlist: [MediaItem] = []
    @Published private(set) var progress: [WatchProgress] = []
    @Published private(set) var watchedEpisodes: Set<WatchedEpisode> = []

    var completedSeriesRequests: [PlaybackRequest] {
        completedSeriesCheckpoints.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { PlaybackRequest(media: $0.media, episode: $0.episode) }
    }

    var continueWatching: [WatchProgress] {
        progress.filter { value in
            guard value.media.kind == .series else { return true }
            return currentSeriesProgressKeys[seriesKey(for: value.media)] == progressKey(for: value)
        }
    }

    private let fileManager: FileManager
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var currentSeriesProgressKeys: [String: String] = [:]
    private var playbackRates: [String: Double] = [:]
    private var completedSeriesCheckpoints: [String: WatchProgress] = [:]
    private var subtitleSyncVersionsByContent: [String: [SubtitleSyncVersion]] = [:]

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        // Keep the pre-rebrand directory so an in-place Vela update retains every user's library.
        self.directory = directory
            ?? support.appending(path: "BetterStreamflix", directoryHint: .isDirectory)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    func exportUserData() throws -> Data {
        try backupService.exportData()
    }

    func backupSummary(for data: Data) throws -> UserDataBackupSummary {
        try backupService.summary(for: data)
    }

    func importUserData(_ data: Data) throws {
        try backupService.restore(from: data)
        load()
    }

    func isInWatchlist(_ item: MediaItem) -> Bool {
        watchlist.contains { $0.id == item.id && $0.providerID == item.providerID }
    }

    func toggleWatchlist(_ item: MediaItem) {
        if let index = watchlist.firstIndex(where: { $0.id == item.id && $0.providerID == item.providerID }) {
            watchlist.remove(at: index)
        } else {
            watchlist.insert(item, at: 0)
        }
        save(watchlist, to: "watchlist.json")
    }

    func resumePosition(for request: PlaybackRequest) -> Double {
        progress(for: request)?.position ?? 0
    }

    func playbackRate(for request: PlaybackRequest, defaultRate: Double) -> Double {
        playbackRates[titleKey(for: request.media)] ?? defaultRate
    }

    func updatePlaybackRate(_ rate: Double, for request: PlaybackRequest) {
        guard rate.isFinite, rate > 0 else { return }
        playbackRates[titleKey(for: request.media)] = rate
        savePlaybackRates()
    }

    func subtitleSyncVersions(for request: PlaybackRequest) -> [SubtitleSyncVersion] {
        (subtitleSyncVersionsByContent[progressKey(for: request)] ?? [])
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func saveSubtitleSyncVersion(
        subtitle: SubtitleSource,
        offset: Double,
        for request: PlaybackRequest,
        now: Date = Date()
    ) -> SubtitleSyncVersion? {
        let version = SubtitleSyncVersion(subtitle: subtitle, offset: offset, createdAt: now)
        guard version.offsetTenths != 0 else { return nil }
        let key = progressKey(for: request)
        subtitleSyncVersionsByContent[key, default: []].append(version)
        saveSubtitleSyncVersions()
        return version
    }

    func deleteSubtitleSyncVersion(_ versionID: UUID, for request: PlaybackRequest) {
        let key = progressKey(for: request)
        subtitleSyncVersionsByContent[key]?.removeAll { $0.id == versionID }
        if subtitleSyncVersionsByContent[key]?.isEmpty == true {
            subtitleSyncVersionsByContent.removeValue(forKey: key)
        }
        saveSubtitleSyncVersions()
    }

    func latestProgress(for item: MediaItem) -> WatchProgress? {
        if item.kind == .series {
            guard let currentKey = currentSeriesProgressKeys[seriesKey(for: item)] else { return nil }
            return progress.first {
                sameTitle($0.media, as: item) && progressKey(for: $0) == currentKey
            }
        }
        return progress.first { value in
            value.episode == nil && sameTitle(value.media, as: item)
        }
    }

    func progress(for request: PlaybackRequest) -> WatchProgress? {
        progress.first { value in progressMatches(value, request: request) }
    }

    func progress(for episode: MediaEpisode, in item: MediaItem) -> WatchProgress? {
        progress(for: PlaybackRequest(media: item, episode: episode))
    }

    func isWatched(_ episode: MediaEpisode, in item: MediaItem) -> Bool {
        watchedEpisodes.contains { $0.matches(episode, in: item) }
    }

    func isWatched(_ request: PlaybackRequest) -> Bool {
        guard let episode = request.episode else { return false }
        return isWatched(episode, in: request.media)
    }

    func markPlaybackStarted(request: PlaybackRequest) {
        let wasWatched = isWatched(request)
        let existing = wasWatched ? nil : progress(for: request)
        if wasWatched {
            watchedEpisodes.remove(WatchedEpisode(request: request))
            saveWatchedEpisodes()
        }
        removeProgress(for: request)
        let value = WatchProgress(
            contentID: request.contentID,
            providerID: request.media.providerID,
            media: request.media,
            episode: request.episode,
            position: existing?.position ?? 0,
            duration: existing?.duration ?? 0,
            updatedAt: Date()
        )
        progress.insert(value, at: 0)
        setAsCurrentIfSeries(value)
        saveProgress()
    }

    func removeProgress(_ value: WatchProgress) {
        let key = progressKey(for: value)
        progress.removeAll { progressKey(for: $0) == key }
        if value.media.kind == .series,
           currentSeriesProgressKeys[seriesKey(for: value.media)] == key {
            currentSeriesProgressKeys.removeValue(forKey: seriesKey(for: value.media))
        }
        playbackRates.removeValue(forKey: titleKey(for: value.media))
        saveProgress()
        savePlaybackRates()
    }

    func updateProgress(request: PlaybackRequest, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite, duration > 0 else { return }
        let value = WatchProgress(
            contentID: request.contentID,
            providerID: request.media.providerID,
            media: request.media,
            episode: request.episode,
            position: position,
            duration: duration,
            updatedAt: Date()
        )
        removeProgress(for: request)
        if request.episode != nil || value.fraction < 0.95 {
            progress.insert(value, at: 0)
            setAsCurrentIfSeries(value)
        }
        saveProgress()
    }

    func markFinished(request: PlaybackRequest, nextRequest: PlaybackRequest?) {
        if request.episode != nil {
            markWatched(request: request)
        } else {
            removeProgress(for: request)
            saveProgress()
        }
        if let nextRequest {
            promoteToContinueWatching(nextRequest)
        } else if request.episode != nil {
            rememberCompletedSeries(request)
        }
    }

    func markWatched(request: PlaybackRequest) {
        markWatched(requests: [request])
    }

    func markWatched(requests: [PlaybackRequest]) {
        let episodeRequests = requests.filter { $0.episode != nil }
        guard !episodeRequests.isEmpty else { return }

        episodeRequests.forEach { watchedEpisodes.insert(WatchedEpisode(request: $0)) }
        let removedProgressKeys = Set(progress.compactMap { value in
            episodeRequests.contains { progressMatches(value, request: $0) }
                ? progressKey(for: value)
                : nil
        })
        progress.removeAll { value in
            episodeRequests.contains { progressMatches(value, request: $0) }
        }
        currentSeriesProgressKeys = currentSeriesProgressKeys.filter {
            !removedProgressKeys.contains($0.value)
        }
        saveWatchedEpisodes()
        saveProgress()
    }

    func markUnwatched(request: PlaybackRequest) {
        watchedEpisodes.remove(WatchedEpisode(request: request))
        saveWatchedEpisodes()
    }

    func promoteToContinueWatching(_ request: PlaybackRequest) {
        let existing = progress(for: request)
        removeProgress(for: request)
        let value = WatchProgress(
            contentID: request.contentID,
            providerID: request.media.providerID,
            media: request.media,
            episode: request.episode,
            position: existing?.position ?? 0,
            duration: existing?.duration ?? 0,
            updatedAt: Date()
        )
        progress.insert(value, at: 0)
        setAsCurrentIfSeries(value)
        completedSeriesCheckpoints.removeValue(forKey: seriesKey(for: request.media))
        saveProgress()
    }

    func deferUnavailableNextUp(_ value: WatchProgress) {
        guard value.isNextUp, let unavailableEpisode = value.episode else { return }
        let request = PlaybackRequest(media: value.media, episode: unavailableEpisode)
        let key = progressKey(for: value)
        removeProgress(for: request)

        let showKey = seriesKey(for: value.media)
        if currentSeriesProgressKeys[showKey] == key {
            currentSeriesProgressKeys.removeValue(forKey: showKey)
        }

        let previousWatchedEpisode = watchedEpisodes
            .filter {
                $0.providerID == value.media.providerID &&
                    $0.showID == value.media.id &&
                    ($0.seasonNumber, $0.episodeNumber) <
                        (unavailableEpisode.seasonNumber, unavailableEpisode.number)
            }
            .max {
                ($0.seasonNumber, $0.episodeNumber) < ($1.seasonNumber, $1.episodeNumber)
            }

        if let previousWatchedEpisode {
            let episode = MediaEpisode(
                id: "\(value.media.id)/completed-s\(previousWatchedEpisode.seasonNumber)e\(previousWatchedEpisode.episodeNumber)",
                providerID: value.media.providerID,
                showID: value.media.id,
                seasonNumber: previousWatchedEpisode.seasonNumber,
                number: previousWatchedEpisode.episodeNumber,
                title: nil,
                overview: nil,
                posterURL: nil
            )
            completedSeriesCheckpoints[showKey] = WatchProgress(
                contentID: episode.id,
                providerID: value.media.providerID,
                media: value.media,
                episode: episode,
                position: 0,
                duration: 0,
                updatedAt: Date()
            )
        }
        saveProgress()
    }

    private func load() {
        watchlist = []
        progress = []
        watchedEpisodes = []
        currentSeriesProgressKeys = [:]
        playbackRates = [:]
        completedSeriesCheckpoints = [:]
        subtitleSyncVersionsByContent = [:]
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let storedWatchlist = read([MediaItem].self, from: "watchlist.json") {
            watchlist = storedWatchlist
        } else {
            watchlist = read([MediaItem].self, from: "favorites.json") ?? []
            if !watchlist.isEmpty {
                save(watchlist, to: "watchlist.json")
            }
        }
        watchedEpisodes = Set(read([WatchedEpisode].self, from: "watched-episodes.json") ?? [])
        let storedProgress = (read([WatchProgress].self, from: "progress.json") ?? [])
            .sorted { $0.updatedAt > $1.updatedAt }
        var seen = Set<String>()
        progress = storedProgress.filter { value in
            guard seen.insert(progressKey(for: value)).inserted else { return false }
            guard let episode = value.episode else { return true }
            return !isWatched(episode, in: value.media)
        }
        let storedCurrentSeriesProgressKeys = read([String: String].self, from: "continue-watching.json")
        if let storedCurrentSeriesProgressKeys {
            let selectedProgressKeys = Set(storedCurrentSeriesProgressKeys.values)
            for value in progress where selectedProgressKeys.contains(progressKey(for: value)) {
                let key = seriesKey(for: value.media)
                if currentSeriesProgressKeys[key] == nil {
                    currentSeriesProgressKeys[key] = progressKey(for: value)
                }
            }
        } else {
            currentSeriesProgressKeys = migratedCurrentSeriesProgressKeys()
        }
        playbackRates = read([String: Double].self, from: "playback-rates.json") ?? [:]
        completedSeriesCheckpoints = read(
            [String: WatchProgress].self,
            from: "completed-series.json"
        ) ?? [:]
        subtitleSyncVersionsByContent = read(
            [String: [SubtitleSyncVersion]].self,
            from: "subtitle-sync-versions.json"
        ) ?? [:]
        if progress != storedProgress || currentSeriesProgressKeys != storedCurrentSeriesProgressKeys {
            saveProgress()
        }
    }

    private func removeProgress(for request: PlaybackRequest) {
        progress.removeAll { value in progressMatches(value, request: request) }
    }

    private func progressKey(for value: WatchProgress) -> String {
        value.media.kind == .series
            ? "\(value.providerID):series:\(value.media.id):\(value.contentID)"
            : "\(value.providerID):movie:\(value.contentID)"
    }

    private func progressKey(for request: PlaybackRequest) -> String {
        request.media.kind == .series
            ? "\(request.media.providerID):series:\(request.media.id):\(request.contentID)"
            : "\(request.media.providerID):movie:\(request.contentID)"
    }

    private func seriesKey(for item: MediaItem) -> String {
        if let tmdbID = item.tmdbID {
            return "tmdb:series:\(tmdbID)"
        }
        return "\(item.providerID):series:\(item.id)"
    }

    private func titleKey(for item: MediaItem) -> String {
        "\(item.providerID):\(item.kind.rawValue):\(item.id)"
    }

    private func setAsCurrentIfSeries(_ value: WatchProgress) {
        guard value.media.kind == .series else { return }
        currentSeriesProgressKeys[seriesKey(for: value.media)] = progressKey(for: value)
    }

    private func migratedCurrentSeriesProgressKeys() -> [String: String] {
        var result: [String: String] = [:]
        for value in progress where value.media.kind == .series {
            let key = seriesKey(for: value.media)
            if result[key] == nil { result[key] = progressKey(for: value) }
        }
        return result
    }

    private func rememberCompletedSeries(_ request: PlaybackRequest) {
        guard request.media.kind == .series, request.episode != nil else { return }
        completedSeriesCheckpoints[seriesKey(for: request.media)] = WatchProgress(
            contentID: request.contentID,
            providerID: request.media.providerID,
            media: request.media,
            episode: request.episode,
            position: 0,
            duration: 0,
            updatedAt: Date()
        )
        saveProgress()
    }

    private func saveProgress() {
        save(progress, to: "progress.json")
        save(currentSeriesProgressKeys, to: "continue-watching.json")
        save(completedSeriesCheckpoints, to: "completed-series.json")
    }

    private func saveWatchedEpisodes() {
        let sorted = watchedEpisodes.sorted {
            if $0.providerID != $1.providerID { return $0.providerID < $1.providerID }
            if $0.showID != $1.showID { return $0.showID < $1.showID }
            if $0.seasonNumber != $1.seasonNumber { return $0.seasonNumber < $1.seasonNumber }
            return $0.episodeNumber < $1.episodeNumber
        }
        save(sorted, to: "watched-episodes.json")
    }

    private func savePlaybackRates() {
        save(playbackRates, to: "playback-rates.json")
    }

    private func saveSubtitleSyncVersions() {
        save(subtitleSyncVersionsByContent, to: "subtitle-sync-versions.json")
    }

    private func progressMatches(_ value: WatchProgress, request: PlaybackRequest) -> Bool {
        guard sameTitle(value.media, as: request.media) else { return false }
        guard let requestedEpisode = request.episode else {
            return value.episode == nil
        }
        guard let savedEpisode = value.episode else { return false }
        return value.contentID == request.contentID || (
            savedEpisode.seasonNumber == requestedEpisode.seasonNumber &&
            savedEpisode.number == requestedEpisode.number
        )
    }

    private func sameTitle(_ lhs: MediaItem, as rhs: MediaItem) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        if let lhsTMDbID = lhs.tmdbID, let rhsTMDbID = rhs.tmdbID {
            return lhsTMDbID == rhsTMDbID
        }
        return lhs.providerID == rhs.providerID && lhs.id == rhs.id
    }

    private func read<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appending(path: filename)) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to filename: String) {
        guard let data = try? encoder.encode(value) else { return }
        let destination = directory.appending(path: filename)
        let temporary = destination.appendingPathExtension("tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
        }
    }

    private var backupService: UserDataBackupService {
        UserDataBackupService(
            applicationSupportDirectory: directory,
            fileManager: fileManager,
            preferencesDomain: Bundle.main.bundleIdentifier ?? "com.refael.BetterStreamflix",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "Unknown"
        )
    }
}
