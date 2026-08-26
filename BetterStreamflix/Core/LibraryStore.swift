import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var favorites: [MediaItem] = []
    @Published private(set) var progress: [WatchProgress] = []

    private let fileManager: FileManager
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directory = support.appending(path: "BetterStreamflix", directoryHint: .isDirectory)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    func isFavorite(_ item: MediaItem) -> Bool { favorites.contains(where: { $0.id == item.id && $0.providerID == item.providerID }) }

    func toggleFavorite(_ item: MediaItem) {
        if let index = favorites.firstIndex(where: { $0.id == item.id && $0.providerID == item.providerID }) {
            favorites.remove(at: index)
        } else {
            favorites.insert(item, at: 0)
        }
        save(favorites, to: "favorites.json")
    }

    func resumePosition(for contentID: String) -> Double {
        progress.first(where: { $0.contentID == contentID })?.position ?? 0
    }

    func latestProgress(for item: MediaItem) -> WatchProgress? {
        progress.first { value in
            value.providerID == item.providerID && value.media.id == item.id
        }
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
        if value.fraction < 0.95 { progress.insert(value, at: 0) }
        save(progress, to: "progress.json")
    }

    func markFinished(request: PlaybackRequest, nextRequest: PlaybackRequest?) {
        removeProgress(for: request)
        if let nextRequest {
            removeProgress(for: nextRequest)
            progress.insert(
                WatchProgress(
                    contentID: nextRequest.contentID,
                    providerID: nextRequest.media.providerID,
                    media: nextRequest.media,
                    episode: nextRequest.episode,
                    position: 0,
                    duration: 0,
                    updatedAt: Date()
                ),
                at: 0
            )
        }
        save(progress, to: "progress.json")
    }

    private func load() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        favorites = read([MediaItem].self, from: "favorites.json") ?? []
        let storedProgress = (read([WatchProgress].self, from: "progress.json") ?? [])
            .sorted { $0.updatedAt > $1.updatedAt }
        var seen = Set<String>()
        progress = storedProgress.filter { seen.insert(progressKey(for: $0)).inserted }
        if progress != storedProgress { save(progress, to: "progress.json") }
    }

    private func removeProgress(for request: PlaybackRequest) {
        progress.removeAll { value in
            if request.media.kind == .series {
                return value.providerID == request.media.providerID && value.media.id == request.media.id
            }
            return value.contentID == request.contentID && value.providerID == request.media.providerID
        }
    }

    private func progressKey(for value: WatchProgress) -> String {
        value.media.kind == .series
            ? "\(value.providerID):series:\(value.media.id)"
            : "\(value.providerID):movie:\(value.contentID)"
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
