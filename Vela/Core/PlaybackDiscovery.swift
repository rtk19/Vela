import Foundation
import AVFoundation

struct PlaybackSourcePreference: Codable, Hashable, Sendable {
    let providerID: String
    let serverName: String
    let audioLanguage: String
}

enum StreamSubtitleKind: String, Sendable {
    case selectable, embeddedEnglish, unknown
}

struct PlaybackCandidate: Identifiable, Sendable {
    let id: String
    let preference: PlaybackSourcePreference
    let providerName: String
    let subtitleKind: StreamSubtitleKind
    let displayMetadata: StreamDisplayMetadata?
    let resolve: @Sendable () async throws -> PlaybackSource

    init(id: String, preference: PlaybackSourcePreference, providerName: String,
         subtitleKind: StreamSubtitleKind, displayMetadata: StreamDisplayMetadata? = nil,
         resolve: @escaping @Sendable () async throws -> PlaybackSource) {
        self.id = id
        self.preference = preference
        self.providerName = providerName
        self.subtitleKind = subtitleKind
        self.displayMetadata = displayMetadata
        self.resolve = resolve
    }
}

struct StreamDisplayMetadata: Sendable {
    let origin: String
    let quality: String?
    let sizeBytes: Int64?
    let container: String?
    let audioLanguage: String?
    let releaseType: String?
}

struct PlayableStream: Identifiable, Sendable {
    let candidate: PlaybackCandidate
    let source: PlaybackSource
    let qualities: [StreamQuality]
    var id: String { candidate.id }
    var label: String {
        if let metadata = candidate.displayMetadata {
            var details = [metadata.origin]
            if let quality = metadata.quality { details.append(quality) }
            if let size = metadata.sizeBytes {
                details.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            } else if let container = metadata.container { details.append(container) }
            if let release = metadata.releaseType, details.count < 4 { details.append(release) }
            return details.joined(separator: " · ")
        }
        let audio = candidate.preference.audioLanguage == "ja" ? "Japanese" :
            candidate.preference.audioLanguage == "en" ? "English" :
            candidate.preference.audioLanguage == "he" ? "Hebrew" : "Original audio"
        let embedded = candidate.subtitleKind == .embeddedEnglish ? " · Embedded English subtitles" : ""
        return "\(candidate.providerName) · \(candidate.preference.serverName) · \(audio)\(embedded)"
    }
}

struct PlaybackLookupContext: Sendable {
    let request: PlaybackRequest
    var alternativeTitles: [String] = []
    var seasonTitle: String? = nil
    var seasonYear: Int? = nil
    var absoluteEpisodeNumber: Int? = nil
    var seasonEpisodeCount: Int? = nil
    var titles: [String] {
        ([request.media.title, request.media.originalTitle].compactMap { $0 } + alternativeTitles)
            .filter { !$0.isEmpty }
    }
}

protocol PlaybackProvider: Sendable {
    var id: String { get }
    func candidates(for context: PlaybackLookupContext) async throws -> [PlaybackCandidate]
}

struct EnrichedPlaybackProvider: PlaybackProvider {
    let provider: any PlaybackProvider
    let context: Task<PlaybackLookupContext, Never>
    var id: String { provider.id }
    func candidates(for unused: PlaybackLookupContext) async throws -> [PlaybackCandidate] {
        try await withTaskCancellationHandler {
            let value = await context.value
            try Task.checkCancellation()
            return try await provider.candidates(for: value)
        } onCancel: { context.cancel() }
    }
}

struct StreamingCommunityPlaybackProvider: PlaybackProvider {
    let provider: any MediaProvider
    var id: String { provider.id }
    func candidates(for context: PlaybackLookupContext) async throws -> [PlaybackCandidate] {
        let request = try await SourceLookupCoordinator.providerRequest(for: context.request, using: provider)
        return [PlaybackCandidate(
            id: "\(id):default", preference: .init(providerID: id, serverName: "Default", audioLanguage: "en"),
            providerName: provider.displayName, subtitleKind: .selectable,
            resolve: { try await provider.playbackSource(for: request) }
        )]
    }
}

struct StreamSelectionPolicy: Sendable {
    var preference: PlaybackSourcePreference?
    var audioLanguage: String = "en"
    var backupAudioLanguage: String = ""
    var qualityHeight: Int = 0

    func best(in streams: [PlayableStream]) -> PlayableStream? {
        streams.enumerated().min { score($0.element, order: $0.offset).lexicographicallyPrecedes(score($1.element, order: $1.offset)) }?.element
    }

    private func score(_ stream: PlayableStream, order: Int) -> [Int] {
        let candidate = stream.candidate
        let language = candidate.preference.audioLanguage
        let audioRank: Int
        if language == audioLanguage {
            audioRank = 0
        } else if !backupAudioLanguage.isEmpty, language == backupAudioLanguage {
            audioRank = 1
        } else {
            audioRank = ["en", "ja", "he"].firstIndex(of: language).map { $0 + 2 } ?? 5
        }
        let quality = qualityHeight > 0 ? StreamQuality.closest(to: qualityHeight, in: stream.qualities)?.height : nil
        let qualityRank = quality.map { abs(qualityHeight - $0) } ?? (qualityHeight > 0 ? 10000 : 0)
        return [preference == candidate.preference ? 0 : 1, audioRank,
                candidate.subtitleKind == .embeddedEnglish ? 2 : candidate.subtitleKind == .unknown ? 1 : 0,
                qualityRank, order]
    }
}

/// Owns a playback-scoped search. The initial result does not end discovery;
/// late results update the menu without replacing the stream already playing.
@MainActor
final class PlaybackDiscovery {
    private(set) var streams: [PlayableStream] = []
    private(set) var isSearching = false
    var onUpdate: (([PlayableStream]) -> Void)?
    var onSearchingChanged: ((Bool) -> Void)?
    private var searchTask: Task<Void, Never>?
    private var initialDeadlineTask: Task<Void, Never>?
    private var backgroundDeadlineTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var initial: CheckedContinuation<PlayableStream, Error>?
    private var generation = UUID()
    private var policy = StreamSelectionPolicy()
    private let settleDelay: Duration
    private let initialDeadline: Duration
    private let backgroundDeadline: Duration
    private let prepare: @Sendable (PlaybackCandidate) async throws -> PlayableStream

    init(settleDelay: Duration = .seconds(2), initialDeadline: Duration = .seconds(15),
         backgroundDeadline: Duration = .seconds(90),
         prepare: @escaping @Sendable (PlaybackCandidate) async throws -> PlayableStream = { try await PlaybackDiscovery.prepare($0) }) {
        self.settleDelay = settleDelay
        self.initialDeadline = initialDeadline
        self.backgroundDeadline = backgroundDeadline
        self.prepare = prepare
    }

    nonisolated static func prepare(_ candidate: PlaybackCandidate) async throws -> PlayableStream {
        try await withThrowingTaskGroup(of: PlayableStream.self) { group in
            group.addTask { try await prepareStream(candidate) }
            group.addTask { try await Task.sleep(for: .seconds(15)); throw AppError.noStream }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw AppError.noStream }
            return result
        }
    }

    private nonisolated static func prepareStream(_ candidate: PlaybackCandidate) async throws -> PlayableStream {
        let source = try await candidate.resolve()
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source.url, options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers])
        let isPlayable = try await withTaskCancellationHandler {
            try await asset.load(.isPlayable)
        } onCancel: { asset.cancelLoading() }
        guard isPlayable else { throw AppError.noStream }
        let qualities = await HLSPlaylistInspector().availableQualities(for: source)
        let nativeSubtitles = try? await asset.loadMediaSelectionGroup(for: .legible)
        let subtitleKind: StreamSubtitleKind
        if candidate.subtitleKind == .unknown {
            subtitleKind = !source.subtitles.isEmpty || !(nativeSubtitles?.options.isEmpty ?? true) ? .selectable :
                candidate.preference.audioLanguage == "ja" ? .embeddedEnglish : .selectable
        } else { subtitleKind = candidate.subtitleKind }
        let verified = PlaybackCandidate(id: candidate.id, preference: candidate.preference, providerName: candidate.providerName,
            subtitleKind: subtitleKind, displayMetadata: candidate.displayMetadata, resolve: candidate.resolve)
        return PlayableStream(candidate: verified, source: source, qualities: qualities)
    }

    func start(context: PlaybackLookupContext, providers: [any PlaybackProvider], policy: StreamSelectionPolicy) async throws -> PlayableStream {
        cancel()
        let operation = UUID()
        generation = operation
        self.policy = policy
        streams = []
        isSearching = true
        onUpdate?([])
        onSearchingChanged?(true)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                initial = continuation
                let prepare = self.prepare
                searchTask = Task { [weak self] in
                    await withTaskGroup(of: Void.self) { group in
                        for provider in providers {
                            group.addTask {
                                do {
                                    let candidates = try await provider.candidates(for: context)
                                    print(
                                        "PLAYBACK PROVIDER CANDIDATES:",
                                        provider.id,
                                        "count=\(candidates.count)"
                                    )

                                    for candidate in candidates {
                                        print(
                                            "PLAYBACK CANDIDATE:",
                                            provider.id,
                                            candidate.id,
                                            candidate.providerName,
                                            candidate.preference.serverName
                                        )
                                    }
                                    await withTaskGroup(of: PlayableStream?.self) { servers in
                                        for candidate in candidates.prefix(12) {
                                            servers.addTask {
                                                do {
                                                    return try await prepare(candidate)
                                                } catch {
                                                    print(
                                                        "PLAYBACK SOURCE REJECTED:",
                                                        candidate.id,
                                                        candidate.providerName,
                                                        candidate.preference.serverName,
                                                        error
                                                    )
                                                    return nil
                                                }
                                            }
                                        }
                                        for await stream in servers {
                                            guard !Task.isCancelled else { servers.cancelAll(); break }
                                            if let stream { await self?.receive(stream, operation: operation) }
                                        }
                                    }
                                } catch { /* An unavailable provider must not fail other providers. */ }
                            }
                        }
                        await group.waitForAll()
                    }
                    self?.finishBackground(operation: operation)
                }
                initialDeadlineTask = Task { [weak self, initialDeadline] in
                    do { try await Task.sleep(for: initialDeadline) } catch { return }
                    guard self?.generation == operation else { return }
                    self?.finishInitialDeadline(operation: operation)
                }
                backgroundDeadlineTask = Task { [weak self, backgroundDeadline] in
                    do { try await Task.sleep(for: backgroundDeadline) } catch { return }
                    guard self?.generation == operation else { return }
                    self?.searchTask?.cancel()
                    self?.finishBackground(operation: operation)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.generation == operation else { return }
                self?.cancel()
            }
        }
    }

    private func receive(_ stream: PlayableStream, operation: UUID) {
        guard generation == operation, isSearching, !streams.contains(where: { $0.id == stream.id }) else { return }
        streams.append(stream)
        onUpdate?(streams)
        guard initial != nil, settleTask == nil else { return }
        settleTask = Task { [weak self, settleDelay] in
            do { try await Task.sleep(for: settleDelay) } catch { return }
            guard self?.generation == operation else { return }
            self?.deliverInitial()
        }
    }

    private func deliverInitial() {
        guard let initial, let best = policy.best(in: streams) else { return }
        self.initial = nil
        initialDeadlineTask?.cancel()
        initialDeadlineTask = nil
        settleTask?.cancel()
        settleTask = nil
        initial.resume(returning: best)
    }

    private func finishInitialDeadline(operation: UUID) {
        guard generation == operation, initial != nil else { return }
        if policy.best(in: streams) != nil {
            deliverInitial()
        } else if let initial {
            self.initial = nil
            initialDeadlineTask = nil
            settleTask?.cancel()
            settleTask = nil
            initial.resume(throwing: AppError.noStream)
        }
    }

    private func finishBackground(operation: UUID) {
        guard generation == operation else { return }
        guard isSearching else { return }
        isSearching = false
        searchTask = nil
        backgroundDeadlineTask?.cancel()
        backgroundDeadlineTask = nil
        initialDeadlineTask?.cancel()
        initialDeadlineTask = nil
        settleTask?.cancel()
        settleTask = nil
        deliverInitial()
        if let initial { self.initial = nil; initial.resume(throwing: AppError.noStream) }
        onSearchingChanged?(false)
    }

    func cancel() {
        generation = UUID()
        searchTask?.cancel()
        initialDeadlineTask?.cancel()
        backgroundDeadlineTask?.cancel()
        settleTask?.cancel()
        searchTask = nil
        initialDeadlineTask = nil
        backgroundDeadlineTask = nil
        settleTask = nil
        let wasSearching = isSearching
        isSearching = false
        if let initial { self.initial = nil; initial.resume(throwing: CancellationError()) }
        if wasSearching { onSearchingChanged?(false) }
    }
}
