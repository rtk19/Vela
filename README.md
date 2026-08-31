# BetterStreamflix for iOS

Native SwiftUI iOS port focused on the English StreamingCommunity provider. The app is intentionally structured so new providers can be added without changing the catalog, details, persistence, or player features.

## Requirements

- macOS with Xcode 16 or newer and an installed iOS platform/runtime in **Xcode → Settings → Components**
- iOS/iPadOS 17 or newer
- An Apple Developer account for installing on a physical device

No third-party packages are required.

## Run on an iPhone

1. Open `BetterStreamflix.xcodeproj` in Xcode.
2. If Xcode shows no eligible iOS destination, open **Xcode → Settings → Components** and install the iOS platform/runtime offered for your Xcode version.
3. Select the **BetterStreamflix** target, then **Signing & Capabilities**.
4. Select your Apple Developer team.
5. If Xcode reports that the bundle identifier is unavailable, replace `com.refael.BetterStreamflix` with a unique identifier such as `com.yourname.BetterStreamflix`.
6. Connect and select your iPhone, then press **Run**.
7. If prompted on the iPhone, enable Developer Mode and trust the developer profile.

Run **Product → Test** once an iOS Simulator runtime is installed. The shared `BetterStreamflix` scheme includes the `BetterStreamflixTests` target.

## Build an unsigned IPA

From the repository root, run:

```sh
./build-unsigned-ipa.sh
```

Enter a release version such as `1.2.0`. The script permanently updates the version in both the Xcode project and `project.yml`, makes an unsigned device build, verifies the built version, and writes the IPA under `build/unsigned-ipa/<version>/`.

The script requires Xcode with iOS platform support installed under **Xcode → Settings → Components**.

To create an archive, select **Any iOS Device (arm64)** and use **Product → Archive**. Xcode can then export a development or ad-hoc signed IPA according to the provisioning profiles in your account.

## Included

- Apple TV-inspired, auto-advancing trending hero carousel backed independently by TMDB
- Native SwiftUI navigation for Home, Movies, Series, Search, Details, Seasons, Episodes, Watchlist, and Continue Watching
- StreamingCommunity EN/Inertia catalog client
- Automatic provider-domain redirect tracking and a configurable fallback domain that can be applied without restarting the app
- Vixcloud player-token resolution with one automatic expired-token retry
- HLS playback through AVPlayer
- Native AVPlayer playback controls, including audio, subtitles, speed, play/pause, and 10-second seeking
- A compact in-player quality selector populated from each stream's real HLS variants
- Default quality with closest-lower fallback and configurable default playback speed
- Preferred primary and backup subtitle languages
- Live ±0.1-second timing adjustment for downloaded subtitle tracks
- Preferred audio language with automatic English fallback
- Resume position and continue-watching persistence
- Versioned JSON export and import for all settings, watchlist entries, watched history, episode progress, Continue Watching selections, and title playback speeds
- Automatic next-episode playback and next-episode Continue Watching handoff
- Picture in Picture, AirPlay, background audio, and native full-screen playback
- Swift Testing coverage for Inertia/HTML parsing, live response-shape compatibility, shared-model persistence, and Vixcloud token parsing

## Architecture

`MediaProvider` is the stable provider contract. Each provider owns only its network mapping and stream resolution. Shared `MediaItem`, `PlaybackSource`, and `SubtitleSource` models isolate the UI and AVPlayer from provider-specific response formats.

To add another source:

1. Implement `MediaProvider` in `Core/`.
2. Map the source's responses into the shared models.
3. Return a `PlaybackSource` containing a standard HLS/MP4 URL, headers, and subtitle sources.
4. Register the implementation in `AppEnvironment`.

The rest of the application does not need provider-specific branching.

### Persistence and backups

User preferences belong in the app's `UserDefaults` domain. Durable user library and playback data belongs under `Application Support/BetterStreamflix`. The Settings backup feature snapshots both locations into a versioned JSON file and restores them as one unit, so new persisted features stored there are included automatically. If durable user data must live elsewhere, its implementation must extend `UserDataBackupService` and the backup round-trip test in the same change. Regenerable caches, temporary playback assets, bundled configuration, and non-user-created Keychain credentials are intentionally excluded.

## Provider maintenance

Streaming sites change domains and response formats without notice. The current fallback domain can be changed in **My Library → Settings → Provider**. A response-format change requires updating only `StreamingCommunityProvider`, `StreamingCommunityModels`, or `VixcloudResolver`.

## TMDB trending carousel

The hero carousel and discovery shelves use TMDB independently of StreamingCommunity's catalog lists. The app ships with its TMDB API Read Access Token in the bundled configuration and imports it into the device Keychain automatically, so no user setup is required.

## Important notes

- On August 26, 2026, the app and unit-test targets compiled against the iPhoneOS 26.5 SDK with strict concurrency enabled, and a live provider smoke test passed Home, two catalog pages, series details, seasons, episodes, and Vixcloud playlist resolution. A signed install still depends on your local Developer-team selection and installed Xcode iOS platform.
- The app does not contain or host media. Only access content you are legally authorized to view.
- The HLS header option used for Vixcloud playback is appropriate for personal/development signing. If this is ever prepared for App Store review, replace it with a documented local resource-loader/proxy implementation and review the provider's terms.

## Credits and license

Based on BetterStreamflix and the original Streamflix project. The repository's Apache-2.0 license and existing attribution apply.
