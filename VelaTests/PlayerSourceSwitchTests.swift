import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import Vela

@Suite("Native player source switching", .serialized)
struct PlayerSourceSwitchTests {
    @MainActor
    @Test("A source switch preserves position, playback state and speed", arguments: [false, true])
    func preservesPlayback(playing: Bool) async throws {
        let video = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        let source = PlaybackSource(url: video, headers: [:], subtitles: [], preferredPeakBitRate: nil)
        let session = PlayerSession()
        defer { session.stop() }
        await session.load(request: PlaybackDiscoveryTests.request, source: source, resumeAt: 0,
            primarySubtitleLanguage: "en", secondarySubtitleLanguage: "", audioLanguage: "en",
            externalSubtitles: [], subtitleSyncVersions: [], automaticallySelectLatestSubtitleSync: true,
            subtitlesEnabled: true,
            defaultQualityHeight: 0, defaultPlaybackRate: 1.5)
        try await waitReady(session.player)
        session.player.pause()
        await session.player.seek(to: CMTime(seconds: 1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try await Task.sleep(for: .milliseconds(100))
        if playing { session.player.playImmediately(atRate: 1.5) }
        let candidate = PlaybackCandidate(id: "replacement", preference: .init(providerID: "test", serverName: "HD", audioLanguage: "en"), providerName: "Test", subtitleKind: .selectable, resolve: { source })
        #expect(await session.switchSource(.init(candidate: candidate, source: source, qualities: []), externalSubtitles: []))
        try await waitReady(session.player)
        try await Task.sleep(for: .milliseconds(150))
        #expect(playing ? session.player.rate > 0 : session.player.timeControlStatus == .paused)
        #expect(abs(session.player.currentTime().seconds - 1) < (playing ? 1 : 0.2))
        #expect(session.player.defaultRate == 1.5)
    }

    @MainActor
    @Test("An invalid replacement leaves the current player item intact")
    func failedSwitch() async throws {
        let video = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        let source = PlaybackSource(url: video, headers: [:], subtitles: [], preferredPeakBitRate: nil)
        let session = PlayerSession()
        defer { session.stop() }
        await session.load(request: PlaybackDiscoveryTests.request, source: source, resumeAt: 0,
            primarySubtitleLanguage: "en", secondarySubtitleLanguage: "", audioLanguage: "en",
            externalSubtitles: [], subtitleSyncVersions: [], automaticallySelectLatestSubtitleSync: true,
            subtitlesEnabled: true,
            defaultQualityHeight: 0, defaultPlaybackRate: 1)
        try await waitReady(session.player)
        session.player.pause()
        let originalItem = session.player.currentItem
        let bad = PlaybackSource(url: video.deletingLastPathComponent().appending(path: "missing-\(UUID()).mp4"), headers: [:], subtitles: [], preferredPeakBitRate: nil)
        let candidate = PlaybackCandidate(id: "bad", preference: .init(providerID: "test", serverName: "bad", audioLanguage: "en"), providerName: "Test", subtitleKind: .selectable, resolve: { bad })
        #expect(!(await session.switchSource(.init(candidate: candidate, source: bad, qualities: []), externalSubtitles: [])))
        #expect(session.player.currentItem === originalItem)
        #expect(session.player.timeControlStatus == .paused)
    }

    @MainActor
    private func waitReady(_ player: AVPlayer) async throws {
        for _ in 0..<100 {
            if player.currentItem?.status == .readyToPlay { return }
            if player.currentItem?.status == .failed { throw AppError.noStream }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AppError.noStream
    }

    private func makeVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "source-switch-\(UUID()).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        guard writer.startWriting() else { throw AppError.noStream }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<40 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw AppError.noStream }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, Int32(frame * 4), CVPixelBufferGetDataSize(buffer)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else { throw AppError.noStream }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw AppError.noStream }
        return url
    }
}
