import Foundation
import SwiftUI
import Testing
@testable import GlancyKit

@Suite struct HUDKeyDecodingTests {
    @Test func decodesEveryKeyDownAndUp() {
        for key in MediaKey.allCases {
            let down = MediaKeyEvent.decode(subtype: 8, data1: MediaKeyEvent.data1(key: key, down: true))
            #expect(down == MediaKeyEvent(key: key, isDown: true, isRepeat: false))
            let up = MediaKeyEvent.decode(subtype: 8, data1: MediaKeyEvent.data1(key: key, down: false))
            #expect(up == MediaKeyEvent(key: key, isDown: false, isRepeat: false))
        }
    }

    @Test func realVolumeUpWords() {
        // Volume up as the keyboard sends it: 0x000A0A00 down, 0x000A0B00 up, 0x000A0A01 repeat
        // (code 0 → NX_KEYTYPE_SOUND_UP); brightness down 0x00030A00.
        #expect(MediaKeyEvent.decode(subtype: 8, data1: 0x0A00) == MediaKeyEvent(key: .volumeUp, isDown: true, isRepeat: false))
        #expect(MediaKeyEvent.decode(subtype: 8, data1: 0x0B00) == MediaKeyEvent(key: .volumeUp, isDown: false, isRepeat: false))
        #expect(MediaKeyEvent.decode(subtype: 8, data1: 0x0A01) == MediaKeyEvent(key: .volumeUp, isDown: true, isRepeat: true))
        #expect(MediaKeyEvent.decode(subtype: 8, data1: 0x0003_0A00)?.key == .brightnessDown)
        #expect(MediaKeyEvent.decode(subtype: 8, data1: 0x0007_0A00)?.key == .mute)
        #expect(MediaKeyEvent.decode(subtype: 8, data1: 0x0015_0A00)?.key == .keyboardUp)
        #expect(MediaKeyEvent.decode(subtype: 8, data1: 0x0016_0B00)?.key == .keyboardDown)
    }

    @Test func repeatFlag() {
        let e = MediaKeyEvent.decode(subtype: 8, data1: MediaKeyEvent.data1(key: .volumeDown, down: true, isRepeat: true))
        #expect(e?.isRepeat == true)
        #expect(e?.isDown == true)
    }

    @Test func ignoresOtherSubtypesKeysAndStates() {
        #expect(MediaKeyEvent.decode(subtype: 7, data1: 0x0A00) == nil)            // not aux control buttons
        #expect(MediaKeyEvent.decode(subtype: 8, data1: 0x0010_0A00) == nil)       // 16 = play/pause: Media's
        #expect(MediaKeyEvent.decode(subtype: 8, data1: 0x0000_0C00) == nil)       // unknown state
        #expect(MediaKeyEvent.decode(subtype: 8, data1: 0x0000_0000) == nil)
    }

    @Test func highBitsBeyond32AreIgnored() {
        let data1 = (1 << 40) | MediaKeyEvent.data1(key: .brightnessUp, down: true)
        #expect(MediaKeyEvent.decode(subtype: 8, data1: data1)?.key == .brightnessUp)
    }

    @Test func modifiers() {
        #expect(HUDModifiers.from(option: true, shift: true) == .fine)
        #expect(HUDModifiers.from(option: true, shift: false) == .systemShortcut)
        #expect(HUDModifiers.from(option: false, shift: true) == .shiftOnly)
        #expect(HUDModifiers.from(option: false, shift: false) == .none)
    }

    @Test func keyKindsAndDirections() {
        #expect(MediaKey.volumeUp.kind == .volume && MediaKey.volumeUp.direction == 1)
        #expect(MediaKey.mute.kind == .volume && MediaKey.mute.direction == 0)
        #expect(MediaKey.brightnessDown.kind == .brightness && MediaKey.brightnessDown.direction == -1)
        #expect(MediaKey.keyboardUp.kind == .keyboard && MediaKey.keyboardUp.direction == 1)
    }
}

@Suite struct HUDStepTests {
    @Test func coarseStepsOnTheGrid() {
        #expect(HUDStep.next(0.5, up: true, fine: false) == 0.5625)
        #expect(HUDStep.next(0.5, up: false, fine: false) == 0.4375)
        #expect(HUDStep.next(0, up: true, fine: false) == 0.0625)
    }

    @Test func fineQuarterSteps() {
        #expect(HUDStep.next(0.5, up: true, fine: true) == 0.515625)
        #expect(HUDStep.next(0.5, up: false, fine: true) == 0.484375)
        // Four fine steps make one coarse step.
        var v: Float = 0.25
        for _ in 0..<4 { v = HUDStep.next(v, up: true, fine: true) }
        #expect(v == HUDStep.next(0.25, up: true, fine: false))
    }

    @Test func offGridSnapsToNeighbourInDirection() {
        // 0.52 sits between 8/16 and 9/16.
        #expect(HUDStep.next(0.52, up: true, fine: false) == 0.5625)
        #expect(HUDStep.next(0.52, up: false, fine: false) == 0.5)
    }

    @Test func deviceQuantisationNoiseDoesNotSkipOrStall() {
        // A device that reads back 0.5624 for 0.5625 must still step to 10/16 and back to 8/16.
        #expect(HUDStep.next(0.5624, up: true, fine: false) == 0.625)
        #expect(HUDStep.next(0.5626, up: false, fine: false) == 0.5)
    }

    @Test func clamps() {
        #expect(HUDStep.next(1, up: true, fine: false) == 1)
        #expect(HUDStep.next(0.98, up: true, fine: false) == 1)
        #expect(HUDStep.next(0, up: false, fine: false) == 0)
        #expect(HUDStep.next(0.01, up: false, fine: true) == 0)
        #expect(HUDStep.next(1.4, up: true, fine: false) == 1)
        #expect(HUDStep.next(-0.2, up: false, fine: false) == 0)
    }

    @Test func fullRangeTakes16And64Presses() {
        var v: Float = 0, n = 0
        while v < 1 { v = HUDStep.next(v, up: true, fine: false); n += 1 }
        #expect(n == 16)
        v = 0; n = 0
        while v < 1 { v = HUDStep.next(v, up: true, fine: true); n += 1 }
        #expect(n == 64)
    }

    @Test func percent() {
        #expect(HUDStep.percent(0.5625) == 56)
        #expect(HUDStep.percent(1.2) == 100)
        #expect(HUDStep.percent(-1) == 0)
    }
}

@Suite struct HUDPresentationTests {
    @Test func volumeSymbols() {
        #expect(HUDReading(kind: .volume, level: 0.5, muted: true).symbol == "speaker.slash.fill")
        #expect(HUDReading(kind: .volume, level: 0).symbol == "speaker.slash.fill")
        #expect(HUDReading(kind: .volume, level: 0.2).symbol == "speaker.wave.1.fill")
        #expect(HUDReading(kind: .volume, level: 0.5).symbol == "speaker.wave.2.fill")
        #expect(HUDReading(kind: .volume, level: 0.9).symbol == "speaker.wave.3.fill")
    }

    @Test func otherSymbols() {
        #expect(HUDReading(kind: .brightness, level: 0.1).symbol == "sun.min.fill")
        #expect(HUDReading(kind: .brightness, level: 0.8).symbol == "sun.max.fill")
        #expect(HUDReading(kind: .keyboard, level: 0).symbol == "light.min")
        #expect(HUDReading(kind: .keyboard, level: 0.5).symbol == "light.max")
    }

    @Test func mutedShowsEmptyBar() {
        #expect(HUDReading(kind: .volume, level: 0.7, muted: true).shownLevel == 0)
        #expect(HUDReading(kind: .volume, level: 0.7).shownLevel == 0.7)
    }

    @Test func externalChangeRule() {
        let known = VolumeState(volume: 0.5, muted: false)
        // Launch / device switch: nothing known yet → silent.
        #expect(!VolumeState.isExternalChange(known: nil, now: known))
        // Our own write already recorded, or device rounding → silent.
        #expect(!VolumeState.isExternalChange(known: known, now: VolumeState(volume: 0.5, muted: false)))
        #expect(!VolumeState.isExternalChange(known: known, now: VolumeState(volume: 0.5031, muted: false)))
        // Slider, AirPods, another app → HUD.
        #expect(VolumeState.isExternalChange(known: known, now: VolumeState(volume: 0.6, muted: false)))
        #expect(VolumeState.isExternalChange(known: known, now: VolumeState(volume: 0.5, muted: true)))
    }
}

@Suite @MainActor struct HUDActivityTests {
    @Test func postsOneActivityAtPriority75AndExtendsIt() throws {
        let hub = ActivityHub()
        let suite = "ai.glancy.tests.hud"
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        let module = HUDModule(settings: HUDSettings(defaults: UserDefaults(suiteName: suite)!), usesHardware: false)
        module.start(hub: hub)
        defer { module.stop() }
        module.showSample(HUDReading(kind: .volume, level: 0.5))
        let first = try #require(hub.top)
        #expect(first.id == "hud" && first.priority == 75 && first.module == .hud)
        let expires = try #require(first.expires)
        #expect(abs(expires.timeIntervalSince(first.updated) - 1.5) < 0.05)
        // A second press while the HUD is up keeps the same presentation (same `updated`).
        module.showSample(HUDReading(kind: .volume, level: 0.5625))
        #expect(hub.top?.updated == first.updated)
        #expect(module.model.reading.level == 0.5625)
        // An agent waiting (90) still wins over the HUD.
        hub.post(LiveActivity(id: "agents", module: .agents, priority: 90, left: AnyView(EmptyView()), right: AnyView(EmptyView())))
        #expect(hub.top?.id == "agents")
    }

    @Test func settingDefaultsOnAndPersists() {
        let suite = "ai.glancy.tests.hud.settings"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        #expect(HUDSettings(defaults: defaults).enabled)
        HUDSettings(defaults: defaults).enabled = false
        #expect(!HUDSettings(defaults: defaults).enabled)
    }
}
