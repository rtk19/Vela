@preconcurrency import AVKit
@preconcurrency import Network
import Combine
@preconcurrency import MediaPlayer
import SwiftUI
import UIKit

@MainActor
final class HLSSubtitleLoopbackServer {
    private struct Route {
        let content: Data
        let contentType: String
    }

    private var listener: NWListener?
    private var listenerPort: NWEndpoint.Port?
    private var listenerError: NWError?
    private var routes: [String: Route] = [:]
    private var requestBuffers: [ObjectIdentifier: Data] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    deinit {
        listener?.cancel()
        for connection in connections.values { connection.cancel() }
    }

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
                } else if file.pathExtension.lowercased() == "ts" {
                    contentType = "video/mp2t"
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
            // Bind to loopback explicitly. acceptLocalOnly restricts peers to the
            // local link and can reject loopback requests before they are accepted.
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
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled:
                    self?.connections.removeValue(forKey: identifier)
                    self?.requestBuffers.removeValue(forKey: identifier)
                default: break
                }
            }
        }
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
        // Finish the HTTP response gracefully. Cancelling immediately after queuing
        // the bytes can reset the socket before AVPlayer receives the response.
        connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { error in
            if error != nil {
                connection.cancel()
            } else {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in
                    connection.cancel()
                }
            }
        })
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

enum SubtitleSelectionLookup {
    static func make(
        displayNames: [String],
        languageTags: [String],
        renditions: [HLSSubtitleRendition]
    ) -> [String: HLSSubtitleRendition] {
        var result = Dictionary(uniqueKeysWithValues: zip(displayNames, renditions))
        let tagCounts = Dictionary(grouping: languageTags.map { $0.lowercased() }, by: { $0 })
            .mapValues(\.count)
        for (languageTag, rendition) in zip(languageTags, renditions) {
            let normalizedTag = languageTag.lowercased()
            if tagCounts[normalizedTag] == 1 { result[normalizedTag] = rendition }
        }
        return result
    }
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

    private(set) var playbackState: PlaybackSessionState = .idle

    var onEnded: (() -> Void)?
    var onSourceRefreshNeeded: (() async -> Bool)?
    var onSubtitleVisibilityChanged: ((Bool) -> Void)?
    nonisolated(unsafe) private var timeObserver: Any?
    nonisolated(unsafe) private var studioTimeObserver: Any?
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    nonisolated(unsafe) private var mediaSelectionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var playbackStalledObserver: NSObjectProtocol?
    nonisolated(unsafe) private var playbackErrorLogObserver: NSObjectProtocol?
    nonisolated(unsafe) private var failedToPlayToEndObserver: NSObjectProtocol?
    nonisolated(unsafe) private var timeJumpedObserver: NSObjectProtocol?
    nonisolated(unsafe) private var audioInterruptionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var audioRouteChangeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var rateObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var defaultRateObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var timeControlStatusObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var playbackBufferEmptyObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var playbackLikelyToKeepUpObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var itemStatusObservation: NSKeyValueObservation?
    private var mediaOptionsTask: Task<Void, Never>?
    private var mediaSelectionGeneration = UUID()
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
    private var subtitleRenditionsBySelectionID: [String: HLSSubtitleRendition] = [:]
    private var subtitlePlaybackSource: PlaybackSource?
    private var subtitleSyncVersions: [SubtitleSyncVersion] = []
    private var studioPreviousSubtitleDisplayName: String?
    private var studioWasPlaying = false
    private var subtitleStudioSeekToken = UUID()
    private var appliedSubtitleTimingOffset: Double = 0
    private var primarySubtitleLanguage = ""
    private var secondarySubtitleLanguage = ""

    private var audioLanguage = "en"
    private var subtitleVisibilityBaseline: Bool?
    private var subtitleSelectionAuthority = SubtitleSelectionAuthority()
    private var isApplyingPreferredLanguages = false
    private var isStabilizingMediaSelection = false
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
    private var seekRecoveryGraceUntil: Date?
    private var playbackSeekState = PlaybackSeekState()
    private var wasPlayingBeforeInterruption = false
    private var qualityPreferenceInitialized = false
    private var preferredQualityHeight: Int?
    private var automaticPeakBitRate: Double?
    private var currentPlaybackSource: PlaybackSource?
    private var currentExternalSubtitles: [SubtitleSource] = []
    private let playlistInspector = HLSPlaylistInspector()
    private let subtitleClient: any HTTPClientProtocol
    private var subtitleServer = HLSSubtitleLoopbackServer()
    private var sourceSwitchGeneration = UUID()
    private var pendingSourceSwitchTime: Double?
    private var pendingSourceSwitchShouldPlay: Bool?
    private var pendingSourceSwitchRate: Float?
    private var pendingSourceSwitchItem: AVPlayerItem?
    private var isSourceSwitching = false
    private var startupPlayingLogged = false
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
        timeControlStatusObservation =
            player.observe(
                \.timeControlStatus,
                options: [.initial, .new]
            ) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    self.refreshPlaybackState()

                    if self.player.timeControlStatus == .playing,
                       !self.startupPlayingLogged {

                        self.startupPlayingLogged = true

                        PlaybackStartupTrace.mark(
                            "AVPlayer PLAYING"
                        )
                    }
                }
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
        if let timeJumpedObserver { NotificationCenter.default.removeObserver(timeJumpedObserver) }
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
        subtitlesEnabled: Bool,
        defaultQualityHeight: Int,
        defaultPlaybackRate: Float
    ) async {
        let startupPerfStart = PlaybackStartupTrace.now()

        PlaybackStartupTrace.mark(
            "PlayerSession LOAD START"
        )

        startupPlayingLogged = false
        sourceSwitchGeneration = UUID()
        pendingSourceSwitchTime = nil
        pendingSourceSwitchShouldPlay = nil
        pendingSourceSwitchRate = nil
        pendingSourceSwitchItem = nil
        isSourceSwitching = false
        // Recovery may replace an item while the user is intentionally paused.
        // Consume the intent before asynchronous subtitle preparation so the
        // replacement cannot unexpectedly start itself later.
        let shouldPlay = nextReplacementShouldPlay ?? true
        nextReplacementShouldPlay = nil
        recoveryWatchdogTask?.cancel()
        qualitySwitchTask?.cancel()
        playbackState = .preparing
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
        let qualityPerfStart =
            PlaybackStartupTrace.now()
        let qualities = await playlistInspector.availableQualities(for: preparedSource)
        PlaybackStartupTrace.mark(
            "PlayerSession qualities READY duration=\(PlaybackStartupTrace.duration(since: qualityPerfStart))ms"
        )
        guard !Task.isCancelled else { return }
        availableQualities = qualities
        if !qualityPreferenceInitialized {
            preferredQualityHeight = defaultQualityHeight > 0 ? defaultQualityHeight : nil
            qualityPreferenceInitialized = true
        }
        selectedQuality = preferredQualityHeight.flatMap {
            StreamQuality.closest(to: $0, in: qualities)
        }
        let subtitlePerfStart =
            PlaybackStartupTrace.now()

        PlaybackStartupTrace.mark(
            "PlayerSession subtitle injection START external=\(externalSubtitles.count)"
        )
        let asset = await assetByInjectingSubtitles(
            externalSubtitles,
            into: preparedSource,
            selectedQuality: selectedQuality
        )
        PlaybackStartupTrace.mark(
            "PlayerSession subtitle injection DONE duration=\(PlaybackStartupTrace.duration(since: subtitlePerfStart))ms"
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
        let preferredSyncVersionID = subtitlesEnabled && automaticallySelectLatestSubtitleSync
            ? subtitleSyncVersions
                .sorted { $0.createdAt > $1.createdAt }
                .compactMap { version in
                    selectionID(forSyncVersionID: version.id).map { (version.id, $0) }
                }
                .first
            : nil
        subtitleVisibilityBaseline = subtitlesEnabled
        PlaybackStartupTrace.mark(
            "PlayerSession replaceCurrentItem total=\(PlaybackStartupTrace.duration(since: startupPerfStart))ms"
        )
        replaceCurrentItem(
            with: asset,
            resumeAt: resumeAt,
            shouldPlay: shouldPlay,
            playbackRate: defaultPlaybackRate,
            preferredSubtitleSelectionID: subtitlesEnabled
                ? preferredSyncVersionID?.1
                : "__subtitles_off__"
        )
        schedulePausedSourceRefreshBeforeExpiration()
    }

    func stop() {
        sourceSwitchGeneration = UUID()
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
        pendingSourceSwitchTime = nil
        pendingSourceSwitchShouldPlay = nil
        pendingSourceSwitchRate = nil
        pendingSourceSwitchItem = nil
        isSourceSwitching = false
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
        playbackState = .idle
        seekRecoveryGraceUntil = nil
        playbackSeekState.reset()
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

    /// Snapshot the active item while it keeps playing. The replacement is
    /// prepared independently and is swapped in only after validation succeeds.
    func beginSourceSwitch() {
        guard let item = player.currentItem, pendingSourceSwitchItem == nil else { return }
        let time = player.currentTime().seconds
        pendingSourceSwitchTime = time.isFinite ? time : position
        pendingSourceSwitchShouldPlay = player.rate > 0 || player.timeControlStatus != .paused
        pendingSourceSwitchRate = player.rate > 0 ? player.rate : player.defaultRate
        pendingSourceSwitchItem = item
        isSourceSwitching = true
    }

    func supersedeSourceSwitch() {
        guard isSourceSwitching
                || pendingSourceSwitchItem != nil else {
            return
        }

        // Invalidate any replacement currently being prepared,
        // while deliberately keeping the original playback snapshot.
        sourceSwitchGeneration = UUID()
    }

    func cancelSourceSwitch(resumePrevious: Bool) {
        let shouldResume = resumePrevious && pendingSourceSwitchShouldPlay == true
        let rate = pendingSourceSwitchRate ?? player.defaultRate
        let previousItem = pendingSourceSwitchItem
        pendingSourceSwitchTime = nil
        pendingSourceSwitchShouldPlay = nil
        pendingSourceSwitchRate = nil
        pendingSourceSwitchItem = nil
        isSourceSwitching = false
        if resumePrevious, player.currentItem == nil, let previousItem {
            player.replaceCurrentItem(with: previousItem)
        }
        isBuffering = false
        if shouldResume { player.playImmediately(atRate: rate) }
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

    /// Prepare using a separate subtitle server so a failed switch cannot delete
    /// the active stream's playlist or subtitle routes.
    func switchSource(_ stream: PlayableStream, externalSubtitles: [SubtitleSource],
                      quality: StreamQuality? = nil, useQualityChoice: Bool = false) async -> Bool {
        guard let oldItem = pendingSourceSwitchItem ?? player.currentItem else { return false }
        let generation = UUID()
        sourceSwitchGeneration = generation
        let oldServer = subtitleServer
        let oldNames = injectedSubtitleNames
        let oldLanguageTags = injectedSubtitleLanguageTags
        let oldRenditions = subtitleRenditions
        let oldByName = subtitleRenditionsByDisplayName
        let oldByID = subtitleRenditionsBySelectionID
        let oldTracks = subtitleStudioTracks
        let oldSubtitleSource = subtitlePlaybackSource
        let oldCanStudio = canOpenSubtitleStudio
        let oldCanAdjust = canAdjustSubtitleTiming
        let oldLanguage = primarySubtitleLanguage
        let subtitleID = await selectedSubtitleSelectionID()
        let subtitleName = await selectedSubtitleDisplayName()
        let legible = try? await oldItem.asset.loadMediaSelectionGroup(for: .legible)
        let audible = try? await oldItem.asset.loadMediaSelectionGroup(for: .audible)
        let selectedAudioLanguage = audible.flatMap { oldItem.currentMediaSelection.selectedMediaOption(in: $0)?.extendedLanguageTag }
        let subtitlesWereOff = legible.map { oldItem.currentMediaSelection.selectedMediaOption(in: $0) == nil } ?? false
        guard generation == sourceSwitchGeneration, !Task.isCancelled else { return false }
        qualitySwitchTask?.cancel()
        subtitleAdjustmentTask?.cancel()
        let height = useQualityChoice ? quality?.height : preferredQualityHeight
        let newQuality = height.flatMap { StreamQuality.closest(to: $0, in: stream.qualities) }
        let source = stream.source.preferredForSubtitleLanguage(primarySubtitleLanguage)
        subtitleServer = HLSSubtitleLoopbackServer()
        let asset = await assetByInjectingSubtitles(source.subtitles + externalSubtitles, into: source, selectedQuality: newQuality, generation: generation)
        let playable = await replacementIsReady(asset, generation: generation)
        let oldItemIsStillCurrent = player.currentItem === oldItem
        let oldItemIsDetachedForSwitch = player.currentItem == nil && pendingSourceSwitchItem === oldItem
        guard playable,
              generation == sourceSwitchGeneration,
              !Task.isCancelled,
              oldItemIsStillCurrent || oldItemIsDetachedForSwitch else {

            // A newer source-switch request superseded this one.
            // Do not restore state or clear the original playback snapshot,
            // because the newer request is still using it.
            guard generation == sourceSwitchGeneration else {
                return false
            }

            subtitleServer = oldServer
            injectedSubtitleNames = oldNames
            injectedSubtitleLanguageTags = oldLanguageTags
            subtitleRenditions = oldRenditions
            subtitleRenditionsByDisplayName = oldByName
            subtitleRenditionsBySelectionID = oldByID
            subtitleStudioTracks = oldTracks
            subtitlePlaybackSource = oldSubtitleSource
            canOpenSubtitleStudio = oldCanStudio
            canAdjustSubtitleTiming = oldCanAdjust

            cancelSourceSwitch(
                resumePrevious: true
            )

            return false
        }
        let liveTime = oldItem.currentTime().seconds
        let isAutomaticRecovery = nextReplacementShouldPlay != nil
        let resumeAt = isAutomaticRecovery
            ? (pendingSourceSwitchTime ?? (liveTime.isFinite ? liveTime : position))
            : (oldItemIsStillCurrent && liveTime.isFinite
                ? liveTime
                : (pendingSourceSwitchTime ?? position))
        let shouldPlay = nextReplacementShouldPlay
            ?? (oldItemIsStillCurrent
                ? Optional(player.rate > 0 || player.timeControlStatus != .paused)
                : pendingSourceSwitchShouldPlay)
            ?? playbackWasRequested
        nextReplacementShouldPlay = nil
        let rate: Float
        if isAutomaticRecovery {
            rate = pendingSourceSwitchRate ?? player.defaultRate
        } else if oldItemIsStillCurrent {
            rate = player.rate > 0 ? player.rate : player.defaultRate
        } else {
            rate = pendingSourceSwitchRate ?? player.defaultRate
        }
        pendingSourceSwitchTime = nil
        pendingSourceSwitchShouldPlay = nil
        pendingSourceSwitchRate = nil
        pendingSourceSwitchItem = nil
        isSourceSwitching = false
        availableQualities = stream.qualities
        selectedQuality = newQuality
        if useQualityChoice { preferredQualityHeight = quality?.height; qualityPreferenceInitialized = true }
        currentPlaybackSource = source
        currentExternalSubtitles = source.subtitles + externalSubtitles
        currentSourceURL = source.url
        currentSourceExpiresAt = Self.expirationDate(in: source.url)
        sourceRefreshRequestedForURL = nil
        automaticPeakBitRate = source.preferredPeakBitRate
        playbackErrorMessage = nil
        // The view model bounds retries per server; allow recovery on the new server.
        automaticSourceRefreshAttempts = 0
        if let selectedAudioLanguage { audioLanguage = selectedAudioLanguage }
        if subtitlesWereOff { primarySubtitleLanguage = "" }
        replaceCurrentItem(with: asset, resumeAt: resumeAt, shouldPlay: shouldPlay, playbackRate: rate,
                           preferredSubtitleDisplayName: subtitleName,
                           preferredSubtitleSelectionID: subtitlesWereOff ? "__subtitles_off__" : subtitleID)
        primarySubtitleLanguage = oldLanguage
        schedulePausedSourceRefreshBeforeExpiration()
        withExtendedLifetime(oldServer) { }
        return true
    }

    private func replacementIsReady(_ asset: AVAsset, generation: UUID) async -> Bool {
        let item = AVPlayerItem(asset: asset)
        let preparationPlayer = AVPlayer(playerItem: item)
        preparationPlayer.isMuted = true
        defer { preparationPlayer.replaceCurrentItem(with: nil) }
        // Loading a manifest alone does not establish that the native player can
        // prepare its tracks. Keep the working item until the replacement is ready.
        for _ in 0..<160 {
            guard generation == sourceSwitchGeneration, !Task.isCancelled else { return false }
            switch item.status {
            case .readyToPlay: return true
            case .failed: return false
            default: break
            }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        return false
    }

    func setQuality(_ quality: StreamQuality?) {
        guard selectedQuality != quality else { return }
        preferredQualityHeight = quality?.height
        qualityPreferenceInitialized = true
        selectedQuality = quality
        guard let item = player.currentItem else { return }
        qualitySwitchTask?.cancel()
        applyQuality(to: item)
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
                    primarySubtitleLanguage: primarySubtitleLanguage,
                    secondarySubtitleLanguage: secondarySubtitleLanguage,
                    client: subtitleClient
                )
                try Task.checkCancellation()
                let selectedSubtitleName = await self.selectedSubtitleDisplayName()
                let selectedSubtitleSelectionID = await self.selectedSubtitleSelectionID()
                let localMasterURL = try await self.subtitleServer.publish(injectedAsset)
                let currentTime = self.player.currentTime().seconds
                let resumeAt = currentTime.isFinite ? currentTime : self.position
                let wasPlaying = self.player.timeControlStatus != .paused
                let playbackRate = self.player.rate > 0
                    ? self.player.rate
                    : self.player.defaultRate
                self.injectedSubtitleNames = injectedAsset.displayNames
                self.injectedSubtitleLanguageTags = Set(
                    injectedAsset.languageTags.map { $0.lowercased() }
                )
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
                    preferredSubtitleSelectionID: selectedSubtitleSelectionID,
                    seekTolerance: .zero
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
        await logSubtitleDiagnostics(at: subtitleStudioPosition)
        studioPreviousSubtitleDisplayName = await selectedSubtitleDisplayName()
        let selectedLanguageTag = await selectedSubtitleSelectionID()
        let selectedRendition = selectedLanguageTag.flatMap {
            subtitleRenditionsBySelectionID[$0]
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
        let selectedTrack = subtitleStudioTracks.first { $0.id == selectedTrackID }
        let studioOffset = selectedRendition?.timingOffset ?? 0
        let sourceTime = subtitleStudioPosition - studioOffset
        let activeCue = selectedTrack?.cues.first {
            $0.startTime <= sourceTime && sourceTime < $0.endTime
        }
        SubtitleDiagnostics.logger.notice(
            "SUBSYNC studio: playerID=\(selectedLanguageTag ?? "none", privacy: .public) resolvedProvider=\(selectedTrack?.source.providerID ?? "none", privacy: .public) resolvedLabel=\(selectedTrack?.source.label ?? "none", privacy: .public) playerTime=\(self.subtitleStudioPosition, privacy: .public) offset=\(studioOffset, privacy: .public) cueStart=\(activeCue?.startTime ?? -1, privacy: .public) cueEnd=\(activeCue?.endTime ?? -1, privacy: .public)"
        )
        player.pause()
        await hideNativeSubtitlesForStudio()

        return SubtitleStudioContext(
            selectedTrackID: selectedTrackID,
            offset: selectedRendition?.timingOffset ?? 0,
            selectedVersionID: selectedRendition?.syncVersionID
        )
    }

    private func hideNativeSubtitlesForStudio() async {
        guard let item = player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
              player.currentItem === item else {
            return
        }

        item.select(nil, in: group)
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
            preferredSubtitleSelectionID: selectionID(forSyncVersionID: versionID),
            seekTolerance: .zero
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
        player.currentItem?.cancelPendingSeeks()
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.subtitleStudioSeekToken == token else { return }

                await self.hideNativeSubtitlesForStudio()
                self.isSubtitleStudioSeeking = false
            }
        }

        subtitleStudioPosition = target
    }

    func toggleStudioPlayback() {
        if player.timeControlStatus == .paused {
            Task {
                await hideNativeSubtitlesForStudio()
                player.play()
            }
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
        selectedQuality: StreamQuality?,
        generation: UUID? = nil
    ) async -> AVURLAsset {
        let injectionPerfStart =
            PlaybackStartupTrace.now()

        PlaybackStartupTrace.mark(
            "subtitle asset START subtitles=\(subtitles.count)"
        )
        let originalAsset = AVURLAsset(
            url: source.url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers]
        )
        var seenResources: Set<String> = []
        let uniqueSubtitles = subtitles.filter {
            seenResources.insert("\($0.providerID):\($0.url.absoluteString)").inserted
        }
        let subtitleDownloadsStart =
            PlaybackStartupTrace.now()
        async let downloadedRenditions = loadSubtitleRenditions(uniqueSubtitles)
        async let embeddedRenditions = HLSNativeSubtitleLoader.load(
            from: source,
            client: subtitleClient
        )
        let loadedRenditions = sortSubtitleRenditions(
            await downloadedRenditions + embeddedRenditions
        )
        PlaybackStartupTrace.mark(
            "subtitle renditions READY total=\(loadedRenditions.count) duration=\(PlaybackStartupTrace.duration(since: subtitleDownloadsStart))ms"
        )
        guard !Task.isCancelled, generation == nil || generation == sourceSwitchGeneration else { return originalAsset }
        subtitleStudioTracks = loadedRenditions.map {
            SubtitleStudioTrack(source: $0.subtitle, cues: $0.cues)
        }
        canOpenSubtitleStudio = !subtitleStudioTracks.isEmpty
        subtitlePlaybackSource = loadedRenditions.isEmpty ? nil : source
        let renditions = expandedSubtitleRenditions(from: loadedRenditions)
        guard !renditions.isEmpty || selectedQuality != nil else { return originalAsset }

        do {
            let injectorStart =
                PlaybackStartupTrace.now()
            let injectedAsset = try await HLSSubtitleInjector.prepare(
                source: source,
                renditions: renditions,
                timingOffset: appliedSubtitleTimingOffset,
                selectedQualityHeight: selectedQuality?.height,
                primarySubtitleLanguage: primarySubtitleLanguage,
                secondarySubtitleLanguage: secondarySubtitleLanguage,
                client: subtitleClient
            )
            PlaybackStartupTrace.mark(
                "subtitle injector PREPARED duration=\(PlaybackStartupTrace.duration(since: injectorStart))ms"
            )
            try Task.checkCancellation()
            let publishStart =
                PlaybackStartupTrace.now()
            let localMasterURL = try await subtitleServer.publish(injectedAsset)
            PlaybackStartupTrace.mark(
                "subtitle server PUBLISHED duration=\(PlaybackStartupTrace.duration(since: publishStart))ms"
            )
            try Task.checkCancellation()
            guard generation == nil || generation == sourceSwitchGeneration else { return originalAsset }
            injectedSubtitleNames = injectedAsset.displayNames
            injectedSubtitleLanguageTags = Set(
                injectedAsset.languageTags.map { $0.lowercased() }
            )
            subtitleRenditions = renditions
            subtitleRenditionsByDisplayName = Dictionary(
                uniqueKeysWithValues: zip(injectedAsset.orderedDisplayNames, renditions)
            )
            subtitleRenditionsBySelectionID = SubtitleSelectionLookup.make(
                displayNames: injectedAsset.orderedDisplayNames,
                languageTags: injectedAsset.orderedLanguageTags,
                renditions: renditions
            )
            for (index, rendition) in renditions.enumerated() {
                let languageTag = injectedAsset.orderedLanguageTags[index]
                SubtitleDiagnostics.logger.notice(
                    "SUBSYNC generated: tag=\(languageTag, privacy: .public) provider=\(rendition.subtitle.providerID, privacy: .public) label=\(rendition.subtitle.label, privacy: .public) offset=\(rendition.timingOffset, privacy: .public) cues=\(rendition.cues.count, privacy: .public)"
                )
            }
            subtitlePlaybackSource = loadedRenditions.isEmpty ? nil : source
            PlaybackStartupTrace.mark(
                "subtitle asset DONE total=\(PlaybackStartupTrace.duration(since: injectionPerfStart))ms"
            )
            return AVURLAsset(
                url: localMasterURL,
                options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers]
            )
        } catch where error.isCancellation {
            return originalAsset
        } catch {
            guard generation == nil || generation == sourceSwitchGeneration else { return originalAsset }
            injectedSubtitleNames = []
            injectedSubtitleLanguageTags = []
            subtitleRenditions = []
            subtitleRenditionsByDisplayName = [:]
            subtitleRenditionsBySelectionID = [:]
            subtitleStudioTracks = []
            canOpenSubtitleStudio = false
            subtitlePlaybackSource = nil
            canAdjustSubtitleTiming = false
            subtitleServer.clear()
            return originalAsset
        }
    }

    private func sortSubtitleRenditions(
        _ renditions: [HLSSubtitleRendition]
    ) -> [HLSSubtitleRendition] {
        let primary = SubtitleLanguage.canonicalCode(primarySubtitleLanguage)
        let secondary = SubtitleLanguage.canonicalCode(secondarySubtitleLanguage)

        return renditions.enumerated().sorted { lhs, rhs in
            let left = lhs.element.subtitle
            let right = rhs.element.subtitle

            let leftKey = subtitleSortKey(
                for: left,
                primary: primary,
                secondary: secondary
            )

            let rightKey = subtitleSortKey(
                for: right,
                primary: primary,
                secondary: secondary
            )

            if leftKey.group != rightKey.group {
                return leftKey.group < rightKey.group
            }

            if leftKey.language != rightKey.language {
                return leftKey.language.localizedCaseInsensitiveCompare(
                    rightKey.language
                ) == .orderedAscending
            }

            if leftKey.source != rightKey.source {
                return leftKey.source < rightKey.source
            }

            let providerComparison =
                left.providerName.localizedCaseInsensitiveCompare(
                    right.providerName
                )

            if providerComparison != .orderedSame {
                return providerComparison == .orderedAscending
            }

            let labelComparison =
                left.label.localizedCaseInsensitiveCompare(
                    right.label
                )

            if labelComparison != .orderedSame {
                return labelComparison == .orderedAscending
            }

            // Final stable fallback: preserve the original order.
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    private func subtitleSortKey(
        for subtitle: SubtitleSource,
        primary: String?,
        secondary: String?
    ) -> (
        group: Int,
        language: String,
        source: Int
    ) {
        let languageCode = subtitle.canonicalLanguageCode

        let languageName = SubtitleLanguage.displayName(
            languageCode
        )

        let isBuiltIn =
            subtitle.providerID == "native-hls"
            || subtitle.providerID == "stream"

        let sourceOrder = isBuiltIn ? 0 : 1

        if let primary,
           languageCode == primary {
            return (
                group: 0,
                language: languageName,
                source: sourceOrder
            )
        }

        if let secondary,
           languageCode == secondary {
            return (
                group: 1,
                language: languageName,
                source: sourceOrder
            )
        }

        if isBuiltIn {
            return (
                group: 2,
                language: languageName,
                source: 0
            )
        }

        return (
            group: 3,
            language: languageName,
            source: 1
        )
    }

    private func expandedSubtitleRenditions(
        from baseRenditions: [HLSSubtitleRendition]
    ) -> [HLSSubtitleRendition] {
        baseRenditions.flatMap { rendition in
            let saved = subtitleSyncVersions
                .filter { rendition.subtitle.matchesSyncKey($0.subtitleKey) }
                .sorted { $0.createdAt < $1.createdAt }
                .enumerated()
                .map { index, version in
                    HLSSubtitleRendition(
                        subtitle: rendition.subtitle,
                        cues: rendition.cues,
                        timingOffset: version.offset,
                        syncVersionID: version.id,
                        displayNameOverride: rendition.subtitle.resyncDisplayName(
                            offset: version.offset
                        )
                    )
                }
            return (rendition.subtitle.providerID == "native-hls" ? [] : [rendition]) + saved
        }
    }

    private func selectionID(forSyncVersionID id: UUID) -> String? {
        subtitleRenditionsBySelectionID.first { $0.value.syncVersionID == id }?.key
    }

    private func selectSubtitle(displayName: String?) async {
        guard let item = player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
              player.currentItem === item else { return }
        var selection: AVMediaSelectionOption?
        if let displayName {
            for option in group.options where await subtitleSelectionID(option) == displayName {
                selection = option
                break
            }
        }
        item.select(selection, in: group)
    }

    private func loadSubtitleRenditions(
        _ subtitles: [SubtitleSource]
    ) async -> [HLSSubtitleRendition] {
        let client = subtitleClient
        let maximumConcurrentDownloads = 6

        guard !subtitles.isEmpty else {
            return []
        }

        return await withTaskGroup(
            of: (Int, HLSSubtitleRendition?).self,
            returning: [HLSSubtitleRendition].self
        ) { group in
            var loaded: [(Int, HLSSubtitleRendition)] = []

            let initialCount = min(
                maximumConcurrentDownloads,
                subtitles.count
            )

            func addTask(
                index: Int,
                subtitle: SubtitleSource
            ) {
                group.addTask {
                    do {
                        var request = URLRequest(
                            url: subtitle.url
                        )

                        for (name, value) in subtitle.headers {
                            request.setValue(
                                value,
                                forHTTPHeaderField: name
                            )
                        }

                        request.setValue(
                            "text/plain,text/vtt,application/x-subrip,*/*;q=0.8",
                            forHTTPHeaderField: "Accept"
                        )

                        request.setValue(
                            HTTPClient.desktopUserAgent,
                            forHTTPHeaderField: "User-Agent"
                        )

                        let response =
                            try await SubtitleResourceRetry.load(
                                request: request,
                                client: client
                            )

                        try Task.checkCancellation()

                        let parsedCues =
                            try SubtitleParser.cues(
                                from: response.data,
                                languageCode:
                                    subtitle.languageCode
                            )

                        let cues =
                            SubtitleDirectionFormatter
                                .normalizedCues(
                                    parsedCues,
                                    languageCode:
                                        subtitle.languageCode
                                )

                        return (
                            index,
                            HLSSubtitleRendition(
                                subtitle: subtitle,
                                cues: cues
                            )
                        )
                    } catch {
                        return (
                            index,
                            nil
                        )
                    }
                }
            }

            for index in 0..<initialCount {
                addTask(
                    index: index,
                    subtitle: subtitles[index]
                )
            }

            var nextIndex = initialCount

            while let (
                index,
                rendition
            ) = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return []
                }

                if let rendition {
                    loaded.append(
                        (index, rendition)
                    )
                }

                if nextIndex < subtitles.count {
                    addTask(
                        index: nextIndex,
                        subtitle: subtitles[nextIndex]
                    )

                    nextIndex += 1
                }
            }

            return loaded
                .sorted {
                    $0.0 < $1.0
                }
                .map(\.1)
        }
    }
    private func replaceCurrentItem(
        with asset: AVURLAsset,
        resumeAt: Double,
        shouldPlay: Bool,
        playbackRate: Float,
        preferredSubtitleDisplayName: String? = nil,
        preferredSubtitleSelectionID: String? = nil,
        seekTolerance: CMTime = PlaybackSeekPolicy.normalTolerance
    ) {
        mediaOptionsTask?.cancel()
        let mediaSelectionGeneration = UUID()
        self.mediaSelectionGeneration = mediaSelectionGeneration
        subtitleSelectionAuthority.beginPlayerItem()
        isStabilizingMediaSelection = true
        playbackWasRequested = shouldPlay
        shouldResumeAfterBuffering = false
        // Keep playback behind the media-selection gate. AVPlayer can otherwise
        // begin rendering before its asynchronously loaded subtitle group has
        // received the saved/default selection.
        isPreparingPlayback = shouldPlay
        if isPreparingPlayback { isBuffering = true }
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        applyQuality(to: item)
        observeBufferingState(
            of: item,
            preferredSubtitleDisplayName: preferredSubtitleDisplayName,
            preferredSubtitleSelectionID: preferredSubtitleSelectionID
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
                self.recordSubtitleVisibilityChange(for: item)
                if !self.isStabilizingMediaSelection {
                    self.subtitleSelectionAuthority.recordExplicitUserSelection()
                }
            }
        }
        player.replaceCurrentItem(with: item)
        player.defaultRate = playbackRate
        mediaOptionsTask = Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            defer {
                if self.mediaSelectionGeneration == mediaSelectionGeneration {
                    self.isStabilizingMediaSelection = false
                    self.mediaOptionsTask = nil
                }
            }
            guard await self.waitUntilReadyForMediaSelection(item),
                  !Task.isCancelled,
                  self.mediaSelectionGeneration == mediaSelectionGeneration,
                  self.player.currentItem === item else { return }
            await self.applyPreferredLanguages(
                to: asset,
                primarySubtitleLanguage: self.primarySubtitleLanguage,
                secondarySubtitleLanguage: self.secondarySubtitleLanguage,
                audioLanguage: self.audioLanguage,
                preferredSubtitleDisplayName: preferredSubtitleDisplayName,
                preferredSubtitleSelectionID: preferredSubtitleSelectionID
            )
            // Some HLS manifests publish a forced/default rendition as the item
            // settles. AVPlayer can momentarily restore that choice even with
            // automatic criteria disabled, so reassert our explicit selection
            // after the initial media-selection notification cycle.
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            await self.applyPreferredLanguages(
                to: asset,
                primarySubtitleLanguage: self.primarySubtitleLanguage,
                secondarySubtitleLanguage: self.secondarySubtitleLanguage,
                audioLanguage: self.audioLanguage,
                preferredSubtitleDisplayName: preferredSubtitleDisplayName,
                preferredSubtitleSelectionID: preferredSubtitleSelectionID
            )
            guard !Task.isCancelled,
                  self.mediaSelectionGeneration == mediaSelectionGeneration,
                  self.player.currentItem === item else { return }

            var seekFinished = true
            if resumeAt > 0 {
                seekFinished = await item.seek(
                    to: CMTime(seconds: resumeAt, preferredTimescale: 600),
                    toleranceBefore: seekTolerance,
                    toleranceAfter: seekTolerance
                )
            }
            // Seeking can cause another HLS rendition reconciliation. Selection
            // must be the last preparation step before playback is released.
            await self.applyPreferredLanguages(
                to: asset,
                primarySubtitleLanguage: self.primarySubtitleLanguage,
                secondarySubtitleLanguage: self.secondarySubtitleLanguage,
                audioLanguage: self.audioLanguage,
                preferredSubtitleDisplayName: preferredSubtitleDisplayName,
                preferredSubtitleSelectionID: preferredSubtitleSelectionID
            )
            guard !Task.isCancelled,
                  self.mediaSelectionGeneration == mediaSelectionGeneration,
                  self.player.currentItem === item else { return }
            self.isPreparingPlayback = false
            guard seekFinished, shouldPlay else {
                self.refreshPlaybackState()
                return
            }
            // `play()` deliberately uses `defaultRate`, retaining AVPlayer's
            // automatic wait-for-buffer behavior.
            self.player.play()
            // AVPlayer can re-apply a manifest's forced/default subtitle shortly after
            // playback begins. Reassert Vela's preferred selection a few times while the
            // item settles so late HLS reconciliation cannot leave a forced subtitle active.
            for delay in [250, 500, 1000] {
                do {
                    try await Task.sleep(for: .milliseconds(delay))
                } catch {
                    return
                }

                guard !Task.isCancelled,
                      self.mediaSelectionGeneration == mediaSelectionGeneration,
                      self.player.currentItem === item,
                      self.subtitleSelectionAuthority.allowsAutomaticSelection else {
                    return
                }

                await self.applyPreferredLanguages(
                    to: asset,
                    primarySubtitleLanguage: self.primarySubtitleLanguage,
                    secondarySubtitleLanguage: self.secondarySubtitleLanguage,
                    audioLanguage: self.audioLanguage,
                    preferredSubtitleDisplayName: preferredSubtitleDisplayName,
                    preferredSubtitleSelectionID: preferredSubtitleSelectionID
                )
            }
        }
    }

    private func waitUntilReadyForMediaSelection(_ item: AVPlayerItem) async -> Bool {
        while !Task.isCancelled, player.currentItem === item {
            switch item.status {
            case .readyToPlay:
                return true
            case .failed:
                return false
            default:
                do {
                    try await Task.sleep(for: .milliseconds(25))
                } catch {
                    return false
                }
            }
        }
        return false
    }

    private func observeBufferingState(
        of item: AVPlayerItem,
        preferredSubtitleDisplayName: String?,
        preferredSubtitleSelectionID: String?
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
                        preferredSubtitleSelectionID: preferredSubtitleSelectionID
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
        if let timeJumpedObserver {
            NotificationCenter.default.removeObserver(timeJumpedObserver)
        }
        timeJumpedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemTimeJumped,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item else { return }
                self.beginSeekRecoveryGrace()
                self.refreshPlaybackState()
            }
        }
    }

    private func refreshPlaybackState() {
        if isSourceSwitching {
            playbackState = .preparing
            isBuffering = true
            publishNowPlayingInfo()
            return
        }
        switch player.timeControlStatus {
        case .playing:
            playbackState = .playing
            playbackWasRequested = true
            shouldResumeAfterBuffering = false
            needsSourceRefreshAfterBackground = false
            isBuffering = false
            stagnantBufferChecks = 0
            recoveryWatchdogTask?.cancel()
            recoveryWatchdogTask = nil
        case .waitingToPlayAtSpecifiedRate:
            playbackState = isSeekRecoveryGraceActive ? .seeking : .buffering
            playbackWasRequested = true
            if needsSourceRefreshAfterBackground {
                requestSourceRefresh()
            } else {
                refreshSourceIfExpired()
            }
            scheduleRecoveryWatchdogIfNeeded()
        case .paused:
            if isPreparingPlayback {
                playbackState = .preparing
                playbackWasRequested = true
                isBuffering = true
                publishNowPlayingInfo()
                return
            }
            playbackWasRequested = false
            shouldResumeAfterBuffering = false
            isBuffering = false
            playbackState = .paused
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
        // Initial preparation intentionally keeps the item paused until subtitle
        // and audio selection has completed. An initial empty-buffer callback is
        // not a playback stall and must not bypass that gate.
        guard !isPreparingPlayback else { return }
        playbackWasRequested = true
        shouldResumeAfterBuffering = true
        playbackState = isSeekRecoveryGraceActive ? .seeking : .buffering
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
        guard !isPreparingPlayback else { return }
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
        playbackState = .recovering
        let currentTime = player.currentTime().seconds
        let recovery = playbackSeekState.recoverySnapshot(
            currentPosition: currentTime.isFinite ? currentTime : position,
            fallbackShouldPlay: playbackWasRequested || shouldResumeAfterBuffering,
            fallbackRate: player.rate > 0 ? player.rate : player.defaultRate
        )
        pendingSourceSwitchTime = recovery.position
        pendingSourceSwitchShouldPlay = recovery.shouldPlay
        pendingSourceSwitchRate = recovery.rate
        nextReplacementShouldPlay = recovery.shouldPlay
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

    private var isSeekRecoveryGraceActive: Bool {
        guard let seekRecoveryGraceUntil else { return false }
        return Date() < seekRecoveryGraceUntil
    }

    private func beginSeekRecoveryGrace() {
        playbackState = .seeking
        seekRecoveryGraceUntil = Date().addingTimeInterval(PlaybackRecoveryPolicy.seekGracePeriod)
        stagnantBufferChecks = 0
        recoveryWatchdogTask?.cancel()
        recoveryWatchdogTask = nil
    }

    private func finishSeek() {
        refreshPlaybackState()
        if playbackWasRequested,
           player.timeControlStatus != .playing {
            scheduleRecoveryWatchdogIfNeeded()
        }
    }

    private func scheduleRecoveryWatchdogIfNeeded() {
        guard recoveryWatchdogTask == nil,
              playbackWasRequested,
              player.currentItem != nil else { return }
        lastObservedBufferEnd = bufferedEndTime()
        stagnantBufferChecks = 0
        // AVPlayer has no terminal event for a server that stays connected but
        // stops delivering media. This deliberately long watchdog is only a
        // last-resort detector for that case; ordinary buffering remains under
        // AVPlayer's automatic wait-and-resume control.
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
                    trigger: .stagnantBuffer(
                        checks: self.stagnantBufferChecks,
                        seekGraceActive: self.isSeekRecoveryGraceActive
                    ),
                    sourceRefreshAttempts: self.automaticSourceRefreshAttempts
                ) {
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
        playbackState = .failed
        player.pause()
        playbackErrorMessage = "The video stream stopped responding. Check your connection and try again."
        publishNowPlayingInfo()
    }

    static func expirationDate(in url: URL) -> Date? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let value = query.first(where: { $0.name == "expires" })?.value, let timestamp = TimeInterval(value) {
            return Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp)
        }
        if let token = query.first(where: { $0.name == "token" })?.value?.split(separator: ".").first {
            var payload = String(token).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            if let data = Data(base64Encoded: payload), let text = String(data: data, encoding: .utf8),
               let first = text.split(separator: "|").first, let seconds = TimeInterval(first) {
                return Date(timeIntervalSince1970: seconds)
            }
        }
        return nil
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
        preferredSubtitleSelectionID: String? = nil
    ) async {
        isApplyingPreferredLanguages = true
        defer { isApplyingPreferredLanguages = false }
        let subtitleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
        guard !Task.isCancelled else { return }
        let audioGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
        guard !Task.isCancelled, player.currentItem?.asset === asset else { return }

        var embeddedSubtitle: AVMediaSelectionOption?
        if let subtitleGroup {
            for option in subtitleGroup.options {
                let identity = await subtitleSelectionID(option)
                if identity == preferredSubtitleSelectionID || identity == preferredSubtitleDisplayName {
                    embeddedSubtitle = option
                    break
                }
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
            if embeddedSubtitle == nil {
                embeddedSubtitle = await preferredOption(
                    in: nativeOptions, languageCodes: [primarySubtitleLanguage]
                )
            }
            if embeddedSubtitle == nil {
                embeddedSubtitle = await preferredOption(
                    in: injectedOptions, languageCodes: [primarySubtitleLanguage]
                )
            }
            if embeddedSubtitle == nil {
                embeddedSubtitle = await preferredOption(
                    in: nativeOptions, languageCodes: [secondarySubtitleLanguage]
                )
            }
            if embeddedSubtitle == nil {
                embeddedSubtitle = await preferredOption(
                    in: injectedOptions, languageCodes: [secondarySubtitleLanguage]
                )
            }
        }
        if preferredSubtitleSelectionID == "__subtitles_off__" { embeddedSubtitle = nil }
        if let subtitleGroup {
            player.currentItem?.select(embeddedSubtitle, in: subtitleGroup)
            subtitleVisibilityBaseline = embeddedSubtitle != nil
            if let embeddedSubtitle {
                canAdjustSubtitleTiming = await isInjectedSubtitleOption(embeddedSubtitle)
            } else {
                canAdjustSubtitleTiming = false
            }
        } else {
            canAdjustSubtitleTiming = false
        }
        if let item = player.currentItem, item.asset === asset {
            refreshSubtitleTimingAvailability(for: item)
        }
        if let audioGroup {
            let audio = await preferredOption(in: audioGroup.options, languageCodes: [audioLanguage, "en"])
            if let audio { player.currentItem?.select(audio, in: audioGroup) }
        }
    }

    private func recordSubtitleVisibilityChange(for item: AVPlayerItem) {
        guard !isApplyingPreferredLanguages, !isStabilizingMediaSelection else { return }
        Task { [weak self, weak item] in
            guard let self, let item,
                  let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  self.player.currentItem === item else { return }
            let isEnabled = item.currentMediaSelection.selectedMediaOption(in: group) != nil
            guard self.subtitleVisibilityBaseline != isEnabled else { return }
            self.subtitleVisibilityBaseline = isEnabled
            self.onSubtitleVisibilityChanged?(isEnabled)
        }
    }

    private func reapplyPreferredLanguagesIfNeeded(
        to item: AVPlayerItem,
        preferredSubtitleDisplayName: String?,
        preferredSubtitleSelectionID: String?
    ) {
        // The initial task owns the readiness/selection/playback sequence. If
        // readiness arrives while it is active, that task will apply the final
        // selection itself and must not be cancelled by this observation.
        guard mediaOptionsTask == nil,
              subtitleSelectionAuthority.allowsAutomaticSelection else { return }
        mediaOptionsTask?.cancel()
        mediaOptionsTask = Task { [weak self, weak item] in
            guard let self, let item, self.player.currentItem === item else { return }
            await self.applyPreferredLanguages(
                to: item.asset,
                primarySubtitleLanguage: self.primarySubtitleLanguage,
                secondarySubtitleLanguage: self.secondarySubtitleLanguage,
                audioLanguage: self.audioLanguage,
                preferredSubtitleDisplayName: preferredSubtitleDisplayName,
                preferredSubtitleSelectionID: preferredSubtitleSelectionID
            )
        }
    }

    private func selectedSubtitleDisplayName() async -> String? {
        guard let item = player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
              player.currentItem === item else { return nil }
        guard let option = item.currentMediaSelection.selectedMediaOption(in: group) else { return nil }
        return await subtitleSelectionID(option)
    }

    private func logSubtitleDiagnostics(at playerTime: Double) async {
        guard let item = player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
              player.currentItem === item else {
            SubtitleDiagnostics.logger.notice("SUBSYNC player: no legible media-selection group")
            return
        }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        SubtitleDiagnostics.logger.notice(
            "SUBSYNC player: time=\(playerTime, privacy: .public) optionCount=\(group.options.count, privacy: .public)"
        )
        for (index, option) in group.options.enumerated() {
            let isSelected = selected.map { option == $0 } ?? false
            let identity = await subtitleSelectionID(option)
            let title = await subtitleTitle(option) ?? "none"
            let languageTag = option.extendedLanguageTag ?? "none"
            let rendition = subtitleRenditionsBySelectionID[identity]
                ?? subtitleRenditionsByDisplayName[identity]
            let sourceTime = playerTime - (rendition?.timingOffset ?? 0)
            let cue = rendition?.cues.first {
                $0.startTime <= sourceTime && sourceTime < $0.endTime
            }
            SubtitleDiagnostics.logger.notice(
                "SUBSYNC option[\(index, privacy: .public)]: selected=\(isSelected, privacy: .public) identity=\(identity, privacy: .public) tag=\(languageTag, privacy: .public) display=\(option.displayName, privacy: .public) title=\(title, privacy: .public) provider=\(rendition?.subtitle.providerID ?? "unmapped", privacy: .public) label=\(rendition?.subtitle.label ?? "unmapped", privacy: .public) offset=\(rendition?.timingOffset ?? -999, privacy: .public) cueStart=\(cue?.startTime ?? -1, privacy: .public) cueEnd=\(cue?.endTime ?? -1, privacy: .public)"
            )
        }
    }

    private func subtitleTitle(_ option: AVMediaSelectionOption) async -> String? {
        for item in option.commonMetadata where item.commonKey == .commonKeyTitle {
            if let title = try? await item.load(.stringValue), !title.isEmpty { return title }
        }
        return nil
    }

    private func selectedSubtitleSelectionID() async -> String? {
        guard let item = player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
              player.currentItem === item else { return nil }
        guard let option = item.currentMediaSelection.selectedMediaOption(in: group) else { return nil }
        return await subtitleSelectionID(option)
    }

    private func refreshSubtitleTimingAvailability(for item: AVPlayerItem) {
        Task { [weak self, weak item] in
            guard let self, let item,
                  let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  self.player.currentItem === item else { return }
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            if let selected {
                self.canAdjustSubtitleTiming = await self.isInjectedSubtitleOption(selected)
                let selectionID = await self.subtitleSelectionID(selected)
                let rendition = self.subtitleRenditionsBySelectionID[selectionID]
                    ?? self.subtitleRenditionsByDisplayName[selectionID]
                SubtitleDiagnostics.logger.notice(
                    "SUBSYNC selected: selectionID=\(selectionID, privacy: .public) provider=\(rendition?.subtitle.providerID ?? "native", privacy: .public)"
                )
            } else {
                self.canAdjustSubtitleTiming = false
                SubtitleDiagnostics.logger.notice(
                    "SUBSYNC selected: selectionID=off provider=none"
                )
            }
        }
    }

    private func subtitleSelectionID(_ option: AVMediaSelectionOption) async -> String {
        if let title = await subtitleTitle(option) { return title }
        return option.displayName
    }

    private func isInjectedSubtitleOption(_ option: AVMediaSelectionOption) async -> Bool {
        return injectedSubtitleNames.contains(await subtitleSelectionID(option))
    }

    private func preferredOption(
        in options: [AVMediaSelectionOption],
        languageCodes: [String]
    ) async -> AVMediaSelectionOption? {
        var matchingForcedOption: AVMediaSelectionOption?
        for code in languageCodes where !code.isEmpty {
            guard let preferredLanguage = SubtitleLanguage.canonicalCode(code) else { continue }
            var matches: [AVMediaSelectionOption] = []
            for option in options {
                let selectionID = await subtitleSelectionID(option)
                let renditionLanguage = (subtitleRenditionsBySelectionID[selectionID]
                    ?? subtitleRenditionsByDisplayName[selectionID])?.subtitle.canonicalLanguageCode
                let tags = [option.extendedLanguageTag, option.locale?.identifier]
                    .compactMap { SubtitleLanguage.canonicalCode($0) }
                if renditionLanguage == preferredLanguage || tags.contains(preferredLanguage) {
                    matches.append(option)
                }
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
        seekForPlayback(to: position)
    }

    /// Performs an ordinary playback seek. AVPlayer remains responsible for
    /// fetching HLS segments; this only serializes user intent so stale seek
    /// completions cannot restore an older position or play/pause state.
    func seekForPlayback(to position: TimeInterval) {
        guard let item = player.currentItem, position.isFinite else { return }
        let shouldPlay = player.rate > 0 || player.timeControlStatus != .paused
        let rate = player.rate > 0 ? player.rate : player.defaultRate
        let request = playbackSeekState.begin(
            target: max(0, position),
            shouldPlay: shouldPlay,
            rate: rate
        )
        if sourceRefreshTask != nil || nextReplacementShouldPlay != nil {
            pendingSourceSwitchTime = request.target
            pendingSourceSwitchShouldPlay = request.shouldPlay
            pendingSourceSwitchRate = request.rate
            nextReplacementShouldPlay = request.shouldPlay
        }
        playbackWasRequested = shouldPlay
        shouldResumeAfterBuffering = shouldPlay
        beginSeekRecoveryGrace()
        item.cancelPendingSeeks()
        player.seek(
            to: CMTime(seconds: request.target, preferredTimescale: 600),
            toleranceBefore: PlaybackSeekPolicy.normalTolerance,
            toleranceAfter: PlaybackSeekPolicy.normalTolerance
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self,
                      let completed = self.playbackSeekState.complete(request.id, finished: finished) else { return }
                if completed.shouldPlay {
                    self.player.playImmediately(atRate: completed.rate)
                } else {
                    self.player.pause()
                }
                self.finishSeek()
                self.publishNowPlayingInfo()
            }
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
        subtitleRenditionsBySelectionID = [:]
        subtitleStudioTracks = []
        subtitlePlaybackSource = nil
        canAdjustSubtitleTiming = false
        canOpenSubtitleStudio = false
    }
}

enum PlaybackSessionState: Equatable, Sendable {
    case idle
    case preparing
    case playing
    case paused
    case seeking
    case buffering
    case recovering
    case failed
}

enum PlaybackSeekPolicy {
    // Normal HLS playback benefits from keyframe/segment-aligned seeks. Subtitle
    // Studio continues to use zero tolerance in its separate seek path.
    static let normalTolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
}

struct PlaybackSeekRequest: Equatable, Sendable {
    let id: UInt64
    let target: TimeInterval
    let shouldPlay: Bool
    let rate: Float
}

struct PlaybackSeekRecoverySnapshot: Equatable, Sendable {
    let position: TimeInterval
    let shouldPlay: Bool
    let rate: Float
}

struct PlaybackSeekState: Sendable {
    private(set) var latestRequest: PlaybackSeekRequest?
    private var nextID: UInt64 = 0

    mutating func begin(target: TimeInterval, shouldPlay: Bool, rate: Float) -> PlaybackSeekRequest {
        nextID &+= 1
        let request = PlaybackSeekRequest(
            id: nextID,
            target: target,
            shouldPlay: shouldPlay,
            rate: rate.isFinite && rate > 0 ? rate : 1
        )
        latestRequest = request
        return request
    }

    mutating func complete(_ id: UInt64, finished: Bool) -> PlaybackSeekRequest? {
        guard finished, latestRequest?.id == id else { return nil }
        let completed = latestRequest
        latestRequest = nil
        return completed
    }

    func recoverySnapshot(
        currentPosition: TimeInterval,
        fallbackShouldPlay: Bool,
        fallbackRate: Float
    ) -> PlaybackSeekRecoverySnapshot {
        if let latestRequest {
            return .init(
                position: latestRequest.target,
                shouldPlay: latestRequest.shouldPlay,
                rate: latestRequest.rate
            )
        }
        return .init(
            position: max(0, currentPosition),
            shouldPlay: fallbackShouldPlay,
            rate: fallbackRate.isFinite && fallbackRate > 0 ? fallbackRate : 1
        )
    }

    mutating func reset() {
        latestRequest = nil
    }
}

enum PlaybackRecoveryTrigger: Equatable, Sendable {
    case stagnantBuffer(checks: Int, seekGraceActive: Bool)
    case fatalPlaybackError
}

enum PlaybackRecoveryAction: Equatable, Sendable {
    case keepWaiting
    case refreshSource
    case fail
}

enum PlaybackRecoveryPolicy {
    static let watchdogInterval: Duration = .seconds(10)
    static let minimumBufferGrowth = 0.5
    static let seekGracePeriod: TimeInterval = 15
    static let stagnantChecksBeforeRecovery = 6
    static let maximumSourceRefreshes = 3

    static func action(
        trigger: PlaybackRecoveryTrigger,
        sourceRefreshAttempts: Int
    ) -> PlaybackRecoveryAction {
        switch trigger {
        case .fatalPlaybackError:
            return sourceRefreshAttempts >= maximumSourceRefreshes ? .fail : .refreshSource
        case let .stagnantBuffer(checks, seekGraceActive):
            guard !seekGraceActive,
                  checks >= stagnantChecksBeforeRecovery else { return .keepWaiting }
            return sourceRefreshAttempts >= maximumSourceRefreshes ? .fail : .refreshSource
        }
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

actor HLSPlaylistInspector {
    private let client: any HTTPClientProtocol

    init(client: any HTTPClientProtocol = HTTPClient()) {
        self.client = client
    }

    func availableQualities(for source: PlaybackSource) async -> [StreamQuality] {
        guard source.url.pathExtension.lowercased() != "mp4" else { return [] }
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
    let streams: [PlayableStream]
    let selectedSourceID: String?
    let automaticSource: Bool
    let isSearchingForSources: Bool
    let onSourceChanged: (String?, StreamQuality?) -> Void
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
        // PlayerScreen is already presented as a full-screen cover. Letting
        // AVKit present another full-screen layer causes a second close step
        // after replacing an item during a source switch.
        controller.entersFullScreenWhenPlaybackBegins = false
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
        context.coordinator.updateSources(streams, selectedID: selectedSourceID,
            automatic: automaticSource, isSearching: isSearchingForSources, onChanged: onSourceChanged)
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
        private var streams: [PlayableStream] = []
        private var selectedSourceID: String?
        private var automaticSource = true
        private var isSearchingForSources = false
        private var sourceMenuSignature = ""
        private var onSourceChanged: ((String?, StreamQuality?) -> Void)?
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
            configurePlaybackErrorView()
            settingsButton.translatesAutoresizingMaskIntoConstraints = false
            settingsButton.showsMenuAsPrimaryAction = true
            settingsButton.accessibilityLabel = "Playback settings"
            configureSubtitleTimingControl()
            attachControls(to: overlay)
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

        private func attachControls(to overlay: UIView) {
            guard settingsButton.superview !== overlay else { return }
            bufferingIndicator.removeFromSuperview()
            playbackErrorView.removeFromSuperview()
            settingsButton.removeFromSuperview()
            subtitleTimingControl.removeFromSuperview()
            overlay.addSubview(bufferingIndicator)
            overlay.addSubview(playbackErrorView)
            overlay.addSubview(settingsButton)
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
        }

        func updateZoomPreference(_ isZoomedToFill: Bool, in controller: AVPlayerViewController) {
            guard prefersZoomedToFill != isZoomedToFill else { return }
            prefersZoomedToFill = isZoomedToFill
            applyZoomPreference(in: controller)
        }

        func playerViewDidLayout(_ controller: AVPlayerViewController) {
            if let overlay = controller.contentOverlayView {
                attachControls(to: overlay)
            }
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

        func updateSources(_ streams: [PlayableStream], selectedID: String?, automatic: Bool, isSearching: Bool,
                           onChanged: @escaping (String?, StreamQuality?) -> Void) {
            onSourceChanged = onChanged
            self.streams = streams
            selectedSourceID = selectedID
            automaticSource = automatic
            isSearchingForSources = isSearching
            let signature = streams.map { $0.id + $0.label + $0.qualities.map(\.title).joined() }.joined()
                + (selectedID ?? "") + String(automatic) + String(isSearching)
            guard signature != sourceMenuSignature else { return }
            sourceMenuSignature = signature
            rebuildSettingsMenu()
            showSettingsButton()
        }

        private func rebuildSettingsMenu() {
            let hasSettings = !streams.isEmpty || !availableQualities.isEmpty || subtitleTimingAvailable
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

            settingsButton.accessibilityLabel = "Source & Quality"
            let accessibilitySource: String

            if automaticSource {
                accessibilitySource = "Automatic"
            } else if let selectedSourceID,
                      let stream = streams.first(
                        where: { $0.id == selectedSourceID }
                      ) {
                accessibilitySource =
                    stream.candidate.providerName
            } else {
                accessibilitySource = "Automatic"
            }

            settingsButton.accessibilityValue =
                "\(accessibilitySource), \(selectedQuality?.title ?? "Auto quality")"
            var sections: [UIMenuElement] = []
            if !streams.isEmpty {
                let activeStream = selectedSourceID.flatMap { id in
                    streams.first { $0.id == id }
                }

                let activeSourceName = activeStream?.candidate.providerName
                    ?? "Unknown source"

                let activeQualityText = selectedQuality?.title
                    ?? activeStream?.candidate.displayMetadata?.quality
                    ?? "Auto"

                let automaticSubtitle: String

                if automaticSource {
                    automaticSubtitle =
                        "Best available • Playing: \(activeSourceName) • \(activeQualityText)"
                } else {
                    automaticSubtitle = "Choose the best available source automatically"
                }

                var sources: [UIMenuElement] = [
                    UIAction(
                        title: "Automatic",
                        subtitle: automaticSubtitle,
                        image: UIImage(systemName: "wand.and.stars"),
                        state: automaticSource ? .on : .off
                    ) { [weak self] _ in
                        self?.onSourceChanged?(nil, nil)
                    }
                ]

                for stream in streams {
                    let active = selectedSourceID == stream.id

                    let sourceName = stream.candidate.providerName

                    var metadata: [String] = []

                    if let quality = stream.candidate.displayMetadata?.quality {
                        metadata.append(quality)
                    }

                    if let container = stream.candidate.displayMetadata?.container {
                        metadata.append(container.uppercased())
                    }

                    if let size = stream.candidate.displayMetadata?.sizeBytes {
                        metadata.append(
                            ByteCountFormatter.string(
                                fromByteCount: size,
                                countStyle: .file
                            )
                        )
                    }

                    if active {
                        metadata.insert("Playing", at: 0)
                    }

                    let subtitle = metadata.isEmpty
                        ? stream.label
                        : metadata.joined(separator: " • ")

                    let qualities = active
                        ? availableQualities
                        : stream.qualities

                    if qualities.isEmpty {
                        sources.append(
                            UIAction(
                                title: sourceName,
                                subtitle: subtitle,
                                image: active
                                    ? UIImage(systemName: "play.fill")
                                    : UIImage(systemName: "play.circle"),
                                state: active && !automaticSource ? .on : .off
                            ) { [weak self] _ in
                                self?.onSourceChanged?(stream.id, nil)
                            }
                        )
                    } else {
                        let choices: [StreamQuality?] =
                            [nil]
                            + qualities
                                .reversed()
                                .map { Optional($0) }

                        let actions = choices.map { quality in
                            UIAction(
                                title: quality?.title ?? "Auto",
                                state:
                                    active
                                    && !automaticSource
                                    && quality == selectedQuality
                                        ? .on
                                        : .off
                            ) { [weak self] _ in
                                self?.onSourceChanged?(
                                    stream.id,
                                    quality
                                )
                            }
                        }

                        sources.append(
                            UIMenu(
                                title: sourceName,
                                subtitle: subtitle,
                                image: active
                                    ? UIImage(systemName: "play.fill")
                                    : UIImage(systemName: "play.circle"),
                                children: actions
                            )
                        )
                    }
                }

                if isSearchingForSources {
                    sources.append(
                        UIAction(
                            title: "Searching for more sources…",
                            subtitle: "New sources will appear automatically",
                            image: UIImage(systemName: "magnifyingglass"),
                            attributes: [.disabled]
                        ) { _ in }
                    )
                }

                sections.append(
                    UIMenu(
                        title: "Source & Quality",
                        image: UIImage(systemName: "video"),
                        children: sources
                    )
                )
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
            guard !streams.isEmpty
                    || !availableQualities.isEmpty
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
