import AVFoundation
import Foundation
import Testing
@testable import Vela

/// Explicit opt-in because third-party availability is not a deterministic CI dependency.
/// TEST_RUNNER_VELA_LIVE_STREAMS=1 xcodebuild ... -only-testing:VelaTests/AnimeLivePlaybackTests test
@Suite("Live anime playback", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VELA_LIVE_STREAMS"] == "1"))
struct AnimeLivePlaybackTests {
    @MainActor
    @Test(arguments: [AnimePlaybackProvider.Site.hiAnime, .anikoto])
    func movie(_ site: AnimePlaybackProvider.Site) async throws {
        let media = MediaItem(id: "372058", providerID: "tmdb", kind: .movie, title: "Your Name.", originalTitle: "君の名は。", releaseDate: "2016-08-26", tmdbID: 372058, genres: [.init(id: "16", name: "Animation")])
        var context = PlaybackLookupContext(request: .init(media: media, episode: nil))
        context.alternativeTitles = ["Your Name", "Kimi no Na wa."]
        try await verify(site, context: context)
    }

    @MainActor
    @Test(arguments: [AnimePlaybackProvider.Site.hiAnime, .anikoto])
    func series(_ site: AnimePlaybackProvider.Site) async throws {
        let media = MediaItem(id: "37854", providerID: "tmdb", kind: .series, title: "One Piece", originalTitle: "ワンピース", releaseDate: "1999-10-20", tmdbID: 37854, genres: [.init(id: "16", name: "Animation")])
        let episode = MediaEpisode(id: "1", providerID: "tmdb", showID: media.id, seasonNumber: 1, number: 1, title: "I'm Luffy! The Man Who's Gonna Be King of the Pirates!", overview: nil, posterURL: nil)
        try await verify(site, context: .init(request: .init(media: media, episode: episode)))
    }

    @MainActor
    @Test(arguments: [AnimePlaybackProvider.Site.hiAnime, .anikoto])
    func laterSeason(_ site: AnimePlaybackProvider.Site) async throws {
        let media = MediaItem(id: "127532", providerID: "tmdb", kind: .series, title: "Solo Leveling", releaseDate: "2024-01-07", tmdbID: 127532, genres: [.init(id: "16", name: "Animation")])
        let episode = MediaEpisode(id: "s2e1", providerID: "tmdb", showID: media.id, seasonNumber: 2, number: 1, title: "You Aren't E-Rank, Are You?", overview: nil, posterURL: nil)
        var context = PlaybackLookupContext(request: .init(media: media, episode: episode))
        context.seasonYear = 2025
        context.seasonEpisodeCount = 13
        try await verify(site, context: context)
    }

    @MainActor
    @Test(arguments: [AnimePlaybackProvider.Site.hiAnime, .anikoto])
    func continuousSeason(_ site: AnimePlaybackProvider.Site) async throws {
        let client = TMDBClient()
        let token = try #require(Bundle.main.object(forInfoDictionaryKey: "TMDBReadAccessToken") as? String)
        let media = MediaItem(id: "37854", providerID: "tmdb", kind: .series, title: "One Piece", originalTitle: "ワンピース", releaseDate: "1999-10-20", tmdbID: 37854, genres: [.init(id: "16", name: "Animation")])
        let episodes = try await client.episodes(for: .init(id: "2", number: 2, title: nil, posterURL: nil), show: media, accessToken: token)
        let episode = try #require(episodes.first)
        let context = try await client.playbackContext(for: .init(media: media, episode: episode), accessToken: token)
        #expect(context.absoluteEpisodeNumber == episode.number)
        try await verify(site, context: context)
    }

    @MainActor
    private func verify(_ site: AnimePlaybackProvider.Site, context: PlaybackLookupContext) async throws {
        let candidates = try await AnimePlaybackProvider(site: site).candidates(for: context)
        #expect(!candidates.isEmpty, "\(site.rawValue): no verified matching servers for \(context.request.media.title)")
        #expect(candidates.contains { $0.preference.audioLanguage == "ja" })
        try await verifyCandidates(candidates, providerID: site.rawValue)
    }

    @MainActor
    @Test("The existing StreamingCommunity resolution path still plays")
    func streamingCommunity() async throws {
        let media = MediaItem(id: "603", providerID: "tmdb", kind: .movie, title: "The Matrix", releaseDate: "1999-03-31", tmdbID: 603)
        let provider = StreamingCommunityPlaybackProvider(provider: StreamingCommunityProvider(domain: "streamingunity.cc"))
        let candidates = try await provider.candidates(for: .init(request: .init(media: media, episode: nil)))
        try await verifyCandidates(candidates, providerID: provider.id)
    }

    @MainActor
    private func verifyCandidates(_ candidates: [PlaybackCandidate], providerID: String) async throws {
        #expect(!candidates.isEmpty)
        let languages = Set(candidates.map { $0.preference.audioLanguage })
        var preparedByLanguage: [String: PlayableStream] = [:]
        for language in languages.sorted() {
            for candidate in candidates.filter({ $0.preference.audioLanguage == language }).prefix(2) {
                if let stream = try? await PlaybackDiscovery.prepare(candidate) {
                    preparedByLanguage[language] = stream
                    break
                }
            }
            #expect(preparedByLanguage[language] != nil, "\(providerID) \(language): no native-compatible stream")
        }
        var played = false
        for stream in preparedByLanguage.values {
            do {
                let player = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: stream.source.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.source.headers])))
                player.isMuted = true
                player.play()
                defer { player.pause(); player.replaceCurrentItem(with: nil) }
                for _ in 0..<100 {
                    try await Task.sleep(for: .milliseconds(200))
                    if player.currentItem?.status == .failed { break }
                    if player.currentTime().seconds > 1 { played = true; break }
                }
                if played { break }
            } catch { continue }
        }
        #expect(played, "\(providerID): a native player must advance, not merely resolve a URL")
    }
}
