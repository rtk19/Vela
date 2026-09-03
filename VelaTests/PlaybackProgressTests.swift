import Foundation
import Testing
@testable import Vela

@Suite("Vela theme migration")
struct VelaThemeMigrationTests {
    @Test("Uses Vela Blue by default and maps legacy theme names")
    func migratesLegacyThemes() {
        #expect(VelaTheme(persistedValue: nil) == .blue)
        #expect(VelaTheme(persistedValue: "blue") == .blue)
        #expect(VelaTheme(persistedValue: "white") == .silver)
        #expect(VelaTheme(persistedValue: "purple") == .violet)
        #expect(VelaTheme(persistedValue: "green") == .aurora)
        #expect(VelaTheme(persistedValue: "pink") == .rose)
        #expect(VelaTheme(persistedValue: "red") == .ember)
    }
}

@Suite("Playback progress")
struct PlaybackProgressTests {
    @Test(
        "Episode exit completion uses the final minute boundary",
        arguments: [
            (position: 1_739.0, duration: 1_800.0, expected: false),
            (position: 1_740.0, duration: 1_800.0, expected: true),
            (position: 1_799.0, duration: 1_800.0, expected: true),
            (position: 0.0, duration: 30.0, expected: false),
        ]
    )
    func episodeExitBoundary(value: (position: Double, duration: Double, expected: Bool)) {
        #expect(
            PlaybackCompletionPolicy.shouldFinishEpisodeOnExit(
                request: request(episodeNumber: 1),
                position: value.position,
                duration: value.duration
            ) == value.expected
        )
    }

    @Test("Movies do not use the episode exit rule")
    func movieExitDoesNotFinish() {
        let movie = MediaItem(id: "movie", providerID: "test", kind: .movie, title: "Movie")
        #expect(
            PlaybackCompletionPolicy.shouldFinishEpisodeOnExit(
                request: PlaybackRequest(media: movie, episode: nil),
                position: 1_799,
                duration: 1_800
            ) == false
        )
    }

    @MainActor
    @Test("Finishing an episode promotes the next episode at zero")
    func finishingPromotesNextEpisode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory)
        let current = request(episodeNumber: 1)
        let next = request(episodeNumber: 2)

        library.updateProgress(request: current, position: 1_750, duration: 1_800)
        #expect(library.latestProgress(for: current.media)?.episode?.number == 1)

        library.markFinished(request: current, nextRequest: next)

        let progress = try #require(library.latestProgress(for: current.media))
        #expect(progress.episode?.number == 2)
        #expect(progress.position == 0)
        #expect(progress.duration == 0)
        #expect(progress.isNextUp)
        #expect(progress.shelfProgressLabel == "S01E02 • 00:00:00")
    }

    @MainActor
    @Test("Each episode keeps its own resume position while the latest play drives Continue Watching")
    func perEpisodeProgressAndLatestPlay() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory)
        let seasonThreeEpisodeFour = request(seasonNumber: 3, episodeNumber: 4)
        let seasonOneEpisodeOne = request(seasonNumber: 1, episodeNumber: 1)

        library.updateProgress(request: seasonThreeEpisodeFour, position: 792, duration: 1_800)
        library.updateProgress(request: seasonOneEpisodeOne, position: 75, duration: 1_800)

        #expect(library.progress.count == 2)
        #expect(library.continueWatching.count == 1)
        #expect(library.latestProgress(for: seasonOneEpisodeOne.media)?.episode?.number == 1)
        #expect(library.resumePosition(for: seasonThreeEpisodeFour) == 792)
        #expect(library.resumePosition(for: seasonOneEpisodeOne) == 75)

        library.markPlaybackStarted(request: seasonThreeEpisodeFour)

        #expect(library.latestProgress(for: seasonThreeEpisodeFour.media)?.episode?.seasonNumber == 3)
        #expect(library.latestProgress(for: seasonThreeEpisodeFour.media)?.episode?.number == 4)
        #expect(library.resumePosition(for: seasonThreeEpisodeFour) == 792)
        #expect(library.resumePosition(for: seasonOneEpisodeOne) == 75)

        library.markFinished(request: seasonOneEpisodeOne, nextRequest: seasonThreeEpisodeFour)
        #expect(library.resumePosition(for: seasonThreeEpisodeFour) == 792)

        let reloadedLibrary = LibraryStore(directory: directory)
        #expect(reloadedLibrary.progress.count == 1)
        #expect(reloadedLibrary.latestProgress(for: seasonThreeEpisodeFour.media)?.episode?.number == 4)
        #expect(reloadedLibrary.resumePosition(for: seasonThreeEpisodeFour) == 792)
        #expect(reloadedLibrary.resumePosition(for: seasonOneEpisodeOne) == 0)
    }

    @MainActor
    @Test("The latest episode follows a title opened through a different catalog representation")
    func latestEpisodeAcrossCatalogRepresentations() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let providerRequest = request(
            showID: "provider-show",
            providerID: "provider",
            tmdbID: 1_627,
            seasonNumber: 3,
            episodeNumber: 12
        )
        let watchlistRequest = request(
            showID: "tmdb:tv:1627",
            providerID: MediaItem.tmdbCatalogProviderID,
            tmdbID: 1_627,
            seasonNumber: 3,
            episodeNumber: 12
        )
        let library = LibraryStore(directory: directory)

        library.updateProgress(request: providerRequest, position: 321, duration: 1_800)

        let progress = try #require(library.latestProgress(for: watchlistRequest.media))
        #expect(progress.episode?.seasonNumber == 3)
        #expect(progress.episode?.number == 12)
        #expect(library.resumePosition(for: watchlistRequest) == 321)

        let reloadedLibrary = LibraryStore(directory: directory)
        #expect(reloadedLibrary.latestProgress(for: watchlistRequest.media)?.episode?.number == 12)
        #expect(reloadedLibrary.resumePosition(for: watchlistRequest) == 321)
    }

    @MainActor
    @Test("Playing the same TMDB series from another list keeps one Continue Watching selection")
    func oneContinueWatchingSelectionAcrossCatalogRepresentations() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = request(
            showID: "provider-show",
            providerID: "provider",
            tmdbID: 1_627,
            seasonNumber: 3,
            episodeNumber: 12
        )
        let replayed = request(
            showID: "tmdb:tv:1627",
            providerID: MediaItem.tmdbCatalogProviderID,
            tmdbID: 1_627,
            seasonNumber: 1,
            episodeNumber: 1
        )
        let library = LibraryStore(directory: directory)

        library.updateProgress(request: older, position: 321, duration: 1_800)
        library.updateProgress(request: replayed, position: 45, duration: 1_800)

        let current = try #require(library.continueWatching.first)
        #expect(library.continueWatching.count == 1)
        #expect(current.episode?.seasonNumber == 1)
        #expect(current.episode?.number == 1)
        #expect(library.latestProgress(for: older.media)?.episode?.number == 1)
    }

    @MainActor
    @Test("Watched state persists and replaying resets the episode")
    func watchedStatePersistsAndReplayResets() {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let episode = request(episodeNumber: 1)
        let library = LibraryStore(directory: directory)

        library.updateProgress(request: episode, position: 540, duration: 1_800)
        library.markWatched(request: episode)

        #expect(library.isWatched(episode))
        #expect(library.progress(for: episode) == nil)
        #expect(library.continueWatching.isEmpty)
        #expect(LibraryStore(directory: directory).isWatched(episode))

        library.markPlaybackStarted(request: episode)

        #expect(!library.isWatched(episode))
        #expect(library.resumePosition(for: episode) == 0)
        #expect(library.progress(for: episode)?.duration == 0)
    }

    @MainActor
    @Test("Promoting the next unwatched episode keeps its saved position")
    func promotionKeepsNextEpisodeProgress() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory)
        let current = request(episodeNumber: 1)
        let watchedNext = request(episodeNumber: 2)
        let nextUnwatched = request(episodeNumber: 3)

        library.updateProgress(request: nextUnwatched, position: 321, duration: 1_800)
        library.updateProgress(request: current, position: 900, duration: 1_800)
        library.markWatched(request: watchedNext)
        library.markWatched(request: current)
        library.promoteToContinueWatching(nextUnwatched)

        let promoted = try #require(library.continueWatching.first)
        #expect(promoted.episode?.number == 3)
        #expect(promoted.position == 321)
        #expect(library.isWatched(current))
        #expect(library.isWatched(watchedNext))
    }

    @MainActor
    @Test("Marking previous episodes watched spans seasons and leaves the selected episode untouched")
    func markingPreviousEpisodesWatchedSpansSeasons() {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory)
        let seasonOneEpisodeOne = request(seasonNumber: 1, episodeNumber: 1)
        let seasonOneEpisodeTwo = request(seasonNumber: 1, episodeNumber: 2)
        let seasonTwoEpisodeOne = request(seasonNumber: 2, episodeNumber: 1)
        let selectedEpisode = request(seasonNumber: 2, episodeNumber: 2)
        let laterEpisode = request(seasonNumber: 2, episodeNumber: 3)

        library.updateProgress(request: seasonOneEpisodeTwo, position: 240, duration: 1_800)
        library.updateProgress(request: selectedEpisode, position: 120, duration: 1_800)
        library.markWatched(requests: [
            seasonOneEpisodeOne,
            seasonOneEpisodeTwo,
            seasonTwoEpisodeOne
        ])

        #expect(library.isWatched(seasonOneEpisodeOne))
        #expect(library.isWatched(seasonOneEpisodeTwo))
        #expect(library.isWatched(seasonTwoEpisodeOne))
        #expect(!library.isWatched(selectedEpisode))
        #expect(!library.isWatched(laterEpisode))
        #expect(library.progress(for: seasonOneEpisodeTwo) == nil)
        #expect(library.progress(for: selectedEpisode)?.position == 120)

        let reloadedLibrary = LibraryStore(directory: directory)
        #expect(reloadedLibrary.isWatched(seasonOneEpisodeOne))
        #expect(reloadedLibrary.isWatched(seasonTwoEpisodeOne))
        #expect(!reloadedLibrary.isWatched(selectedEpisode))
    }

    @MainActor
    @Test("Marking previous episodes watched queues the selected episode without playback history")
    func markingPreviousEpisodesWatchedQueuesSelectedEpisode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory)
        let seasonFourEpisodeFour = request(seasonNumber: 4, episodeNumber: 4)
        let seasonFourEpisodeFive = request(seasonNumber: 4, episodeNumber: 5)

        library.markPreviousEpisodesWatched(
            requests: [seasonFourEpisodeFour],
            selectedRequest: seasonFourEpisodeFive
        )

        #expect(library.isWatched(seasonFourEpisodeFour))
        #expect(!library.isWatched(seasonFourEpisodeFive))
        let queued = try #require(library.continueWatching.first)
        #expect(queued.episode?.seasonNumber == 4)
        #expect(queued.episode?.number == 5)
        #expect(queued.isNextUp)

        let reloadedLibrary = LibraryStore(directory: directory)
        #expect(reloadedLibrary.latestProgress(for: seasonFourEpisodeFive.media)?.episode?.number == 5)
    }

    @MainActor
    @Test("Finishing the final episode does not reveal older saved progress")
    func finishingFinalEpisodeClearsSeriesFromContinueWatching() {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory)
        let older = request(episodeNumber: 1)
        let final = request(episodeNumber: 8)

        library.updateProgress(request: older, position: 120, duration: 1_800)
        library.updateProgress(request: final, position: 1_790, duration: 1_800)
        library.markFinished(request: final, nextRequest: nil)

        #expect(library.progress(for: older)?.position == 120)
        #expect(library.continueWatching.isEmpty)
        #expect(library.latestProgress(for: final.media) == nil)
        #expect(library.isWatched(final))
    }

    @MainActor
    @Test("A finished final episode is remembered until a newly released episode is promoted")
    func completedSeriesCheckpointPersistsUntilNewEpisode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = request(seasonNumber: 2, episodeNumber: 8)
        let newlyReleased = request(seasonNumber: 3, episodeNumber: 1)
        let library = LibraryStore(directory: directory)

        library.markFinished(request: final, nextRequest: nil)

        #expect(library.continueWatching.isEmpty)
        let reloadedLibrary = LibraryStore(directory: directory)
        let checkpoint = try #require(reloadedLibrary.completedSeriesRequests.first)
        #expect(checkpoint.episode?.seasonNumber == 2)
        #expect(checkpoint.episode?.number == 8)

        reloadedLibrary.promoteToContinueWatching(newlyReleased)

        #expect(reloadedLibrary.completedSeriesRequests.isEmpty)
        #expect(reloadedLibrary.continueWatching.first?.episode?.seasonNumber == 3)
        #expect(reloadedLibrary.continueWatching.first?.episode?.number == 1)
        #expect(LibraryStore(directory: directory).completedSeriesRequests.isEmpty)
    }

    @MainActor
    @Test("A discovered episode is not promoted again after relaunch")
    func discoveredEpisodeIsOnlyPromotedOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = request(episodeNumber: 8)
        let discoveredMedia = MediaItem(
            id: final.media.id,
            providerID: final.media.providerID,
            kind: .series,
            title: final.media.title,
            tmdbID: 1_627
        )
        let discoveredEpisode = MediaEpisode(
            id: "show-episode-2-1",
            providerID: final.media.providerID,
            showID: final.media.id,
            seasonNumber: 2,
            number: 1,
            title: "Episode 1",
            overview: nil,
            posterURL: nil
        )
        let discovered = PlaybackRequest(media: discoveredMedia, episode: discoveredEpisode)
        let playedMovie = MediaItem(
            id: "movie",
            providerID: "test",
            kind: .movie,
            title: "Movie"
        )
        let movieRequest = PlaybackRequest(media: playedMovie, episode: nil)
        let library = LibraryStore(directory: directory)

        library.markFinished(request: final, nextRequest: nil)
        library.promoteToContinueWatching(discovered)
        library.updateProgress(request: movieRequest, position: 120, duration: 7_200)

        #expect(library.completedSeriesRequests.isEmpty)
        #expect(library.continueWatching.first?.media.id == playedMovie.id)

        let reloadedLibrary = LibraryStore(directory: directory)
        #expect(reloadedLibrary.completedSeriesRequests.isEmpty)
        #expect(reloadedLibrary.continueWatching.first?.media.id == playedMovie.id)
        #expect(reloadedLibrary.continueWatching.last?.episode?.number == 1)
    }

    @MainActor
    @Test("An unreleased queued episode is removed while the completed-series checkpoint is restored")
    func unreleasedQueuedEpisodeIsDeferred() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let released = request(episodeNumber: 2)
        let unreleased = request(episodeNumber: 3)
        let library = LibraryStore(directory: directory)

        library.markWatched(request: released)
        library.promoteToContinueWatching(unreleased)
        library.deferUnavailableNextUp(try #require(library.continueWatching.first))

        #expect(library.continueWatching.isEmpty)
        #expect(library.completedSeriesRequests.first?.episode?.number == 2)
        #expect(LibraryStore(directory: directory).completedSeriesRequests.first?.episode?.number == 2)
    }

    @MainActor
    @Test("Playback speed persists per title and removal resets it to Settings")
    func playbackSpeedMemory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstEpisode = request(episodeNumber: 1)
        let anotherEpisode = request(episodeNumber: 2)
        let library = LibraryStore(directory: directory)

        #expect(library.playbackRate(for: firstEpisode, defaultRate: 1.25) == 1.25)

        library.updatePlaybackRate(1.5, for: firstEpisode)

        #expect(library.playbackRate(for: anotherEpisode, defaultRate: 1.0) == 1.5)
        #expect(LibraryStore(directory: directory).playbackRate(
            for: anotherEpisode,
            defaultRate: 1.0
        ) == 1.5)

        library.updateProgress(request: firstEpisode, position: 120, duration: 1_800)
        let savedProgress = try #require(library.progress(for: firstEpisode))
        library.removeProgress(savedProgress)

        #expect(library.resumePosition(for: firstEpisode) == 0)
        #expect(library.playbackRate(for: firstEpisode, defaultRate: 0.75) == 0.75)
        #expect(LibraryStore(directory: directory).playbackRate(
            for: firstEpisode,
            defaultRate: 0.75
        ) == 0.75)
    }

    @MainActor
    @Test("Landscape player zoom persists per title and removal resets it")
    func playerZoomMemory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstEpisode = request(episodeNumber: 1)
        let anotherEpisode = request(episodeNumber: 2)
        let movie = MediaItem(id: "movie", providerID: "test", kind: .movie, title: "Movie")
        let movieRequest = PlaybackRequest(media: movie, episode: nil)
        let library = LibraryStore(directory: directory)

        #expect(!library.isPlayerZoomedToFill(for: firstEpisode))
        library.updatePlayerZoomedToFill(true, for: firstEpisode)

        #expect(library.isPlayerZoomedToFill(for: anotherEpisode))
        #expect(!library.isPlayerZoomedToFill(for: movieRequest))
        #expect(LibraryStore(directory: directory).isPlayerZoomedToFill(for: anotherEpisode))

        library.updateProgress(request: firstEpisode, position: 120, duration: 1_800)
        let savedProgress = try #require(library.progress(for: firstEpisode))
        library.removeProgress(savedProgress)

        #expect(!library.isPlayerZoomedToFill(for: firstEpisode))
        #expect(!LibraryStore(directory: directory).isPlayerZoomedToFill(for: firstEpisode))
    }

    @MainActor
    @Test("Watchlist persists and migrates the previous favorites file")
    func watchlistPersistenceAndMigration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyItem = MediaItem(
            id: "legacy-movie",
            providerID: "test",
            kind: .movie,
            title: "Legacy Movie"
        )
        try JSONEncoder().encode([legacyItem]).write(
            to: directory.appending(path: "favorites.json"),
            options: .atomic
        )

        let migratedLibrary = LibraryStore(directory: directory)

        #expect(migratedLibrary.watchlist == [legacyItem])
        #expect(FileManager.default.fileExists(
            atPath: directory.appending(path: "watchlist.json").path
        ))

        let newItem = MediaItem(
            id: "new-series",
            providerID: "test",
            kind: .series,
            title: "New Series"
        )
        migratedLibrary.toggleWatchlist(newItem)
        let reloadedLibrary = LibraryStore(directory: directory)

        #expect(reloadedLibrary.watchlist == [newItem, legacyItem])
        #expect(reloadedLibrary.isInWatchlist(newItem))
    }

    @Test("User data backup restores preferences and all application-support files exactly")
    func userDataBackupRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let dataDirectory = root.appending(path: "BetterStreamflix", directoryHint: .isDirectory)
        let suiteName = "VelaTests.Backup.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try Data("progress-before-export".utf8).write(
            to: dataDirectory.appending(path: "progress.json")
        )
        let nestedDirectory = dataDirectory.appending(path: "future-feature", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: nestedDirectory.appending(path: ".history-data"))
        try Data(#"{"episode":[{"offsetTenths":3}]}"#.utf8).write(
            to: dataDirectory.appending(path: "subtitle-sync-versions.json")
        )
        defaults.set("purple", forKey: "appearance.themeColor")
        defaults.set(1.75, forKey: "player.defaultPlaybackRate")

        let service = UserDataBackupService(
            applicationSupportDirectory: dataDirectory,
            userDefaults: defaults,
            preferencesDomain: suiteName,
            appVersion: "9.9.9"
        )
        let exportedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let backup = try service.exportData(now: exportedAt)

        let exportedJSON = try #require(
            JSONSerialization.jsonObject(with: backup) as? [String: Any]
        )
        let exportedFiles = try #require(
            exportedJSON["applicationSupportFiles"] as? [[String: Any]]
        )
        #expect(Set(exportedFiles.compactMap { $0["relativePath"] as? String }) == [
            "future-feature/.history-data",
            "progress.json",
            "subtitle-sync-versions.json"
        ])

        try Data("changed".utf8).write(to: dataDirectory.appending(path: "progress.json"))
        try Data("remove-me".utf8).write(to: dataDirectory.appending(path: "created-after-export.json"))
        defaults.set("green", forKey: "appearance.themeColor")
        defaults.set(true, forKey: "future.setting")

        try service.restore(from: backup)

        #expect(try Data(contentsOf: dataDirectory.appending(path: "progress.json")) == Data("progress-before-export".utf8))
        #expect(try Data(contentsOf: nestedDirectory.appending(path: ".history-data")) == Data([0, 1, 2, 3]))
        #expect(try Data(contentsOf: dataDirectory.appending(path: "subtitle-sync-versions.json")) == Data(#"{"episode":[{"offsetTenths":3}]}"#.utf8))
        #expect(!FileManager.default.fileExists(atPath: dataDirectory.appending(path: "created-after-export.json").path))
        #expect(defaults.string(forKey: "appearance.themeColor") == "purple")
        #expect(defaults.double(forKey: "player.defaultPlaybackRate") == 1.75)
        #expect(defaults.object(forKey: "future.setting") == nil)
        #expect(try service.summary(for: backup) == UserDataBackupSummary(
            exportedAt: exportedAt,
            appVersion: "9.9.9",
            fileCount: 3
        ))
    }

    @Test("User data backup imports iOS version 1 paths affected by the /private/var mismatch")
    func userDataBackupImportsLegacyIOSPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let dataDirectory = root.appending(path: "BetterStreamflix", directoryHint: .isDirectory)
        let suiteName = "VelaTests.Backup.Legacy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try Data("saved-progress".utf8).write(to: dataDirectory.appending(path: "progress.json"))

        let service = UserDataBackupService(
            applicationSupportDirectory: dataDirectory,
            userDefaults: defaults,
            preferencesDomain: suiteName,
            appVersion: "2.0.0"
        )
        let backup = try service.exportData()
        var json = try #require(JSONSerialization.jsonObject(with: backup) as? [String: Any])
        var files = try #require(json["applicationSupportFiles"] as? [[String: Any]])
        for index in files.indices {
            let path = try #require(files[index]["relativePath"] as? String)
            files[index]["relativePath"] = "eamflix/\(path)"
        }
        json["applicationSupportFiles"] = files
        let affectedBackup = try JSONSerialization.data(withJSONObject: json)

        try Data("changed".utf8).write(to: dataDirectory.appending(path: "progress.json"))
        try service.restore(from: affectedBackup)

        #expect(
            try Data(contentsOf: dataDirectory.appending(path: "progress.json"))
                == Data("saved-progress".utf8)
        )
        #expect(!FileManager.default.fileExists(atPath: dataDirectory.appending(path: "eamflix").path))
    }

    @MainActor
    @Test("Subtitle sync versions persist per episode without depending on expiring URLs")
    func subtitleSyncVersionsPersistPerEpisode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstEpisode = request(episodeNumber: 1)
        let secondEpisode = request(episodeNumber: 2)
        let expiringSource = SubtitleSource(
            providerID: "wizdom",
            providerName: "Wizdom",
            label: "Release.1080p",
            languageCode: "he",
            url: try #require(URL(string: "https://example.com/sub.srt?token=first"))
        )
        let laterURLForSameSource = SubtitleSource(
            providerID: "wizdom",
            providerName: "Wizdom",
            label: "Release.1080p",
            languageCode: "he",
            url: try #require(URL(string: "https://example.com/sub.srt?token=second"))
        )
        let library = LibraryStore(directory: directory)
        let older = try #require(library.saveSubtitleSyncVersion(
            subtitle: expiringSource,
            offset: 0.26,
            for: firstEpisode,
            now: Date(timeIntervalSince1970: 100)
        ))
        let newer = try #require(library.saveSubtitleSyncVersion(
            subtitle: expiringSource,
            offset: -31,
            for: firstEpisode,
            now: Date(timeIntervalSince1970: 200)
        ))

        #expect(expiringSource.syncKey == laterURLForSameSource.syncKey)
        #expect(older.offset == 0.3)
        #expect(newer.offset == -30)
        #expect(library.subtitleSyncVersions(for: secondEpisode).isEmpty)

        let reloaded = LibraryStore(directory: directory)
        let restored = reloaded.subtitleSyncVersions(for: firstEpisode)
        #expect(restored.map(\.id) == [newer.id, older.id])
        #expect(restored.allSatisfy { $0.subtitleKey == laterURLForSameSource.syncKey })

        reloaded.deleteSubtitleSyncVersion(newer.id, for: firstEpisode)
        #expect(LibraryStore(directory: directory).subtitleSyncVersions(for: firstEpisode).map(\.id) == [older.id])
    }

    private func request(seasonNumber: Int = 1, episodeNumber: Int) -> PlaybackRequest {
        request(
            showID: "show",
            providerID: "test",
            tmdbID: nil,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber
        )
    }

    private func request(
        showID: String,
        providerID: String,
        tmdbID: Int?,
        seasonNumber: Int,
        episodeNumber: Int
    ) -> PlaybackRequest {
        let show = MediaItem(
            id: showID,
            providerID: providerID,
            kind: .series,
            title: "Show",
            tmdbID: tmdbID
        )
        let episode = MediaEpisode(
            id: "\(showID)-episode-\(seasonNumber)-\(episodeNumber)",
            providerID: providerID,
            showID: show.id,
            seasonNumber: seasonNumber,
            number: episodeNumber,
            title: "Episode \(episodeNumber)",
            overview: nil,
            posterURL: nil
        )
        return PlaybackRequest(media: show, episode: episode)
    }
}
