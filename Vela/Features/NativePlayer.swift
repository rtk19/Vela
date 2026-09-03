@preconcurrency import AVKit
@preconcurrency import Network
import Combine
@preconcurrency import MediaPlayer
import SwiftUI
import UIKit

@MainActor
private final class HLSSubtitleLoopbackServer {
    private struct Route {
        let content: Data
        let contentType: String
    }

    private var listener: NWListener?
    private var listenerPort: NWEndpoint.Port?
    private var listenerError: NWError?
    private var routes: [String: Route] = [:]
    private var requestBuffers: [ObjectIdentifier: Data] = [:]

    deinit { listener?.cancel() }

    func publish(_ asset: InjectedHLSSubtitleAsset) async throws -> URL {
        let port = try await startIfNeeded()
        let token = UUID().uuidString
        guard let rootURL = URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/") else {
            throw AppError.invalidURL
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: asset.workingDirectory,
                includingPropertiesForKeys: nil
            )
            let localURLs = Dictionary(uniqueKeysWithValues: files.map { file in
                (file.absoluteString, rootURL.appending(path: file.lastPathComponent).absoluteString)
            })
            clear()
            for file in files {
                var content = try Data(contentsOf: file)
                let contentType: String
                if file.pathExtension.lowercased() == "m3u8" {
                    guard var playlist = String(data: content, encoding: .utf8) else {
                        throw AppError.decoding("Injected HLS playlist")
                    }
                    for (fileURL, routeURL) in localURLs {
                        playlist = playlist.replacingOccurrences(of: fileURL, with: routeURL)
                    }
                    content = Data(playlist.utf8)
                    contentType = "application/vnd.apple.mpegurl"
                } else {
                    contentType = "text/vtt; charset=utf-8"
                }
                let routeURL = rootURL.appending(path: file.lastPathComponent)
                routes[routeURL.path] = Route(content: content, contentType: contentType)
            }
            try? FileManager.default.removeItem(at: asset.workingDirectory)
            return rootURL.appending(path: asset.masterPlaylistURL.lastPathComponent)
        } catch {
            try? FileManager.default.removeItem(at: asset.workingDirectory)
            throw error
        }
    }

    func clear() {
        routes.removeAll(keepingCapacity: true)
    }

    private func startIfNeeded() async throws -> NWEndpoint.Port {
        if let listenerPort { return listenerPort }
        if let listenerError { throw listenerError }
        if listener == nil {
            let parameters = NWParameters.tcp
            parameters.acceptLocalOnly = true
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.listenerPort = listener.port
                    case .failed(let error):
                        self.listenerError = error
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: .main)
        }

        for _ in 0..<200 {
            if let listenerPort { return listenerPort }
            if let listenerError { throw listenerError }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError.providerUnavailable("The local subtitle server did not start.")
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                let identifier = ObjectIdentifier(connection)
                if let data { self.requestBuffers[identifier, default: Data()].append(data) }
                if self.requestBuffers[identifier]?.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.respond(
                        to: connection,
                        request: self.requestBuffers.removeValue(forKey: identifier) ?? Data()
                    )
                } else if isComplete || error != nil {
                    self.requestBuffers.removeValue(forKey: identifier)
                    connection.cancel()
                } else {
                    self.receiveRequest(on: connection)
                }
            }
        }
    }

    private func respond(to connection: NWConnection, request: Data) {
        guard let requestText = String(data: request, encoding: .utf8),
              let requestLine = requestText.components(separatedBy: "\r\n").first else {
            send(status: "400 Bad Request", route: nil, includeBody: false, on: connection)
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              parts[0] == "GET" || parts[0] == "HEAD",
              let components = URLComponents(string: String(parts[1])) else {
            send(status: "400 Bad Request", route: nil, includeBody: false, on: connection)
            return
        }
        guard let route = routes[components.path] else {
            send(status: "404 Not Found", route: nil, includeBody: false, on: connection)
            return
        }
        send(status: "200 OK", route: route, includeBody: parts[0] == "GET", on: connection)
    }

    private func send(
        status: String,
        route: Route?,
        includeBody: Bool,
        on connection: NWConnection
    ) {
        let body = route?.content ?? Data()
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: \(route?.contentType ?? "text/plain")\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        if includeBody { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

struct SubtitleStudioTrack: Identifiable, Sendable {
    let source: SubtitleSource
    let cues: [SubtitleCue]

    var id: String { source.syncKey }
    var displayName: String { "\(source.providerName) · \(source.label)" }

    func text(at playbackTime: Double, offset: Double) -> String? {
        let sourceTime = playbackTime - offset
        return cues.first {
            $0.startTime <= sourceTime && sourceTime < $0.endTime
        }?.text
    }
}

struct SubtitleStudioContext: Identifiable, Sendable {
    let selectedTrackID: String
    let offset: Double
    let selectedVersionID: UUID?

    var id: String { selectedTrackID }
}

@MainActor
final class PlayerSession: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var availableQualities: [StreamQuality] = []
    @Published private(set) var selectedQuality: StreamQuality?
    @Published private(set) var subtitleTimingOffset: Double = 0
    @Published private(set) var canAdjustSubtitleTiming = false
    @Published private(set) var canOpenSubtitleStudio = false
    @Published private(set) var subtitleStudioTracks: [SubtitleStudioTrack] = []
    @Published private(set) var subtitleStudioPosition: Double = 0
    @Published private(set) var isSubtitleStudioSeeking = false
    @Published private(set) var playbackRate: Double = 1
    @Published private(set) var isBuffering = false
    @Published private(set) var playbackErrorMessage: String?

    var onEnded: (() -> Void)?
    var onSourceRefreshNeeded: (() async -> Bool)?
    nonisolated(unsafe) private var timeObserver: Any?
    nonisolated(unsafe) private var studioTimeObserver: Any?
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    nonisolated(unsafe) private var mediaSelectionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var playbackStalledObserver: NSObjectProtocol?
    nonisolated(unsafe) private var playbackErrorLogObserver: NSObjectProtocol?
    nonisolated(unsafe) private var failedToPlayToEndObserver: NSObjectProtocol?
    nonisolated(unsafe) private var audioInterruptionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var audioRouteChangeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var rateObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var defaultRateObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var timeControlStatusObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var playbackBufferEmptyObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var playbackLikelyToKeepUpObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var itemStatusObservation: NSKeyValueObservation?
    private var mediaOptionsTask: Task<Void, Never>?
    private var subtitleAdjustmentTask: Task<Void, Never>?
    private var qualitySwitchTask: Task<Void, Never>?
    private var nowPlayingArtworkTask: Task<Void, Never>?
    private var recoveryWatchdogTask: Task<Void, Never>?
    private var sourceRefreshTask: Task<Void, Never>?
    private var sourceExpirationTask: Task<Void, Never>?
    private var nowPlayingContentID: String?
    private var nowPlayingTitle: String?
    private var nowPlayingSubtitle: String?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []
    private var injectedSubtitleNames: Set<String> = []
    private var injectedSubtitleLanguageTags: Set<String> = []
    private var subtitleRenditions: [HLSSubtitleRendition] = []
    private var subtitleRenditionsByDisplayName: [String: HLSSubtitleRendition] = [:]
    private var subtitleRenditionsByLanguageTag: [String: HLSSubtitleRendition] = [:]
    private var subtitlePlaybackSource: PlaybackSource?
    private var subtitleSyncVersions: [SubtitleSyncVersion] = []
    private var studioPreviousSubtitleDisplayName: String?
    private var studioWasPlaying = false
    private var subtitleStudioSeekToken = UUID()
    private var appliedSubtitleTimingOffset: Double = 0
    private var primarySubtitleLanguage = ""
    private var secondarySubtitleLanguage = ""
    private var audioLanguage = "en"
    private var playbackWasRequested = false
    private var shouldResumeAfterBuffering = false
    private var isPreparingPlayback = false
    private var nextReplacementShouldPlay: Bool?
    private var currentSourceURL: URL?
    private var currentSourceExpiresAt: Date?
    private var sourceRefreshRequestedForURL: URL?
    private var needsSourceRefreshAfterBackground = false
    private var automaticSourceRefreshAttempts = 0
    private var recoveryBaselinePosition = 0.0
    private var lastObservedBufferEnd = 0.0
    private var stagnantBufferChecks = 0
    private var wasPlayingBeforeInterruption = false
    private var qualityPreferenceInitialized = false
    private var preferredQualityHeight: Int?
    private var automaticPeakBitRate: Double?
    private var currentPlaybackSource: PlaybackSource?
    private var currentExternalSubtitles: [SubtitleSource] = []
    private let playlistInspector = HLSPlaylistInspector()
    private let subtitleClient: any HTTPClientProtocol
    private let subtitleServer = HLSSubtitleLoopbackServer()
    private let audioSessionController = AudioSessionController()

    init(subtitleClient: any HTTPClientProtocol = HTTPClient()) {
        self.subtitleClient = subtitleClient
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        player.appliesMediaSelectionCriteriaAutomatically = false
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, change in
            guard let rate = change.newValue, rate > 0 else { return }
            Task { @MainActor [weak self] in self?.recordPlaybackRate(rate) }
        }
        defaultRateObservation = player.observe(\.defaultRate, options: [.new]) { [weak self] _, change in
            guard let rate = change.newValue, rate > 0 else { return }
            Task { @MainActor [weak self] in self?.recordPlaybackRate(rate) }
        }
        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshPlaybackState() }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                let value = self.player.currentItem?.duration.seconds ?? 0
                self.duration = value.isFinite ? value : 0
                self.recordPlaybackRate(self.player.rate > 0 ? self.player.rate : self.player.defaultRate)
                if self.automaticSourceRefreshAttempts > 0,
                   self.player.timeControlStatus == .playing,
                   self.position >= self.recoveryBaselinePosition + 5 {
                    self.automaticSourceRefreshAttempts = 0
                    self.playbackErrorMessage = nil
                }
                self.publishNowPlayingInfo()
            }
        }
        observeAudioSessionEvents()
    }

    deinit {
        mediaOptionsTask?.cancel()
        subtitleAdjustmentTask?.cancel()
        qualitySwitchTask?.cancel()
        nowPlayingArtworkTask?.cancel()
        recoveryWatchdogTask?.cancel()
        sourceRefreshTask?.cancel()
        sourceExpirationTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let studioTimeObserver { player.removeTimeObserver(studioTimeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let mediaSelectionObserver { NotificationCenter.default.removeObserver(mediaSelectionObserver) }
        if let playbackStalledObserver { NotificationCenter.default.removeObserver(playbackStalledObserver) }
        if let playbackErrorLogObserver { NotificationCenter.default.removeObserver(playbackErrorLogObserver) }
        if let failedToPlayToEndObserver { NotificationCenter.default.removeObserver(failedToPlayToEndObserver) }
        if let audioInterruptionObserver { NotificationCenter.default.removeObserver(audioInterruptionObserver) }
        if let audioRouteChangeObserver { NotificationCenter.default.removeObserver(audioRouteChangeObserver) }
    }

    func load(
        request playbackRequest: PlaybackRequest,
        source: PlaybackSource,
        resumeAt: Double,
        primarySubtitleLanguage: String,
        secondarySubtitleLanguage: String,
        audioLanguage: String,
        externalSubtitles: [SubtitleSource],
        subtitleSyncVersions: [SubtitleSyncVersion],
        automaticallySelectLatestSubtitleSync: Bool,
        defaultQualityHeight: Int,
        defaultPlaybackRate: Float
    ) async {
        // Recovery may replace an item while the user is intentionally paused.
        // Consume the intent before asynchronous subtitle preparation so the
        // replacement cannot unexpectedly start itself later.
        let shouldPlay = nextReplacementShouldPlay ?? true
        nextReplacementShouldPlay = nil
        recoveryWatchdogTask?.cancel()
        qualitySwitchTask?.cancel()
        isBuffering = shouldPlay
        playbackErrorMessage = nil
        await audioSessionController.activateForPlayback()
        guard !Task.isCancelled else { return }
        configureNowPlaying(for: playbackRequest)
        mediaOptionsTask?.cancel()
        subtitleAdjustmentTask?.cancel()
        removeInjectedSubtitleAsset()
        subtitleTimingOffset = 0
        appliedSubtitleTimingOffset = 0
        self.subtitleSyncVersions = subtitleSyncVersions
        let preparedSource = source.preferredForSubtitleLanguage(primarySubtitleLanguage)
        let qualities = await playlistInspector.availableQualities(for: preparedSource)
        guard !Task.isCancelled else { return }
        availableQualities = qualities
        if !qualityPreferenceInitialized {
            preferredQualityHeight = defaultQualityHeight > 0 ? defaultQualityHeight : nil
            qualityPreferenceInitialized = true
        }
        selectedQuality = preferredQualityHeight.flatMap {
            StreamQuality.closest(to: $0, in: qualities)
        }
        let asset = await assetByInjectingSubtitles(
            externalSubtitles,
            into: preparedSource,
            selectedQuality: selectedQuality
        )
        guard !Task.isCancelled else { return }
        automaticPeakBitRate = source.preferredPeakBitRate
        currentPlaybackSource = preparedSource
        currentExternalSubtitles = externalSubtitles
        sourceRefreshRequestedForURL = nil
        currentSourceURL = source.url
        currentSourceExpiresAt = Self.expirationDate(in: source.url)
        needsSourceRefreshAfterBackground = false
        self.primarySubtitleLanguage = primarySubtitleLanguage
        self.secondarySubtitleLanguage = secondarySubtitleLanguage
        self.audioLanguage = audioLanguage
        player.defaultRate = defaultPlaybackRate
        playbackRate = Double(defaultPlaybackRate)
        let preferredSyncVersionID = automaticallySelectLatestSubtitleSync
            ? subtitleSyncVersions
                .sorted { $0.createdAt > $1.createdAt }
                .compactMap { version in
                    languageTag(forSyncVersionID: version.id).map { (version.id, $0) }
                }
                .first
            : nil
        replaceCurrentItem(
            with: asset,
            resumeAt: resumeAt,
            shouldPlay: shouldPlay,
            playbackRate: defaultPlaybackRate,
            preferredSubtitleLanguageTag: preferredSyncVersionID?.1
        )
        schedulePausedSourceRefreshBeforeExpiration()
    }

    func stop() {
        subtitleAdjustmentTask?.cancel()
        qualitySwitchTask?.cancel()
        nowPlayingArtworkTask?.cancel()
        recoveryWatchdogTask?.cancel()
        sourceRefreshTask?.cancel()
        sourceExpirationTask?.cancel()
        playbackWasRequested = false
        shouldResumeAfterBuffering = false
        isPreparingPlayback = false
        nextReplacementShouldPlay = nil
        currentSourceURL = nil
        currentPlaybackSource = nil
        currentExternalSubtitles = []
        subtitleSyncVersions = []
        subtitleStudioTracks = []
        isSubtitleStudioSeeking = false
        currentSourceExpiresAt = nil
        sourceRefreshRequestedForURL = nil
        needsSourceRefreshAfterBackground = false
        automaticSourceRefreshAttempts = 0
        playbackErrorMessage = nil
        player.pause()
        removeStudioTimeObserver()
        isBuffering = false
        removeInjectedSubtitleAsset()
        clearNowPlaying()
        removeRemoteCommands()
        Task { [audioSessionController] in
            await audioSessionController.deactivate()
        }
    }

    func resetProgressTracking() {
        position = 0
        duration = 0
        automaticSourceRefreshAttempts = 0
        recoveryBaselinePosition = 0
        playbackErrorMessage = nil
    }

    func prepareForForegroundResume() {
        Task { [audioSessionController] in
            await audioSessionController.activateForPlayback()
        }
        guard player.currentItem != nil,
              player.timeControlStatus == .paused else { return }
        // iOS can leave a paused HLS item attached after suspending its network
        // requests. Recreate that item only when the user next asks it to play.
        needsSourceRefreshAfterBackground = true
        sourceRefreshRequestedForURL = nil
    }

    func prepareForBackground() {
        guard player.timeControlStatus == .paused else { return }
        Task { [audioSessionController] in
            await audioSessionController.deactivate()
        }
    }

    func retryPlayback() {
        guard currentSourceURL != nil else { return }
        playbackErrorMessage = nil
        automaticSourceRefreshAttempts = 0
        sourceRefreshRequestedForURL = nil
        playbackWasRequested = true
        shouldResumeAfterBuffering = true
        isBuffering = true
        requestSourceRefresh()
    }

    private func recordPlaybackRate(_ rate: Float) {
        guard rate.isFinite, rate > 0 else { return }
        // Video content is dominated by dialogue. The time-domain processor
        // preserves pitch with substantially less work than the default
        // spectral processor, preventing its audio queue from falling behind
        // the shared player clock during sustained accelerated playback.
        player.currentItem?.audioTimePitchAlgorithm = .timeDomain
        let value = Double(rate)
        guard abs(playbackRate - value) > 0.001 else { return }
        playbackRate = value
    }

    func setQuality(_ quality: StreamQuality?) {
        guard selectedQuality != quality else { return }
        preferredQualityHeight = quality?.height
        qualityPreferenceInitialized = true
        selectedQuality = quality
        guard let source = currentPlaybackSource,
              player.currentItem != nil else { return }

        qualitySwitchTask?.cancel()
        let requestedQuality = quality
        let externalSubtitles = currentExternalSubtitles
        let resumeAt = player.currentTime().seconds.isFinite
            ? player.currentTime().seconds
            : position
        let shouldPlay = playbackWasRequested || player.timeControlStatus != .paused
        let rate = player.rate > 0 ? player.rate : player.defaultRate
        isBuffering = true

        qualitySwitchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let preferredSubtitleDisplayName = await self.selectedSubtitleDisplayName()
            let preferredSubtitleLanguageTag = await self.selectedSubtitleLanguageTag()
            let asset = await self.assetByInjectingSubtitles(
                externalSubtitles,
                into: source,
                selectedQuality: requestedQuality
            )
            guard !Task.isCancelled,
                  self.selectedQuality == requestedQuality else { return }
            self.replaceCurrentItem(
                with: asset,
                resumeAt: resumeAt,
                shouldPlay: shouldPlay,
                playbackRate: rate,
                preferredSubtitleDisplayName: preferredSubtitleDisplayName,
                preferredSubtitleLanguageTag: preferredSubtitleLanguageTag
            )
            self.qualitySwitchTask = nil
            if !shouldPlay { self.isBuffering = false }
        }
    }

    func adjustSubtitleTiming(by delta: Double) {
        guard canAdjustSubtitleTiming,
              let source = subtitlePlaybackSource,
              !subtitleRenditions.isEmpty else { return }
        let updatedOffset = min(
            10,
            max(-10, ((subtitleTimingOffset + delta) * 10).rounded() / 10)
        )
        guard updatedOffset != subtitleTimingOffset else { return }
        subtitleTimingOffset = updatedOffset
        subtitleAdjustmentTask?.cancel()
        let renditions = subtitleRenditions
        subtitleAdjustmentTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                guard let self else { return }
                let injectedAsset = try await HLSSubtitleInjector.prepare(
                    source: source,
                    renditions: renditions,
                    timingOffset: updatedOffset,
                    selectedQualityHeight: selectedQuality?.height,
                    client: self.subtitleClient
                )
                try Task.checkCancellation()
                let selectedSubtitleName = await self.selectedSubtitleDisplayName()
                let selectedSubtitleLanguageTag = await self.selectedSubtitleLanguageTag()
                let localMasterURL = try await self.subtitleServer.publish(injectedAsset)
                let currentTime = self.player.currentTime().seconds
                let resumeAt = currentTime.isFinite ? currentTime : self.position
                let wasPlaying = self.player.timeControlStatus != .paused
                let playbackRate = self.player.rate > 0
                    ? self.player.rate
                    : self.player.defaultRate
                self.injectedSubtitleNames = injectedAsset.displayNames
                self.injectedSubtitleLanguageTags = injectedAsset.languageTags
                self.appliedSubtitleTimingOffset = updatedOffset
                self.replaceCurrentItem(
                    with: AVURLAsset(
                        url: localMasterURL,
                        options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers]
                    ),
                    resumeAt: resumeAt,
                    shouldPlay: wasPlaying,
                    playbackRate: playbackRate,
                    preferredSubtitleDisplayName: selectedSubtitleName,
                    preferredSubtitleLanguageTag: selectedSubtitleLanguageTag
                )
            } catch where error.isCancellation { }
            catch {
                guard let self else { return }
                self.subtitleTimingOffset = self.appliedSubtitleTimingOffset
            }
        }
    }

    func beginSubtitleStudio() async -> SubtitleStudioContext? {
        guard !subtitleStudioTracks.isEmpty else { return nil }
        isSubtitleStudioSeeking = false
        studioWasPlaying = player.timeControlStatus != .paused
        subtitleStudioPosition = player.currentTime().seconds.isFinite
            ? player.currentTime().seconds
            : position
        installStudioTimeObserver()
        studioPreviousSubtitleDisplayName = await selectedSubtitleDisplayName()
        let selectedLanguageTag = await selectedSubtitleLanguageTag()
        let selectedRendition = selectedLanguageTag.flatMap {
            subtitleRenditionsByLanguageTag[$0]
        } ?? studioPreviousSubtitleDisplayName.flatMap {
            subtitleRenditionsByDisplayName[$0]
        }
        let selectedEmbeddedTrack = studioPreviousSubtitleDisplayName.flatMap { displayName in
            subtitleStudioTracks.first {
                $0.source.providerID == "native-hls" &&
                    ($0.source.label.localizedCaseInsensitiveCompare(displayName) == .orderedSame ||
                     $0.source.label.replacingOccurrences(of: " (Forced)", with: "")
                        .localizedCaseInsensitiveCompare(displayName) == .orderedSame)
            }
        }
        let selectedTrackID = selectedRendition?.subtitle.syncKey
            ?? selectedEmbeddedTrack?.id
            ?? subtitleStudioTracks.first?.id
        guard let selectedTrackID else { return nil }
        player.pause()
        if let item = player.currentItem,
           let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
           player.currentItem === item {
            item.select(nil, in: group)
        }
        return SubtitleStudioContext(
            selectedTrackID: selectedTrackID,
            offset: selectedRendition?.timingOffset ?? 0,
            selectedVersionID: selectedRendition?.syncVersionID
        )
    }

    func cancelSubtitleStudio() async {
        isSubtitleStudioSeeking = false
        await selectSubtitle(displayName: studioPreviousSubtitleDisplayName)
        if studioWasPlaying { player.play() }
        removeStudioTimeObserver()
        studioPreviousSubtitleDisplayName = nil
    }

    func applySubtitleSyncVersions(
        _ versions: [SubtitleSyncVersion],
        selecting versionID: UUID
    ) async {
        guard let source = subtitlePlaybackSource else {
            await cancelSubtitleStudio()
            return
        }
        subtitleSyncVersions = versions
        let resumeAt = player.currentTime().seconds.isFinite
            ? player.currentTime().seconds
            : position
        isBuffering = true
        let asset = await assetByInjectingSubtitles(
            currentExternalSubtitles,
            into: source,
            selectedQuality: selectedQuality
        )
        guard !Task.isCancelled else { return }
        replaceCurrentItem(
            with: asset,
            resumeAt: resumeAt,
            shouldPlay: studioWasPlaying,
            playbackRate: player.defaultRate,
            preferredSubtitleLanguageTag: languageTag(forSyncVersionID: versionID)
        )
        isSubtitleStudioSeeking = false
        removeStudioTimeObserver()
        studioPreviousSubtitleDisplayName = nil
    }

    func seek(to seconds: Double) {
        let safeDuration = duration.isFinite ? duration : 0
        let target = min(max(seconds, 0), max(safeDuration, 0))
        let token = UUID()
        subtitleStudioSeekToken = token
        isSubtitleStudioSeeking = true
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.subtitleStudioSeekToken == token else { return }
                self.isSubtitleStudioSeeking = false
            }
        }
        subtitleStudioPosition = target
    }

    func toggleStudioPlayback() {
        if player.timeControlStatus == .paused {
            player.play()
        } else {
            player.pause()
        }
    }

    private func installStudioTimeObserver() {
        removeStudioTimeObserver()
        studioTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 10),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.subtitleStudioPosition = time.seconds.isFinite ? time.seconds : 0
            }
        }
    }

    private func removeStudioTimeObserver() {
        guard let studioTimeObserver else { return }
        player.removeTimeObserver(studioTimeObserver)
        self.studioTimeObserver = nil
    }

    private func assetByInjectingSubtitles(
        _ subtitles: [SubtitleSource],
        into source: PlaybackSource,
        selectedQuality: StreamQuality?
    ) async -> AVURLAsset {
        let originalAsset = AVURLAsset(
            url: source.url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers]
        )
        var seenResources: Set<String> = []
        let uniqueSubtitles = subtitles.filter {
            seenResources.insert("\($0.providerID):\($0.url.absoluteString)").inserted
        }
        async let downloadedRenditions = loadSubtitleRenditions(uniqueSubtitles)
        async let embeddedRenditions = HLSNativeSubtitleLoader.load(
            from: source,
            client: subtitleClient
        )
        let loadedRenditions = await downloadedRenditions + embeddedRenditions
        guard !Task.isCancelled else { return originalAsset }
        subtitleStudioTracks = loadedRenditions.map {
            SubtitleStudioTrack(source: $0.subtitle, cues: $0.cues)
        }
        canOpenSubtitleStudio = !subtitleStudioTracks.isEmpty
        let renditions = expandedSubtitleRenditions(from: loadedRenditions)
        guard !renditions.isEmpty || selectedQuality != nil else { return originalAsset }

        do {
            let injectedAsset = try await HLSSubtitleInjector.prepare(
                source: source,
                renditions: renditions,
                selectedQualityHeight: selectedQuality?.height,
                client: subtitleClient
            )
            try Task.checkCancellation()
            let localMasterURL = try await subtitleServer.publish(injectedAsset)
            try Task.checkCancellation()
            injectedSubtitleNames = injectedAsset.displayNames
            injectedSubtitleLanguageTags = injectedAsset.languageTags
            subtitleRenditions = renditions
            subtitleRenditionsByDisplayName = Dictionary(
                uniqueKeysWithValues: zip(injectedAsset.orderedDisplayNames, renditions)
            )
            subtitleRenditionsByLanguageTag = Dictionary(
                uniqueKeysWithValues: zip(injectedAsset.orderedLanguageTags, renditions)
            )
            subtitlePlaybackSource = renditions.isEmpty ? nil : source
            return AVURLAsset(
                url: localMasterURL,
                options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers]
            )
        } catch where error.isCancellation {
            return originalAsset
        } catch {
            injectedSubtitleNames = []
            injectedSubtitleLanguageTags = []
            subtitleRenditions = []
            subtitleRenditionsByDisplayName = [:]
            subtitleRenditionsByLanguageTag = [:]
            subtitleStudioTracks = []
            canOpenSubtitleStudio = false
            subtitlePlaybackSource = nil
            canAdjustSubtitleTiming = false
            subtitleServer.clear()
            return originalAsset
        }
    }

    private func expandedSubtitleRenditions(
        from baseRenditions: [HLSSubtitleRendition]
    ) -> [HLSSubtitleRendition] {
        baseRenditions.flatMap { rendition in
            let saved = subtitleSyncVersions
                .filter { $0.subtitleKey == rendition.subtitle.syncKey }
                .sorted { $0.createdAt < $1.createdAt }
                .enumerated()
                .map { index, version in
                    HLSSubtitleRendition(
                        subtitle: rendition.subtitle,
                        cues: rendition.cues,
                        timingOffset: version.offset,
                        syncVersionID: version.id,
                        displayNameOverride: syncedDisplayName(
                            for: rendition.subtitle,
                            versionNumber: index + 1
                        )
                    )
                }
            return [rendition] + saved
        }
    }

    private func syncedDisplayName(for subtitle: SubtitleSource, versionNumber: Int) -> String {
        let language = subtitle.languageCode.flatMap {
            Locale.current.localizedString(forLanguageCode: $0)
        } ?? subtitle.label
        let version = "\(language) (Resynced \(versionNumber))"
        guard subtitle.providerID != "native-hls" else { return version }
        return "\(version) - \(subtitle.providerName) - \(subtitle.label)"
    }

    private func languageTag(forSyncVersionID id: UUID) -> String? {
        subtitleRenditionsByLanguageTag.first { $0.value.syncVersionID == id }?.key
    }

    private func selectSubtitle(displayName: String?) async {
        guard let item = player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
              player.currentItem === item else { return }
        let option = displayName.flatMap { name in
            group.options.first { $0.displayName == name }
        }
        item.select(option, in: group)
    }

    private func loadSubtitleRenditions(
        _ subtitles: [SubtitleSource]
    ) async -> [HLSSubtitleRendition] {
        let client = subtitleClient
        var loaded: [(Int, HLSSubtitleRendition)] = []
        let maximumConcurrentDownloads = 6

        for start in stride(from: 0, to: subtitles.count, by: maximumConcurrentDownloads) {
            guard !Task.isCancelled else { return [] }
            let end = min(start + maximumConcurrentDownloads, subtitles.count)
            let batch = Array(subtitles[start..<end].enumerated()).map { offset, subtitle in
                (start + offset, subtitle)
            }
            let batchResults = await withTaskGroup(
                of: (Int, HLSSubtitleRendition?).self,
                returning: [(Int, HLSSubtitleRendition)].self
            ) { group in
                for (index, subtitle) in batch {
                    group.addTask {
                        do {
                            var request = URLRequest(url: subtitle.url)
                            request.setValue(
                                "text/plain,text/vtt,application/x-subrip,*/*;q=0.8",
                                forHTTPHeaderField: "Accept"
                            )
                            request.setValue(
                                HTTPClient.desktopUserAgent,
                                forHTTPHeaderField: "User-Agent"
                            )
                            let response = try await SubtitleResourceRetry.load(
                                request: request,
                                client: client
                            )
                            try Task.checkCancellation()
                            let parsedCues = try SubtitleParser.cues(from: response.data)
                            let cues = SubtitleDirectionFormatter.normalizedCues(
                                parsedCues,
                                languageCode: subtitle.languageCode
                            )
                            return (index, HLSSubtitleRendition(subtitle: subtitle, cues: cues))
                        } catch {
                            return (index, nil)
                        }
                    }
                }
                var results: [(Int, HLSSubtitleRendition)] = []
                for await (index, rendition) in group {
                    if let rendition { results.append((index, rendition)) }
                }
                return results
            }
            loaded.append(contentsOf: batchResults)
        }
        return loaded.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func replaceCurrentItem(
        with asset: AVURLAsset,
        resumeAt: Double,
        shouldPlay: Bool,
        playbackRate: Float,
        preferredSubtitleDisplayName: String? = nil,
        preferredSubtitleLanguageTag: String? = nil
    ) {
        mediaOptionsTask?.cancel()
        playbackWasRequested = shouldPlay
        shouldResumeAfterBuffering = false
        isPreparingPlayback = shouldPlay && resumeAt > 0
        if isPreparingPlayback { isBuffering = true }
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        applyQuality(to: item)
        observeBufferingState(
            of: item,
            preferredSubtitleDisplayName: preferredSubtitleDisplayName,
            preferredSubtitleLanguageTag: preferredSubtitleLanguageTag
        )
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let mediaSelectionObserver { NotificationCenter.default.removeObserver(mediaSelectionObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnded?() }
        }
        mediaSelectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item else { return }
                self.refreshSubtitleTimingAvailability(for: item)
            }
        }
        player.replaceCurrentItem(with: item)
        player.defaultRate = playbackRate
        if resumeAt > 0 {
            item.seek(
                to: CMTime(seconds: resumeAt, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero,
                completionHandler: { [weak self, weak item] finished in
                    Task { @MainActor [weak self, weak item] in
                        guard let self, let item,
                              self.player.currentItem === item else { return }
                        self.isPreparingPlayback = false
                        guard finished, shouldPlay else {
                            self.refreshPlaybackState()
                            return
                        }
                        // `play()` deliberately uses `defaultRate`, retaining
                        // AVPlayer's automatic wait-for-buffer behavior.
                        self.player.play()
                    }
                }
            )
        } else if shouldPlay {
            player.play()
        }
        mediaOptionsTask = Task { [weak self] in
            guard let self else { return }
            await self.applyPreferredLanguages(
                to: asset,
                primarySubtitleLanguage: self.primarySubtitleLanguage,
                secondarySubtitleLanguage: self.secondarySubtitleLanguage,
                audioLanguage: self.audioLanguage,
                preferredSubtitleDisplayName: preferredSubtitleDisplayName,
                preferredSubtitleLanguageTag: preferredSubtitleLanguageTag
            )
        }
    }

    private func observeBufferingState(
        of item: AVPlayerItem,
        preferredSubtitleDisplayName: String?,
        preferredSubtitleLanguageTag: String?
    ) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) {
            [weak self, weak item] _, change in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                switch change.newValue {
                case .readyToPlay:
                    self.reapplyPreferredLanguagesIfNeeded(
                        to: item,
                        preferredSubtitleDisplayName: preferredSubtitleDisplayName,
                        preferredSubtitleLanguageTag: preferredSubtitleLanguageTag
                    )
                case .failed:
                    self.handleItemFailure()
                default:
                    break
                }
            }
        }
        playbackBufferEmptyObservation = item.observe(
            \.isPlaybackBufferEmpty,
            options: [.initial, .new]
        ) { [weak self, weak item] _, change in
            guard change.newValue == true else { return }
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                guard self.playbackWasRequested
                        || self.player.timeControlStatus != .paused else { return }
                self.beginAutomaticBufferRecovery()
            }
        }
        playbackLikelyToKeepUpObservation = item.observe(
            \.isPlaybackLikelyToKeepUp,
            options: [.initial, .new]
        ) { [weak self, weak item] _, change in
            guard change.newValue == true else { return }
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                self.resumeWhenBufferIsReady()
            }
        }

        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
        }
        playbackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item else { return }
                self.beginAutomaticBufferRecovery()
            }
        }
        if let playbackErrorLogObserver {
            NotificationCenter.default.removeObserver(playbackErrorLogObserver)
        }
        playbackErrorLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item,
                      let statusCode = item.errorLog()?.events.last?.errorStatusCode,
                      statusCode >= 400 else { return }
                self.handleItemFailure()
            }
        }
        if let failedToPlayToEndObserver {
            NotificationCenter.default.removeObserver(failedToPlayToEndObserver)
        }
        failedToPlayToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item else { return }
                self.handleItemFailure()
            }
        }
    }

    private func refreshPlaybackState() {
        switch player.timeControlStatus {
        case .playing:
            playbackWasRequested = true
            shouldResumeAfterBuffering = false
            needsSourceRefreshAfterBackground = false
            isBuffering = false
            stagnantBufferChecks = 0
            recoveryWatchdogTask?.cancel()
            recoveryWatchdogTask = nil
        case .waitingToPlayAtSpecifiedRate:
            playbackWasRequested = true
            if needsSourceRefreshAfterBackground {
                requestSourceRefresh()
            } else {
                refreshSourceIfExpired()
            }
            scheduleRecoveryWatchdogIfNeeded()
        case .paused:
            if isPreparingPlayback {
                playbackWasRequested = true
                isBuffering = true
                publishNowPlayingInfo()
                return
            }
            playbackWasRequested = false
            shouldResumeAfterBuffering = false
            isBuffering = false
            recoveryWatchdogTask?.cancel()
            recoveryWatchdogTask = nil
            if player.currentItem?.status == .failed || sourceIsExpiredOrExpiringSoon {
                requestSourceRefresh()
            }
        @unknown default:
            break
        }
        isBuffering = shouldResumeAfterBuffering
            || isPreparingPlayback
            || (playbackWasRequested
                && player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        publishNowPlayingInfo()
    }

    private func beginAutomaticBufferRecovery() {
        playbackWasRequested = true
        shouldResumeAfterBuffering = true
        isBuffering = true
        publishNowPlayingInfo()
        // A stall can leave AVPlayer in .paused rather than .waiting. Calling
        // play again preserves the user's play intent and keeps media loading.
        player.play()
        if needsSourceRefreshAfterBackground {
            requestSourceRefresh()
        } else {
            refreshSourceIfExpired()
        }
        scheduleRecoveryWatchdogIfNeeded()
    }

    private func resumeWhenBufferIsReady() {
        guard playbackWasRequested || shouldResumeAfterBuffering else { return }
        player.play()
    }

    private func refreshSourceIfExpired() {
        guard sourceIsExpiredOrExpiringSoon else { return }
        requestSourceRefresh()
    }

    private var sourceIsExpiredOrExpiringSoon: Bool {
        currentSourceExpiresAt.map { $0 <= Date().addingTimeInterval(30) } ?? false
    }

    private func schedulePausedSourceRefreshBeforeExpiration() {
        sourceExpirationTask?.cancel()
        guard let currentSourceURL, let currentSourceExpiresAt else { return }
        let delay = max(0, currentSourceExpiresAt.timeIntervalSinceNow - 30)
        sourceExpirationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self,
                  self.currentSourceURL == currentSourceURL,
                  self.currentSourceExpiresAt == currentSourceExpiresAt,
                  self.player.timeControlStatus == .paused,
                  !self.playbackWasRequested,
                  !self.isPreparingPlayback else { return }
            self.requestSourceRefresh()
        }
    }

    private func requestSourceRefresh() {
        guard let currentSourceURL,
              sourceRefreshRequestedForURL != currentSourceURL,
              sourceRefreshTask == nil else { return }
        guard automaticSourceRefreshAttempts < PlaybackRecoveryPolicy.maximumSourceRefreshes else {
            failPlaybackRecovery()
            return
        }
        guard let onSourceRefreshNeeded else {
            failPlaybackRecovery()
            return
        }
        sourceRefreshRequestedForURL = currentSourceURL
        nextReplacementShouldPlay = playbackWasRequested || shouldResumeAfterBuffering
        automaticSourceRefreshAttempts += 1
        recoveryBaselinePosition = position
        recoveryWatchdogTask?.cancel()
        recoveryWatchdogTask = nil
        isBuffering = nextReplacementShouldPlay == true
        sourceRefreshTask = Task { @MainActor [weak self] in
            let succeeded = await onSourceRefreshNeeded()
            guard let self, !Task.isCancelled else { return }
            self.sourceRefreshTask = nil
            if !succeeded {
                self.sourceRefreshRequestedForURL = nil
                self.failPlaybackRecovery()
            }
        }
    }

    private func handleItemFailure() {
        // A signed HLS item can fail while paused. AVPlayer does not publish the
        // same status transition again when its system Play button is pressed,
        // leaving the crossed-out play icon stuck unless we replace the item.
        let shouldContinuePlaying = playbackWasRequested || shouldResumeAfterBuffering
        isPreparingPlayback = false
        shouldResumeAfterBuffering = shouldContinuePlaying
        isBuffering = shouldContinuePlaying
        requestSourceRefresh()
    }

    private func scheduleRecoveryWatchdogIfNeeded() {
        guard recoveryWatchdogTask == nil,
              playbackWasRequested,
              player.currentItem != nil else { return }
        lastObservedBufferEnd = bufferedEndTime()
        stagnantBufferChecks = 0
        recoveryWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: PlaybackRecoveryPolicy.watchdogInterval)
                } catch {
                    return
                }
                guard let self,
                      self.playbackWasRequested,
                      (self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                        || self.shouldResumeAfterBuffering) else { return }

                let bufferedEnd = self.bufferedEndTime()
                if bufferedEnd >= self.lastObservedBufferEnd + PlaybackRecoveryPolicy.minimumBufferGrowth {
                    self.lastObservedBufferEnd = bufferedEnd
                    self.stagnantBufferChecks = 0
                    continue
                }

                self.stagnantBufferChecks += 1
                switch PlaybackRecoveryPolicy.action(
                    stagnantChecks: self.stagnantBufferChecks,
                    sourceRefreshAttempts: self.automaticSourceRefreshAttempts
                ) {
                case .retryPlay:
                    self.player.play()
                case .refreshSource:
                    self.recoveryWatchdogTask = nil
                    self.requestSourceRefresh()
                    return
                case .fail:
                    self.recoveryWatchdogTask = nil
                    self.failPlaybackRecovery()
                    return
                case .keepWaiting:
                    break
                }
            }
        }
    }

    private func bufferedEndTime() -> Double {
        guard let item = player.currentItem else { return 0 }
        return item.loadedTimeRanges.reduce(0) { result, value in
            let range = value.timeRangeValue
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            return end.isFinite ? max(result, end) : result
        }
    }

    private func failPlaybackRecovery() {
        recoveryWatchdogTask?.cancel()
        recoveryWatchdogTask = nil
        sourceRefreshTask?.cancel()
        sourceRefreshTask = nil
        shouldResumeAfterBuffering = false
        isPreparingPlayback = false
        playbackWasRequested = false
        isBuffering = false
        player.pause()
        playbackErrorMessage = "The video stream stopped responding. Check your connection and try again."
        publishNowPlayingInfo()
    }

    private static func expirationDate(in url: URL) -> Date? {
        guard let value = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems?.first(where: { $0.name == "expires" })?.value,
        let timestamp = TimeInterval(value) else { return nil }
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp
        return Date(timeIntervalSince1970: seconds)
    }

    private func observeAudioSessionEvents() {
        let audioSession = AVAudioSession.sharedInstance()
        audioInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else {
                return
            }
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(typeRawValue: rawType, optionsRawValue: rawOptions)
            }
        }
        audioRouteChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else {
                return
            }
            Task { @MainActor [weak self] in
                self?.handleAudioRouteChange(reasonRawValue: rawReason)
            }
        }
    }

    private func handleAudioInterruption(typeRawValue: UInt, optionsRawValue: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeRawValue) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = playbackWasRequested
                && player.timeControlStatus != .paused
            recoveryWatchdogTask?.cancel()
            recoveryWatchdogTask = nil
            isBuffering = false
            Task { [audioSessionController] in
                await audioSessionController.markInactive()
            }
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRawValue)
            guard wasPlayingBeforeInterruption, options.contains(.shouldResume) else {
                wasPlayingBeforeInterruption = false
                return
            }
            wasPlayingBeforeInterruption = false
            playbackWasRequested = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.audioSessionController.activateForPlayback()
                self.player.play()
            }
        @unknown default:
            break
        }
    }

    private func handleAudioRouteChange(reasonRawValue: UInt) {
        guard AVAudioSession.RouteChangeReason(rawValue: reasonRawValue) == .oldDeviceUnavailable else {
            return
        }
        player.pause()
        playbackWasRequested = false
        shouldResumeAfterBuffering = false
        isBuffering = false
        recoveryWatchdogTask?.cancel()
        recoveryWatchdogTask = nil
        publishNowPlayingInfo()
    }

    private func applyPreferredLanguages(
        to asset: AVAsset,
        primarySubtitleLanguage: String,
        secondarySubtitleLanguage: String,
        audioLanguage: String,
        preferredSubtitleDisplayName: String? = nil,
        preferredSubtitleLanguageTag: String? = nil
    ) async {
        let subtitleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
        guard !Task.isCancelled else { return }
        let audioGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
        guard !Task.isCancelled, player.currentItem?.asset === asset else { return }

        var embeddedSubtitle: AVMediaSelectionOption?
        if let subtitleGroup {
            embeddedSubtitle = preferredSubtitleLanguageTag.flatMap { preferredTag in
                subtitleGroup.options.first {
                    normalizedLanguageValue($0.extendedLanguageTag ?? "") ==
                        normalizedLanguageValue(preferredTag)
                }
            } ?? preferredSubtitleDisplayName.flatMap { preferredName in
                subtitleGroup.options.first { $0.displayName == preferredName }
            }
            var nativeOptions: [AVMediaSelectionOption] = []
            var injectedOptions: [AVMediaSelectionOption] = []
            for option in subtitleGroup.options {
                if await isInjectedSubtitleOption(option) {
                    injectedOptions.append(option)
                } else {
                    nativeOptions.append(option)
                }
            }
            embeddedSubtitle = embeddedSubtitle ?? preferredOption(
                in: nativeOptions,
                languageCodes: [primarySubtitleLanguage]
            ) ?? preferredOption(
                in: injectedOptions,
                languageCodes: [primarySubtitleLanguage]
            ) ?? preferredOption(
                in: nativeOptions,
                languageCodes: [secondarySubtitleLanguage]
            ) ?? preferredOption(
                in: injectedOptions,
                languageCodes: [secondarySubtitleLanguage]
            )
        }
        if let subtitleGroup {
            player.currentItem?.select(embeddedSubtitle, in: subtitleGroup)
            canAdjustSubtitleTiming = embeddedSubtitle.map {
                isInjectedSubtitleLanguageTag($0.extendedLanguageTag) ||
                    injectedSubtitleNames.contains($0.displayName)
            } ?? false
        } else {
            canAdjustSubtitleTiming = false
        }
        if let audioGroup {
            let audio = preferredOption(in: audioGroup.options, languageCodes: [audioLanguage, "en"])
            if let audio { player.currentItem?.select(audio, in: audioGroup) }
        }
    }

    private func reapplyPreferredLanguagesIfNeeded(
        to item: AVPlayerItem,
        preferredSubtitleDisplayName: String?,
        preferredSubtitleLanguageTag: String?
    ) {
        mediaOptionsTask?.cancel()
        mediaOptionsTask = Task { [weak self, weak item] in
            guard let self, let item, self.player.currentItem === item else { return }
            await self.applyPreferredLanguages(
                to: item.asset,
                primarySubtitleLanguage: self.primarySubtitleLanguage,
                secondarySubtitleLanguage: self.secondarySubtitleLanguage,
                audioLanguage: self.audioLanguage,
                preferredSubtitleDisplayName: preferredSubtitleDisplayName,
                preferredSubtitleLanguageTag: preferredSubtitleLanguageTag
            )
        }
    }

    private func selectedSubtitleDisplayName() async -> String? {
        guard let item = player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
              player.currentItem === item else { return nil }
        return item.currentMediaSelection.selectedMediaOption(in: group)?.displayName
    }

    private func selectedSubtitleLanguageTag() async -> String? {
        guard let item = player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
              player.currentItem === item else { return nil }
        return item.currentMediaSelection.selectedMediaOption(in: group)?.extendedLanguageTag
    }

    private func refreshSubtitleTimingAvailability(for item: AVPlayerItem) {
        Task { [weak self, weak item] in
            guard let self, let item,
                  let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  self.player.currentItem === item else { return }
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            self.canAdjustSubtitleTiming = selected.map {
                self.isInjectedSubtitleLanguageTag($0.extendedLanguageTag) ||
                    self.injectedSubtitleNames.contains($0.displayName)
            } ?? false
        }
    }

    private func isInjectedSubtitleOption(_ option: AVMediaSelectionOption) async -> Bool {
        if isInjectedSubtitleLanguageTag(option.extendedLanguageTag) { return true }
        guard !injectedSubtitleNames.isEmpty else { return false }
        for item in option.commonMetadata where item.commonKey == .commonKeyTitle {
            if let title = try? await item.load(.stringValue),
               injectedSubtitleNames.contains(title) {
                return true
            }
        }
        return false
    }

    private func isInjectedSubtitleLanguageTag(_ languageTag: String?) -> Bool {
        guard let languageTag else { return false }
        let normalized = normalizedLanguageValue(languageTag)
        return injectedSubtitleLanguageTags.contains {
            normalizedLanguageValue($0) == normalized
        }
    }

    private func preferredOption(
        in options: [AVMediaSelectionOption],
        languageCodes: [String]
    ) -> AVMediaSelectionOption? {
        var matchingForcedOption: AVMediaSelectionOption?
        for code in languageCodes where !code.isEmpty {
            let identifiers = languageIdentifiers(for: code)
            let matches = options.filter { option in
                let tags = [option.extendedLanguageTag, option.locale?.identifier]
                    .compactMap { $0.map(normalizedLanguageValue) }
                let displayName = normalizedLanguageValue(option.displayName)
                return tags.contains { tag in
                    identifiers.contains(tag) || identifiers.contains(where: { tag.hasPrefix("\($0)-") })
                } || identifiers.contains(where: { displayName.contains($0) })
            }
            if let regular = matches.first(where: {
                !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
            }) {
                return regular
            }
            matchingForcedOption = matchingForcedOption ?? matches.first
        }
        return matchingForcedOption
    }

    private func languageIdentifiers(for code: String) -> Set<String> {
        var values = Set([normalizedLanguageValue(code)])
        if let alpha3 = Locale.LanguageCode(code).identifier(.alpha3) {
            values.insert(normalizedLanguageValue(alpha3))
        }
        for locale in [Locale.current, Locale(identifier: "en_US")] {
            if let name = locale.localizedString(forLanguageCode: code) {
                values.insert(normalizedLanguageValue(name))
            }
        }
        if code == "he" {
            values.formUnion(["iw", "heb"])
        } else if code == "en" {
            values.insert("eng")
        }
        return values
    }

    private func normalizedLanguageValue(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "(forced)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func configureNowPlaying(for request: PlaybackRequest) {
        configureRemoteCommandsIfNeeded()
        nowPlayingArtworkTask?.cancel()
        nowPlayingContentID = request.contentID
        nowPlayingTitle = request.nowPlayingTitle
        nowPlayingSubtitle = request.nowPlayingSubtitle
        nowPlayingArtwork = nil
        publishNowPlayingInfo()

        guard let posterURL = request.media.posterURL else { return }
        var posterRequest = URLRequest.providerRequest(url: posterURL)
        posterRequest.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let contentID = request.contentID
        let client = subtitleClient
        nowPlayingArtworkTask = Task { [weak self] in
            do {
                let response = try await client.data(for: posterRequest)
                try Task.checkCancellation()
                guard let image = UIImage(data: response.data),
                      let self,
                      self.nowPlayingContentID == contentID else { return }
                self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.publishNowPlayingInfo()
            } catch { }
        }
    }

    private func publishNowPlayingInfo() {
        guard let nowPlayingTitle, let nowPlayingContentID else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .playing
                ? Double(player.rate)
                : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(player.defaultRate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: nowPlayingContentID,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let nowPlayingSubtitle {
            info[MPMediaItemPropertyArtist] = nowPlayingSubtitle
        }
        if let nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = player.timeControlStatus == .paused ? .paused : .playing
    }

    private func clearNowPlaying() {
        nowPlayingContentID = nil
        nowPlayingTitle = nil
        nowPlayingSubtitle = nil
        nowPlayingArtwork = nil
        let center = MPNowPlayingInfoCenter.default()
        center.playbackState = .stopped
        center.nowPlayingInfo = nil
    }

    private func configureRemoteCommandsIfNeeded() {
        guard remoteCommandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        let playTarget = center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.resumeFromRemoteCommand() }
            return .success
        }
        remoteCommandTargets.append((center.playCommand, playTarget))

        center.pauseCommand.isEnabled = true
        let pauseTarget = center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pauseFromRemoteCommand() }
            return .success
        }
        remoteCommandTargets.append((center.pauseCommand, pauseTarget))

        center.togglePlayPauseCommand.isEnabled = true
        let toggleTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.togglePlaybackFromRemoteCommand() }
            return .success
        }
        remoteCommandTargets.append((center.togglePlayPauseCommand, toggleTarget))

        center.changePlaybackPositionCommand.isEnabled = true
        let positionTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = positionEvent.positionTime
            Task { @MainActor [weak self] in self?.seekFromRemoteCommand(to: position) }
            return .success
        }
        remoteCommandTargets.append((center.changePlaybackPositionCommand, positionTarget))
    }

    private func removeRemoteCommands() {
        for target in remoteCommandTargets {
            target.command.removeTarget(target.target)
        }
        remoteCommandTargets.removeAll()

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
    }

    private func resumeFromRemoteCommand() {
        guard let item = player.currentItem else { return }
        playbackWasRequested = true
        playbackErrorMessage = nil
        let currentTime = item.currentTime().seconds
        let itemDuration = item.duration.seconds
        let rate = Float(playbackRate.isFinite && playbackRate > 0 ? playbackRate : 1)

        if currentTime.isFinite,
           itemDuration.isFinite,
           itemDuration > 0,
           currentTime >= itemDuration - 0.5 {
            item.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.player.playImmediately(atRate: rate)
                    self?.publishNowPlayingInfo()
                }
            }
        } else {
            player.playImmediately(atRate: rate)
            publishNowPlayingInfo()
        }
    }

    private func pauseFromRemoteCommand() {
        guard player.currentItem != nil else { return }
        playbackWasRequested = false
        shouldResumeAfterBuffering = false
        isBuffering = false
        recoveryWatchdogTask?.cancel()
        recoveryWatchdogTask = nil
        player.pause()
        publishNowPlayingInfo()
    }

    private func togglePlaybackFromRemoteCommand() {
        if player.timeControlStatus == .paused {
            resumeFromRemoteCommand()
        } else {
            pauseFromRemoteCommand()
        }
    }

    private func seekFromRemoteCommand(to position: TimeInterval) {
        guard player.currentItem != nil, position.isFinite else { return }
        player.seek(
            to: CMTime(seconds: max(0, position), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.publishNowPlayingInfo() }
        }
    }

    private func applyQuality(to item: AVPlayerItem) {
        guard let selectedQuality else {
            item.preferredPeakBitRate = automaticPeakBitRate ?? 0
            item.preferredMaximumResolution = .zero
            return
        }
        item.preferredPeakBitRate = selectedQuality.peakBitRate * 1.02
        item.preferredMaximumResolution = CGSize(
            width: selectedQuality.width,
            height: selectedQuality.height
        )
    }

    private func removeInjectedSubtitleAsset() {
        subtitleServer.clear()
        injectedSubtitleNames = []
        injectedSubtitleLanguageTags = []
        subtitleRenditions = []
        subtitleRenditionsByDisplayName = [:]
        subtitleRenditionsByLanguageTag = [:]
        subtitleStudioTracks = []
        subtitlePlaybackSource = nil
        canAdjustSubtitleTiming = false
        canOpenSubtitleStudio = false
    }
}

enum PlaybackRecoveryAction: Equatable, Sendable {
    case keepWaiting
    case retryPlay
    case refreshSource
    case fail
}

enum PlaybackRecoveryPolicy {
    static let watchdogInterval: Duration = .seconds(8)
    static let minimumBufferGrowth = 0.5
    static let maximumSourceRefreshes = 3

    static func action(
        stagnantChecks: Int,
        sourceRefreshAttempts: Int
    ) -> PlaybackRecoveryAction {
        if sourceRefreshAttempts >= maximumSourceRefreshes { return .fail }
        if stagnantChecks >= 2 { return .refreshSource }
        if stagnantChecks == 1 { return .retryPlay }
        return .keepWaiting
    }
}

struct StreamQuality: Identifiable, Hashable, Sendable {
    let width: Int
    let height: Int
    let peakBitRate: Double

    var id: Int { height }
    var title: String { "\(height)p" }

    static func closest(to preferredHeight: Int, in qualities: [StreamQuality]) -> StreamQuality? {
        guard preferredHeight > 0 else { return nil }
        return qualities.last(where: { $0.height <= preferredHeight }) ?? qualities.first
    }
}

private actor HLSPlaylistInspector {
    private let client: any HTTPClientProtocol

    init(client: any HTTPClientProtocol = HTTPClient()) {
        self.client = client
    }

    func availableQualities(for source: PlaybackSource) async -> [StreamQuality] {
        do {
            var request = URLRequest(url: source.url)
            for (name, value) in source.headers { request.setValue(value, forHTTPHeaderField: name) }
            let response = try await client.data(for: request)
            try Task.checkCancellation()
            guard let playlist = String(data: response.data, encoding: .utf8) else { return [] }
            return HLSMasterPlaylistParser.qualities(from: playlist)
        } catch {
            return []
        }
    }
}

enum HLSMasterPlaylistParser {
    static func qualities(from playlist: String) -> [StreamQuality] {
        var byHeight: [Int: StreamQuality] = [:]
        for line in playlist.split(whereSeparator: \.isNewline) {
            let value = String(line)
            guard value.hasPrefix("#EXT-X-STREAM-INF:"),
                  let resolution = capture(#"RESOLUTION=(\d+)x(\d+)"#, in: value),
                  let width = Int(resolution[0]),
                  let height = Int(resolution[1]) else { continue }
            let averageBandwidth = capture(#"AVERAGE-BANDWIDTH=(\d+)"#, in: value)?.first.flatMap(Double.init)
            let bandwidth = capture(#"(?:^|,)BANDWIDTH=(\d+)"#, in: value)?.first.flatMap(Double.init)
            let quality = StreamQuality(
                width: width,
                height: height,
                peakBitRate: averageBandwidth ?? bandwidth ?? 0
            )
            if quality.peakBitRate >= (byHeight[height]?.peakBitRate ?? -1) {
                byHeight[height] = quality
            }
        }
        return byHeight.values.sorted { $0.height < $1.height }
    }

    /// Returns a valid master playlist that exposes only variants at the
    /// requested resolution. Keeping the master (instead of opening a media
    /// playlist directly) preserves alternate audio and subtitle groups.
    static func playlist(_ playlist: String, filteredToHeight targetHeight: Int) -> String {
        let lines = playlist.components(separatedBy: .newlines)
        guard lines.contains(where: {
            $0.hasPrefix("#EXT-X-STREAM-INF:") && resolutionHeight(in: $0) == targetHeight
        }) else { return playlist }

        var output: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let keepVariant = resolutionHeight(in: line) == targetHeight
                if keepVariant { output.append(line) }
                index += 1
                while index < lines.count {
                    let followingLine = lines[index]
                    let isVariantURI = !followingLine.isEmpty && !followingLine.hasPrefix("#")
                    if keepVariant { output.append(followingLine) }
                    index += 1
                    if isVariantURI { break }
                }
                continue
            }
            if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:"),
               let height = resolutionHeight(in: line),
               height != targetHeight {
                index += 1
                continue
            }
            output.append(line)
            index += 1
        }
        return output.joined(separator: "\n")
    }

    private static func resolutionHeight(in line: String) -> Int? {
        capture(#"RESOLUTION=\d+x(\d+)"#, in: line)?.first.flatMap(Int.init)
    }

    private static func capture(_ pattern: String, in value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
            return nil
        }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: value).map { String(value[$0]) }
        }
    }
}

private extension PlaybackSource {
    func preferredForSubtitleLanguage(_ languageCode: String) -> PlaybackSource {
        guard !languageCode.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return self }
        var queryItems = components.queryItems ?? []
        if let index = queryItems.firstIndex(where: { $0.name == "language" }) {
            queryItems[index] = URLQueryItem(name: "language", value: languageCode)
        } else {
            queryItems.append(URLQueryItem(name: "language", value: languageCode))
        }
        components.queryItems = queryItems
        guard let preferredURL = components.url else { return self }
        var preferredHeaders = headers
        preferredHeaders["Accept-Language"] = "\(languageCode),en;q=0.8"
        preferredHeaders["Cookie"] = "language=\(languageCode)"
        return PlaybackSource(
            url: preferredURL,
            headers: preferredHeaders,
            subtitles: subtitles,
            preferredPeakBitRate: preferredPeakBitRate
        )
    }
}

private actor AudioSessionController {
    private var isActive = false

    func activateForPlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            try session.setActive(true)
            isActive = true
        } catch {
            isActive = false
        }
    }

    func markInactive() {
        isActive = false
    }

    func deactivate() {
        guard isActive else { return }
        defer { isActive = false }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }
}

final class LayoutAwarePlayerViewController: AVPlayerViewController {
    var onLayout: ((LayoutAwarePlayerViewController) -> Void)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?(self)
    }
}

struct NativePlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    let isZoomedToFill: Bool
    let isBuffering: Bool
    let playbackErrorMessage: String?
    let availableQualities: [StreamQuality]
    let selectedQuality: StreamQuality?
    let subtitleTimingOffset: Double
    let canAdjustSubtitleTiming: Bool
    let onQualityChanged: (StreamQuality?) -> Void
    let onAdjustSubtitleTiming: (Double) -> Void
    let onOpenSubtitleSync: () -> Void
    let onRetryPlayback: () -> Void
    let onZoomChanged: (Bool) -> Void
    let onWillDismiss: () -> Void
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            availableQualities: availableQualities,
            selectedQuality: selectedQuality,
            onQualityChanged: onQualityChanged,
            onAdjustSubtitleTiming: onAdjustSubtitleTiming,
            onOpenSubtitleSync: onOpenSubtitleSync,
            onRetryPlayback: onRetryPlayback,
            isZoomedToFill: isZoomedToFill,
            onZoomChanged: onZoomChanged,
            onWillDismiss: onWillDismiss,
            onDismiss: onDismiss
        )
    }

    func makeUIViewController(context: Context) -> LayoutAwarePlayerViewController {
        let controller = LayoutAwarePlayerViewController()
        controller.player = player
        controller.delegate = context.coordinator
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.entersFullScreenWhenPlaybackBegins = true
        controller.onLayout = { [weak coordinator = context.coordinator] controller in
            coordinator?.playerViewDidLayout(controller)
        }
        context.coordinator.installControls(in: controller)
        return controller
    }

    func updateUIViewController(_ controller: LayoutAwarePlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        context.coordinator.updateZoomPreference(isZoomedToFill, in: controller)
        context.coordinator.updateQualities(
            availableQualities,
            selectedQuality: selectedQuality
        )
        context.coordinator.updateSubtitleTiming(
            offset: subtitleTimingOffset,
            isAvailable: canAdjustSubtitleTiming
        )
        context.coordinator.updateBuffering(isBuffering)
        context.coordinator.updatePlaybackError(playbackErrorMessage)
    }

    @MainActor
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        private let systemVolumeHUDSuppressor = MPVolumeView(frame: .zero)
        private let settingsButton = UIButton(type: .system)
        private let bufferingIndicator = UIActivityIndicatorView(style: .large)
        private let playbackErrorView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        private let playbackErrorLabel = UILabel()
        private let retryPlaybackButton = UIButton(type: .system)
        private let subtitleTimingControl = UIStackView()
        private let subtitleTimingLabel = UILabel()
        private let decreaseSubtitleTimingButton = UIButton(type: .system)
        private let increaseSubtitleTimingButton = UIButton(type: .system)
        private var availableQualities: [StreamQuality]
        private var selectedQuality: StreamQuality?
        private let onQualityChanged: (StreamQuality?) -> Void
        private let onAdjustSubtitleTiming: (Double) -> Void
        private let onOpenSubtitleSync: () -> Void
        private let onRetryPlayback: () -> Void
        private let onWillDismiss: () -> Void
        private var subtitleTimingAvailable = false
        private var lastPlaybackErrorMessage: String?
        private var hideTask: Task<Void, Never>?
        private weak var player: AVPlayer?
        private weak var playerViewController: AVPlayerViewController?
        private var prefersZoomedToFill: Bool
        private var lastIsLandscape: Bool?
        private let onZoomChanged: (Bool) -> Void
        let onDismiss: () -> Void

        init(
            availableQualities: [StreamQuality],
            selectedQuality: StreamQuality?,
            onQualityChanged: @escaping (StreamQuality?) -> Void,
            onAdjustSubtitleTiming: @escaping (Double) -> Void,
            onOpenSubtitleSync: @escaping () -> Void,
            onRetryPlayback: @escaping () -> Void,
            isZoomedToFill: Bool,
            onZoomChanged: @escaping (Bool) -> Void,
            onWillDismiss: @escaping () -> Void,
            onDismiss: @escaping () -> Void
        ) {
            self.availableQualities = availableQualities
            self.selectedQuality = selectedQuality
            self.onQualityChanged = onQualityChanged
            self.onAdjustSubtitleTiming = onAdjustSubtitleTiming
            self.onOpenSubtitleSync = onOpenSubtitleSync
            self.onRetryPlayback = onRetryPlayback
            prefersZoomedToFill = isZoomedToFill
            self.onZoomChanged = onZoomChanged
            self.onWillDismiss = onWillDismiss
            self.onDismiss = onDismiss
            super.init()
        }

        func installControls(in controller: AVPlayerViewController) {
            guard let overlay = controller.contentOverlayView else { return }
            player = controller.player
            playerViewController = controller
            installSystemVolumeHUDSuppressor(in: controller.view)
            bufferingIndicator.translatesAutoresizingMaskIntoConstraints = false
            bufferingIndicator.color = .white
            bufferingIndicator.hidesWhenStopped = true
            bufferingIndicator.accessibilityLabel = "Buffering video"
            overlay.addSubview(bufferingIndicator)
            configurePlaybackErrorView()
            overlay.addSubview(playbackErrorView)
            settingsButton.translatesAutoresizingMaskIntoConstraints = false
            settingsButton.showsMenuAsPrimaryAction = true
            settingsButton.accessibilityLabel = "Playback settings"
            overlay.addSubview(settingsButton)
            configureSubtitleTimingControl()
            overlay.addSubview(subtitleTimingControl)
            NSLayoutConstraint.activate([
                bufferingIndicator.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                bufferingIndicator.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                playbackErrorView.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                playbackErrorView.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                playbackErrorView.widthAnchor.constraint(lessThanOrEqualTo: overlay.safeAreaLayoutGuide.widthAnchor, constant: -40),
                settingsButton.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -14),
                settingsButton.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                settingsButton.widthAnchor.constraint(equalToConstant: 44),
                settingsButton.heightAnchor.constraint(equalToConstant: 44),
                subtitleTimingControl.trailingAnchor.constraint(equalTo: settingsButton.trailingAnchor),
                subtitleTimingControl.topAnchor.constraint(equalTo: settingsButton.bottomAnchor, constant: 10),
                subtitleTimingControl.widthAnchor.constraint(equalToConstant: 156),
                subtitleTimingControl.heightAnchor.constraint(equalToConstant: 44)
            ])
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(playerTapped(_:)))
            tapGesture.cancelsTouchesInView = false
            tapGesture.delegate = self
            controller.view.addGestureRecognizer(tapGesture)
            let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(playerPinched(_:)))
            pinchGesture.cancelsTouchesInView = false
            pinchGesture.delegate = self
            controller.view.addGestureRecognizer(pinchGesture)
            updateQualities(availableQualities, selectedQuality: selectedQuality)
            showSettingsButton()
        }

        func updateZoomPreference(_ isZoomedToFill: Bool, in controller: AVPlayerViewController) {
            guard prefersZoomedToFill != isZoomedToFill else { return }
            prefersZoomedToFill = isZoomedToFill
            applyZoomPreference(in: controller)
        }

        func playerViewDidLayout(_ controller: AVPlayerViewController) {
            let isLandscape = controller.view.bounds.width > controller.view.bounds.height
            guard lastIsLandscape != isLandscape else { return }
            lastIsLandscape = isLandscape
            applyZoomPreference(in: controller)
        }

        private func applyZoomPreference(in controller: AVPlayerViewController) {
            let isLandscape = controller.view.bounds.width > controller.view.bounds.height
            controller.videoGravity = isLandscape && prefersZoomedToFill
                ? .resizeAspectFill
                : .resizeAspect
        }

        @objc private func playerPinched(_ gesture: UIPinchGestureRecognizer) {
            guard gesture.state == .ended || gesture.state == .cancelled else { return }
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, let controller = self.playerViewController else { return }
                let isLandscape = controller.view.bounds.width > controller.view.bounds.height
                guard isLandscape else {
                    controller.videoGravity = .resizeAspect
                    return
                }
                let isZoomedToFill = controller.videoGravity == .resizeAspectFill
                guard self.prefersZoomedToFill != isZoomedToFill else { return }
                self.prefersZoomedToFill = isZoomedToFill
                self.onZoomChanged(isZoomedToFill)
            }
        }

        private func installSystemVolumeHUDSuppressor(in view: UIView) {
            // AVPlayerViewController already presents its own volume slider. Keeping an
            // MPVolumeView attached makes iOS omit the second, system-level volume HUD.
            systemVolumeHUDSuppressor.translatesAutoresizingMaskIntoConstraints = false
            systemVolumeHUDSuppressor.isUserInteractionEnabled = false
            systemVolumeHUDSuppressor.accessibilityElementsHidden = true
            systemVolumeHUDSuppressor.alpha = 0.001
            view.addSubview(systemVolumeHUDSuppressor)
            NSLayoutConstraint.activate([
                systemVolumeHUDSuppressor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                systemVolumeHUDSuppressor.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                systemVolumeHUDSuppressor.widthAnchor.constraint(equalToConstant: 1),
                systemVolumeHUDSuppressor.heightAnchor.constraint(equalToConstant: 1)
            ])
        }

        func updateBuffering(_ isBuffering: Bool) {
            if isBuffering && playbackErrorView.isHidden {
                bufferingIndicator.startAnimating()
            } else {
                bufferingIndicator.stopAnimating()
            }
        }

        func updatePlaybackError(_ message: String?) {
            guard lastPlaybackErrorMessage != message else { return }
            lastPlaybackErrorMessage = message
            playbackErrorLabel.text = message
            playbackErrorView.isHidden = message == nil
            if message == nil {
                return
            }
            bufferingIndicator.stopAnimating()
            UIAccessibility.post(notification: .announcement, argument: message)
        }

        private func configurePlaybackErrorView() {
            playbackErrorView.translatesAutoresizingMaskIntoConstraints = false
            playbackErrorView.layer.cornerRadius = 16
            playbackErrorView.clipsToBounds = true
            playbackErrorView.isHidden = true

            playbackErrorLabel.font = .preferredFont(forTextStyle: .body)
            playbackErrorLabel.textColor = .white
            playbackErrorLabel.textAlignment = .center
            playbackErrorLabel.numberOfLines = 0

            var retryConfiguration = UIButton.Configuration.filled()
            retryConfiguration.title = "Retry"
            retryConfiguration.image = UIImage(systemName: "arrow.clockwise")
            retryConfiguration.imagePadding = 8
            retryPlaybackButton.configuration = retryConfiguration
            retryPlaybackButton.accessibilityHint = "Reloads the stream and resumes from your current position"
            retryPlaybackButton.addTarget(self, action: #selector(retryPlayback), for: .touchUpInside)

            let stack = UIStackView(arrangedSubviews: [playbackErrorLabel, retryPlaybackButton])
            stack.axis = .vertical
            stack.alignment = .center
            stack.spacing = 14
            stack.translatesAutoresizingMaskIntoConstraints = false
            playbackErrorView.contentView.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: playbackErrorView.contentView.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: playbackErrorView.contentView.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: playbackErrorView.contentView.topAnchor, constant: 18),
                stack.bottomAnchor.constraint(equalTo: playbackErrorView.contentView.bottomAnchor, constant: -18)
            ])
        }

        @objc private func retryPlayback() {
            playbackErrorView.isHidden = true
            bufferingIndicator.startAnimating()
            onRetryPlayback()
        }

        func updateSubtitleTiming(offset: Double, isAvailable: Bool) {
            let becameAvailable = !subtitleTimingAvailable && isAvailable
            let availabilityChanged = subtitleTimingAvailable != isAvailable
            subtitleTimingAvailable = isAvailable
            subtitleTimingLabel.text = Self.subtitleTimingText(offset)
            subtitleTimingLabel.accessibilityValue = Self.subtitleTimingAccessibilityValue(offset)
            subtitleTimingControl.isHidden = true
            if availabilityChanged { rebuildSettingsMenu() }
            if becameAvailable { showSettingsButton() }
        }

        private func configureSubtitleTimingControl() {
            subtitleTimingControl.axis = .horizontal
            subtitleTimingControl.alignment = .fill
            subtitleTimingControl.distribution = .fill
            subtitleTimingControl.spacing = 2
            subtitleTimingControl.translatesAutoresizingMaskIntoConstraints = false
            subtitleTimingControl.backgroundColor = UIColor(white: 0.14, alpha: 0.92)
            subtitleTimingControl.layer.cornerRadius = 12
            subtitleTimingControl.clipsToBounds = true
            subtitleTimingControl.isHidden = true

            configureTimingButton(
                decreaseSubtitleTimingButton,
                systemImage: "minus",
                accessibilityLabel: "Show subtitles earlier",
                action: #selector(decreaseSubtitleTiming)
            )
            configureTimingButton(
                increaseSubtitleTimingButton,
                systemImage: "plus",
                accessibilityLabel: "Show subtitles later",
                action: #selector(increaseSubtitleTiming)
            )
            subtitleTimingLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            subtitleTimingLabel.textColor = .white
            subtitleTimingLabel.textAlignment = .center
            subtitleTimingLabel.accessibilityLabel = "Subtitle timing"
            subtitleTimingLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

            subtitleTimingControl.addArrangedSubview(decreaseSubtitleTimingButton)
            subtitleTimingControl.addArrangedSubview(subtitleTimingLabel)
            subtitleTimingControl.addArrangedSubview(increaseSubtitleTimingButton)
            NSLayoutConstraint.activate([
                decreaseSubtitleTimingButton.widthAnchor.constraint(equalToConstant: 42),
                increaseSubtitleTimingButton.widthAnchor.constraint(equalToConstant: 42)
            ])
        }

        private func configureTimingButton(
            _ button: UIButton,
            systemImage: String,
            accessibilityLabel: String,
            action: Selector
        ) {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: systemImage)
            configuration.baseForegroundColor = .white
            button.configuration = configuration
            button.accessibilityLabel = accessibilityLabel
            button.addTarget(self, action: action, for: .touchUpInside)
        }

        @objc private func decreaseSubtitleTiming() {
            onAdjustSubtitleTiming(-0.1)
            showSettingsButton()
        }

        @objc private func increaseSubtitleTiming() {
            onAdjustSubtitleTiming(0.1)
            showSettingsButton()
        }

        private static func subtitleTimingText(_ offset: Double) -> String {
            if abs(offset) < 0.05 { return "0.0 sec" }
            return String(format: "%+.1f sec", offset)
        }

        private static func subtitleTimingAccessibilityValue(_ offset: Double) -> String {
            String(format: "%+.1f seconds", offset)
        }

        func updateQualities(
            _ qualities: [StreamQuality],
            selectedQuality: StreamQuality?
        ) {
            if settingsButton.configuration != nil,
               availableQualities == qualities,
               self.selectedQuality == selectedQuality {
                return
            }
            let discoveredQualities = availableQualities.isEmpty && !qualities.isEmpty
            availableQualities = qualities
            self.selectedQuality = selectedQuality
            rebuildSettingsMenu()
            if discoveredQualities { showSettingsButton() }
        }

        private func rebuildSettingsMenu() {
            let hasSettings = !availableQualities.isEmpty || subtitleTimingAvailable
            settingsButton.isHidden = !hasSettings
            guard hasSettings else {
                settingsButton.menu = nil
                return
            }

            var configuration: UIButton.Configuration
            if #available(iOS 26.0, *) {
                configuration = .glass()
            } else {
                configuration = .gray()
            }
            configuration.cornerStyle = .capsule
            configuration.image = UIImage(systemName: "slider.horizontal.3")
            configuration.baseForegroundColor = .white
            settingsButton.configuration = configuration

            let qualityValue = selectedQuality?.title ?? "Auto"
            settingsButton.accessibilityValue = "Quality \(qualityValue)"

            var sections: [UIMenuElement] = []
            if !availableQualities.isEmpty {
                let automaticAction = UIAction(
                    title: "Auto",
                    state: selectedQuality == nil ? .on : .off
                ) { [weak self] _ in
                    self?.onQualityChanged(nil)
                    self?.showSettingsButton()
                }
                let qualityActions = availableQualities.reversed().map { quality in
                    UIAction(
                        title: quality.title,
                        state: quality == selectedQuality ? .on : .off
                    ) { [weak self] _ in
                        self?.onQualityChanged(quality)
                        self?.showSettingsButton()
                    }
                }
                sections.append(UIMenu(
                    title: "Video Quality",
                    image: UIImage(systemName: "video"),
                    children: [automaticAction] + qualityActions
                ))
            }

            if subtitleTimingAvailable {
                sections.append(UIAction(
                    title: "Subtitle Sync Studio",
                    image: UIImage(systemName: "captions.bubble")
                ) { [weak self] _ in
                    self?.onOpenSubtitleSync()
                })
            }

            settingsButton.menu = UIMenu(title: "Playback Settings", children: sections)
        }

        @objc private func playerTapped(_ gesture: UITapGestureRecognizer) {
            guard !settingsButton.isHidden
                    || subtitleTimingAvailable else { return }
            let buttonLocation = gesture.location(in: settingsButton)
            guard !settingsButton.bounds.contains(buttonLocation) else {
                showSettingsButton()
                return
            }
            if let view = gesture.view {
                let location = gesture.location(in: view)
                var hitView: UIView? = view.hitTest(location, with: nil)
                while let current = hitView {
                    if current is UIControl {
                        showSettingsButton()
                        return
                    }
                    hitView = current.superview
                }
            }
            settingsButton.alpha > 0.1 ? hideSettingsButton() : showSettingsButton()
        }

        private func showSettingsButton() {
            guard !availableQualities.isEmpty
                    || subtitleTimingAvailable else { return }
            hideTask?.cancel()
            UIView.animate(withDuration: 0.2) { [settingsButton] in
                settingsButton.alpha = 0.86
            }
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.hideSettingsButton()
            }
        }

        private func hideSettingsButton() {
            hideTask?.cancel()
            UIView.animate(withDuration: 0.2) { [settingsButton] in
                settingsButton.alpha = 0
            }
            UIView.animate(withDuration: 0.2) { [subtitleTimingControl] in
                subtitleTimingControl.alpha = 0
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func playerViewControllerWillEndFullScreenPresentation(
            _ playerViewController: AVPlayerViewController,
            withAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            // Restore portrait while the player still covers the presenting
            // screen. Waiting until PlayerScreen disappears lets the details
            // view briefly lay itself out using the player's landscape width.
            onWillDismiss()
            coordinator.animate(alongsideTransition: nil) { [onDismiss] _ in onDismiss() }
        }
    }
}
