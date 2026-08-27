import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var watchlist: [MediaItem] = []
    @Published private(set) var progress: [WatchProgress] = []
    @Published private(set) var watchedEpisodes: Set<WatchedEpisode> = []

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

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directory = directory
            ?? support.appending(path: "BetterStreamflix", directoryHint: .isDirectory)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
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

    func latestProgress(for item: MediaItem) -> WatchProgress? {
        if item.kind == .series {
            guard let currentKey = currentSeriesProgressKeys[seriesKey(for: item)] else { return nil }
            return progress.first { progressKey(for: $0) == currentKey }
        }
        return progress.first { value in
            value.providerID == item.providerID &&
                value.media.id == item.id &&
                value.episode == nil
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
        if let nextRequest { promoteToContinueWatching(nextRequest) }
    }

    func markWatched(request: PlaybackRequest) {
        guard request.episode != nil else { return }
        watchedEpisodes.insert(WatchedEpisode(request: request))
        let currentKey = progress(for: request).map(progressKey(for:)) ?? progressKey(for: request)
        removeProgress(for: request)
        let showKey = seriesKey(for: request.media)
        if currentSeriesProgressKeys[showKey] == currentKey {
            currentSeriesProgressKeys.removeValue(forKey: showKey)
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
        saveProgress()
    }

    private func load() {
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
            let availableProgressKeys = Set(progress.map(progressKey(for:)))
            currentSeriesProgressKeys = storedCurrentSeriesProgressKeys.filter {
                availableProgressKeys.contains($0.value)
            }
        } else {
            currentSeriesProgressKeys = migratedCurrentSeriesProgressKeys()
        }
        playbackRates = read([String: Double].self, from: "playback-rates.json") ?? [:]
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
        "\(item.providerID):series:\(item.id)"
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

    private func saveProgress() {
        save(progress, to: "progress.json")
        save(currentSeriesProgressKeys, to: "continue-watching.json")
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

    private func progressMatches(_ value: WatchProgress, request: PlaybackRequest) -> Bool {
        guard value.providerID == request.media.providerID else { return false }
        guard let requestedEpisode = request.episode else {
            return value.episode == nil && value.contentID == request.contentID
        }
        guard value.media.id == request.media.id, let savedEpisode = value.episode else { return false }
        return value.contentID == request.contentID || (
            savedEpisode.seasonNumber == requestedEpisode.seasonNumber &&
            savedEpisode.number == requestedEpisode.number
        )
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
}
