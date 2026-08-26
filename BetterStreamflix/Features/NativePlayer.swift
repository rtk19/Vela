@preconcurrency import AVKit
import Combine
import SwiftUI

@MainActor
final class PlayerSession: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var availableQualities: [StreamQuality] = []
    @Published private(set) var selectedQuality: StreamQuality?

    var onEnded: (() -> Void)?
    nonisolated(unsafe) private var timeObserver: Any?
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    private var mediaOptionsTask: Task<Void, Never>?
    private var currentAsset: AVURLAsset?
    private var primarySubtitleLanguage = ""
    private var secondarySubtitleLanguage = ""
    private var audioLanguage = "en"
    private let playlistInspector = HLSPlaylistInspector()
    private let audioSessionController = AudioSessionController()

    init() {
        player.allowsExternalPlayback = true
        player.appliesMediaSelectionCriteriaAutomatically = false
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                let value = self.player.currentItem?.duration.seconds ?? 0
                self.duration = value.isFinite ? value : 0
            }
        }
    }

    deinit {
        mediaOptionsTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func load(
        source: PlaybackSource,
        resumeAt: Double,
        primarySubtitleLanguage: String,
        secondarySubtitleLanguage: String,
        audioLanguage: String,
        defaultQualityHeight: Int,
        defaultPlaybackRate: Float
    ) async {
        await audioSessionController.activateForPlayback()
        guard !Task.isCancelled else { return }
        mediaOptionsTask?.cancel()
        let preparedSource = source.preferredForSubtitleLanguage(primarySubtitleLanguage)
        let qualities = await playlistInspector.availableQualities(for: preparedSource)
        guard !Task.isCancelled else { return }
        availableQualities = qualities
        selectedQuality = Self.closestQuality(to: defaultQualityHeight, in: qualities)
        self.primarySubtitleLanguage = primarySubtitleLanguage
        self.secondarySubtitleLanguage = secondarySubtitleLanguage
        self.audioLanguage = audioLanguage
        let asset = AVURLAsset(
            url: preparedSource.url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": preparedSource.headers]
        )
        currentAsset = asset
        player.defaultRate = defaultPlaybackRate
        replaceCurrentItem(
            with: asset,
            resumeAt: resumeAt,
            shouldPlay: true,
            playbackRate: defaultPlaybackRate
        )
    }

    func stop() {
        player.pause()
        Task { [audioSessionController] in
            await audioSessionController.deactivate()
        }
    }

    func resetProgressTracking() {
        position = 0
        duration = 0
    }

    func setQuality(_ quality: StreamQuality?) {
        guard selectedQuality != quality else { return }
        selectedQuality = quality
        guard let asset = currentAsset else { return }
        let resumeAt = player.currentTime().seconds.isFinite ? player.currentTime().seconds : position
        let wasPlaying = player.rate != 0
        let playbackRate = wasPlaying ? player.rate : player.defaultRate
        replaceCurrentItem(
            with: asset,
            resumeAt: resumeAt,
            shouldPlay: wasPlaying,
            playbackRate: playbackRate
        )
    }

    private func replaceCurrentItem(
        with asset: AVURLAsset,
        resumeAt: Double,
        shouldPlay: Bool,
        playbackRate: Float
    ) {
        mediaOptionsTask?.cancel()
        let item = AVPlayerItem(asset: asset)
        applyQuality(to: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnded?() }
        }
        player.replaceCurrentItem(with: item)
        if resumeAt > 0 {
            item.seek(
                to: CMTime(seconds: resumeAt, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero,
                completionHandler: { _ in }
            )
        }
        mediaOptionsTask = Task { [weak self] in
            guard let self else { return }
            await self.applyPreferredLanguages(
                to: asset,
                primarySubtitleLanguage: self.primarySubtitleLanguage,
                secondarySubtitleLanguage: self.secondarySubtitleLanguage,
                audioLanguage: self.audioLanguage
            )
        }
        if shouldPlay { player.playImmediately(atRate: playbackRate) }
    }

    private static func closestQuality(
        to preferredHeight: Int,
        in qualities: [StreamQuality]
    ) -> StreamQuality? {
        guard preferredHeight > 0 else { return nil }
        return qualities.last(where: { $0.height <= preferredHeight }) ?? qualities.first
    }

    private func applyPreferredLanguages(
        to asset: AVAsset,
        primarySubtitleLanguage: String,
        secondarySubtitleLanguage: String,
        audioLanguage: String
    ) async {
        let subtitleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
        guard !Task.isCancelled else { return }
        let audioGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
        guard !Task.isCancelled, player.currentItem?.asset === asset else { return }

        if let subtitleGroup {
            let subtitle = preferredOption(
                in: subtitleGroup,
                languageCodes: [primarySubtitleLanguage, secondarySubtitleLanguage]
            )
            player.currentItem?.select(subtitle, in: subtitleGroup)
        }
        if let audioGroup {
            let audio = preferredOption(in: audioGroup, languageCodes: [audioLanguage, "en"])
            if let audio { player.currentItem?.select(audio, in: audioGroup) }
        }
    }

    private func preferredOption(
        in group: AVMediaSelectionGroup,
        languageCodes: [String]
    ) -> AVMediaSelectionOption? {
        var matchingForcedOption: AVMediaSelectionOption?
        for code in languageCodes where !code.isEmpty {
            let identifiers = languageIdentifiers(for: code)
            let matches = group.options.filter { option in
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

    private func applyQuality(to item: AVPlayerItem) {
        guard let selectedQuality else {
            item.preferredPeakBitRate = 0
            item.preferredMaximumResolution = .zero
            return
        }
        item.preferredPeakBitRate = selectedQuality.peakBitRate * 1.02
        item.preferredMaximumResolution = CGSize(
            width: selectedQuality.width,
            height: selectedQuality.height
        )
    }
}

struct StreamQuality: Identifiable, Hashable, Sendable {
    let width: Int
    let height: Int
    let peakBitRate: Double

    var id: Int { height }
    var title: String { "\(height)p" }
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
        guard !isActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            try session.setActive(true)
            isActive = true
        } catch {
            isActive = false
        }
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

struct NativePlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    let availableQualities: [StreamQuality]
    let selectedQuality: StreamQuality?
    let onQualityChanged: (StreamQuality?) -> Void
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            availableQualities: availableQualities,
            selectedQuality: selectedQuality,
            onQualityChanged: onQualityChanged,
            onDismiss: onDismiss
        )
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = context.coordinator
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.entersFullScreenWhenPlaybackBegins = true
        context.coordinator.installQualityButton(in: controller)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        context.coordinator.updateQualities(
            availableQualities,
            selectedQuality: selectedQuality
        )
    }

    @MainActor
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        private let qualityButton = UIButton(type: .system)
        private var availableQualities: [StreamQuality]
        private var selectedQuality: StreamQuality?
        private let onQualityChanged: (StreamQuality?) -> Void
        private var hideTask: Task<Void, Never>?
        let onDismiss: () -> Void

        init(
            availableQualities: [StreamQuality],
            selectedQuality: StreamQuality?,
            onQualityChanged: @escaping (StreamQuality?) -> Void,
            onDismiss: @escaping () -> Void
        ) {
            self.availableQualities = availableQualities
            self.selectedQuality = selectedQuality
            self.onQualityChanged = onQualityChanged
            self.onDismiss = onDismiss
        }

        func installQualityButton(in controller: AVPlayerViewController) {
            guard let overlay = controller.contentOverlayView else { return }
            qualityButton.translatesAutoresizingMaskIntoConstraints = false
            qualityButton.showsMenuAsPrimaryAction = true
            qualityButton.accessibilityLabel = "Video quality"
            qualityButton.alpha = 0.86
            overlay.addSubview(qualityButton)
            NSLayoutConstraint.activate([
                qualityButton.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -14),
                qualityButton.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                qualityButton.widthAnchor.constraint(equalToConstant: 38),
                qualityButton.heightAnchor.constraint(equalToConstant: 38)
            ])
            updateQuality(qualityLimit)
        }

        func updateQuality(_ quality: QualityLimit) {
            qualityLimit = quality
            var configuration = UIButton.Configuration.gray()
            configuration.cornerStyle = .capsule
            configuration.image = UIImage(systemName: "slider.horizontal.3")
            configuration.baseForegroundColor = .white
            qualityButton.configuration = configuration
            qualityButton.accessibilityValue = quality.rawValue
            qualityButton.menu = UIMenu(
                title: "Video Quality",
                children: QualityLimit.allCases.map { option in
                    UIAction(
                        title: option.rawValue,
                        state: option == quality ? .on : .off
                    ) { [weak self] _ in
                        self?.onQualityChanged(option)
                    }
                }
            )
        }

        func playerViewControllerWillEndFullScreenPresentation(
            _ playerViewController: AVPlayerViewController,
            withAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            coordinator.animate(alongsideTransition: nil) { [onDismiss] _ in onDismiss() }
        }
    }
}
