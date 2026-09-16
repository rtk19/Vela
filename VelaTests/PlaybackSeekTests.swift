import Foundation
import Testing
@testable import Vela

@Suite("Playback seeking")
struct PlaybackSeekTests {
    @Test("Seek ahead outside the buffer waits for AVPlayer instead of refreshing")
    func seekAheadOutsideBuffer() {
        let action = PlaybackRecoveryPolicy.action(
            trigger: .stagnantBuffer(
                checks: PlaybackRecoveryPolicy.stagnantChecksBeforeRecovery,
                seekGraceActive: true
            ),
            sourceRefreshAttempts: 0
        )
        #expect(action == .keepWaiting)
        #expect(PlaybackSeekPolicy.normalTolerance > .zero)
    }

    @Test("Backward seek remains the latest target")
    func seekBackward() {
        var state = PlaybackSeekState()
        _ = state.begin(target: 2_100, shouldPlay: true, rate: 1)
        let backward = state.begin(target: 1_080, shouldPlay: true, rate: 1)
        #expect(backward.target == 1_080)
        #expect(state.recoverySnapshot(
            currentPosition: 2_100,
            fallbackShouldPlay: false,
            fallbackRate: 1
        ).position == 1_080)
    }

    @Test("Rapid seeks settle on the newest request")
    func rapidMultipleSeeks() {
        var state = PlaybackSeekState()
        let ten = state.begin(target: 600, shouldPlay: true, rate: 1)
        let thirtyFive = state.begin(target: 2_100, shouldPlay: true, rate: 1)
        let fiftyTwo = state.begin(target: 3_120, shouldPlay: true, rate: 1)
        let eighteen = state.begin(target: 1_080, shouldPlay: true, rate: 1)

        #expect(state.complete(ten.id, finished: true) == nil)
        #expect(state.complete(fiftyTwo.id, finished: true) == nil)
        #expect(state.complete(thirtyFive.id, finished: true) == nil)
        #expect(state.complete(eighteen.id, finished: true)?.target == 1_080)
    }

    @Test("Paused seek remains paused")
    func pausedSeek() {
        var state = PlaybackSeekState()
        let request = state.begin(target: 900, shouldPlay: false, rate: 1.25)
        #expect(state.complete(request.id, finished: true)?.shouldPlay == false)
    }

    @Test("Playing seek resumes")
    func playingSeek() {
        var state = PlaybackSeekState()
        let request = state.begin(target: 900, shouldPlay: true, rate: 1)
        #expect(state.complete(request.id, finished: true)?.shouldPlay == true)
    }

    @Test("Playback rate survives seeking")
    func playbackRatePreservation() {
        var state = PlaybackSeekState()
        let request = state.begin(target: 900, shouldPlay: true, rate: 1.75)
        #expect(state.complete(request.id, finished: true)?.rate == 1.75)
    }

    @Test("Source refresh during a seek restores the latest target and intent")
    func sourceRefreshAfterSeek() {
        var state = PlaybackSeekState()
        _ = state.begin(target: 3_120, shouldPlay: true, rate: 1.5)
        _ = state.begin(target: 1_080, shouldPlay: false, rate: 1.25)
        let recovery = state.recoverySnapshot(
            currentPosition: 600,
            fallbackShouldPlay: true,
            fallbackRate: 1
        )
        #expect(recovery == .init(position: 1_080, shouldPlay: false, rate: 1.25))
    }

    @Test("A stale seek completion cannot overwrite a newer seek")
    func staleCompletionIsIgnored() {
        var state = PlaybackSeekState()
        let old = state.begin(target: 2_100, shouldPlay: true, rate: 2)
        let newest = state.begin(target: 1_080, shouldPlay: false, rate: 1.25)

        #expect(state.complete(old.id, finished: true) == nil)
        #expect(state.latestRequest == newest)
        #expect(state.complete(newest.id, finished: true) == newest)
        #expect(state.complete(old.id, finished: true) == nil)
    }
}
