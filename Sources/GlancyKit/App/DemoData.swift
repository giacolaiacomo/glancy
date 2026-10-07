import AppKit
import Foundation

/// Made-up content for README and release images (`glancy-render --demo`): every module runs on
/// `IsolatedModules` (nothing of the user's is read) and is seeded with synthetic data — Claude
/// Code sessions in neutral project folders, a calendar, a now-playing track with drawn artwork,
/// a Pomodoro, a few shelf files, a battery and AirPods. Clipboard, notifications and windows
/// use their existing samples.
@MainActor
public enum DemoData {
    public static func modules(root: URL, now: Date = .now) -> [any GlancyModule] {
        make(root: root, now: now).modules
    }

    /// The seeded set, with its private defaults suites (the lab removes them when it quits).
    static func make(root: URL, now: Date = .now) -> IsolatedModules.Set {
        let set = IsolatedModules.make(root: root)
        writeAgentsLog(to: set.agentsLog, now: now)
        fillCalendar(set.calendar, now: now)
        writeNowPlaying(root: root, media: set.media, now: now)
        seedTimer(root: root, now: now)
        seedShelf(root: root)
        set.power.fixed = .init(
            battery: PowerState(hasBattery: true, percent: 76, onAC: false, isCharging: false),
            devices: [BluetoothDeviceInfo(address: "00:00:00:00:00:01", name: "AirPods Pro",
                                          symbol: BluetoothIcon.symbol(name: "AirPods Pro"), isAudio: true,
                                          battery: BluetoothBattery(left: 82, right: 90, case: 40))])
        // Tiling shown as available (the synthetic desk needs no Accessibility; nothing is moved).
        set.modules.compactMap { $0 as? AgentsModule }.first?.prepareForRender(.tilingReady)
        // Plan limits: Burny's demo readings (no CLI is run, nothing of the user's is read).
        set.modules.compactMap { $0 as? AgentsModule }.first?.seedLimitsSample(now: now)
        return set
    }

    /// The same made-up Mac at rest, for Home's idle cards: no session, no meeting left, nothing
    /// playing (the last track remembered), no timer, an empty shelf, Keep awake off, nothing
    /// pinned, the battery at a normal level; calm plan limits. `active` puts a few back on
    /// (a timer running, Keep awake on) for the mixed shots.
    public static func idleModules(root: URL, now: Date = .now, active: Bool = false) -> [any GlancyModule] {
        let set = IsolatedModules.make(root: root)
        set.power.fixed = .init(battery: PowerState(hasBattery: true, percent: 76, onAC: false, isCharging: false, minutesToEmpty: 312),
                                devices: [])
        let art = root.appendingPathComponent("media/artwork.png")
        if let png = artwork() { try? png.write(to: art) }
        set.media.prepareIdleForRender(LastTrack(title: "Golden Hour Drive", artist: "Paper Lanterns", bundleID: "com.apple.Music"),
                                       artwork: art)
        if active { seedTimer(root: root, now: now) }
        set.modules.compactMap { $0 as? AgentsModule }.first?.seedLimitsCalm(now: now)
        return set.modules
    }

    /// After `start`: the sample notes unpinned; with `active`, Keep awake on.
    @MainActor public static func settleIdle(_ modules: [any GlancyModule], active: Bool) {
        for m in modules {
            (m as? NotesModule)?.unpinForRender()
            if active { (m as? ControlModule)?.prepareForRender(.awake) }
        }
    }

    // MARK: Agents: four sessions, one waiting for permission

    static func writeAgentsLog(to url: URL, now: Date) {
        let ms = Int(now.timeIntervalSince1970 * 1000)
        func line(_ ago: Double, _ event: String, _ sid: String, _ folder: String, tool: String? = nil, prompt: String = "") -> String {
            var o: [String: Any] = ["ts": ms - Int(ago * 1000), "event": event, "session_id": sid,
                                    "cwd": "/Users/demo/Projects/\(folder)", "prompt": prompt]
            if let tool { o["tool_name"] = tool }
            let d = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
            return String(decoding: d, as: UTF8.self)
        }
        let lines = [
            line(1500, "SessionStart", "demo-docs", "docs-site"),
            line(1490, "UserPromptSubmit", "demo-docs", "docs-site", prompt: "Write the install page"),
            line(1200, "PostToolUse", "demo-docs", "docs-site", tool: "Write"),
            line(1100, "Stop", "demo-docs", "docs-site"),
            line(900, "SessionStart", "demo-web", "web-app"),
            line(880, "UserPromptSubmit", "demo-web", "web-app", prompt: "Add dark mode to the settings page"),
            line(60, "PostToolUse", "demo-web", "web-app", tool: "Edit"),
            line(8, "PostToolUse", "demo-web", "web-app", tool: "Bash"),
            line(400, "SessionStart", "demo-api", "api"),
            line(390, "UserPromptSubmit", "demo-api", "api", prompt: "Run the migrations on staging"),
            line(40, "PostToolUse", "demo-api", "api", tool: "Read"),
            line(20, "PermissionRequest", "demo-api", "api", tool: "Bash"),
            line(300, "SessionStart", "demo-mobile", "mobile"),
            line(290, "UserPromptSubmit", "demo-mobile", "mobile", prompt: "Fix the flaky login test"),
            line(4, "PostToolUse", "demo-mobile", "mobile", tool: "Grep"),
        ]
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Calendar: a call in a few minutes, the rest of the day, tomorrow

    static func fillCalendar(_ c: FixedCalendar, now: Date) {
        let work = CalendarInfo(id: "demo-work", title: "Work", source: "Demo", color: CalendarRGB(r: 0.36, g: 0.55, b: 1.0))
        let home = CalendarInfo(id: "demo-home", title: "Personal", source: "Demo", color: CalendarRGB(r: 0.98, g: 0.62, b: 0.30))
        c.calendarList = [work, home]
        let minute: TimeInterval = 60
        // Align to whole minutes so the countdown reads cleanly.
        let base = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        func event(_ id: String, _ title: String, in m: Double, for len: Double, _ cal: CalendarInfo,
                   location: String? = nil, link: String? = nil) -> CalendarEvent {
            CalendarEvent(id: id, title: title, start: base.addingTimeInterval(m * minute),
                          end: base.addingTimeInterval((m + len) * minute), calendarID: cal.id, color: cal.color,
                          location: location,
                          link: link.flatMap { MeetingLink.extract(url: URL(string: $0), location: nil, notes: nil) })
        }
        c.eventList = [
            event("d1", "Design review", in: 6, for: 45, work, link: "https://zoom.us/j/5550100123"),
            event("d2", "1:1 with Alex", in: 120, for: 30, work, link: "https://meet.google.com/abc-defg-hij"),
            event("d3", "Lunch with Sam", in: 210, for: 60, home, location: "Corner Café"),
            event("d4", "Sprint planning", in: 24 * 60 + 30, for: 60, work, link: "https://zoom.us/j/5550100456"),
        ]
    }

    // MARK: Media: a made-up track with drawn artwork

    static func writeNowPlaying(root: URL, media: MediaModule, now: Date) {
        let art = root.appendingPathComponent("media/artwork.png")
        if let png = artwork() { try? png.write(to: art) }
        let payload: [String: Any] = [
            "bundleIdentifier": "com.apple.Music", "title": "Golden Hour Drive", "artist": "Paper Lanterns",
            "album": "Night Roads", "playing": true, "durationMicros": 236_000_000, "elapsedTimeMicros": 92_000_000,
            "timestampEpochMicros": Int(now.timeIntervalSince1970 * 1_000_000), "playbackRate": 1,
            "artworkPath": art.path, "outputName": "MacBook Pro Speakers",
        ]
        let url = root.appendingPathComponent("media/now-playing.json")
        if let d = try? JSONSerialization.data(withJSONObject: payload) { try? d.write(to: url) }
        media.fixturePath = url.path
    }

    /// Dusk colours, a sun and a road: no real album art.
    private static func artwork() -> Data? {
        let s = 600
        guard let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(red: 0.99, green: 0.55, blue: 0.33, alpha: 1), CGColor(red: 0.55, green: 0.20, blue: 0.50, alpha: 1),
                      CGColor(red: 0.16, green: 0.10, blue: 0.30, alpha: 1)]
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
        }
        ctx.setFillColor(CGColor(red: 1, green: 0.86, blue: 0.55, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 190, y: 250, width: 220, height: 220))
        ctx.setFillColor(CGColor(red: 0.10, green: 0.06, blue: 0.18, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: 250))
        ctx.setFillColor(CGColor(red: 1, green: 0.80, blue: 0.50, alpha: 0.85))
        ctx.move(to: CGPoint(x: 280, y: 250)); ctx.addLine(to: CGPoint(x: 320, y: 250))
        ctx.addLine(to: CGPoint(x: 470, y: 0)); ctx.addLine(to: CGPoint(x: 130, y: 0)); ctx.closePath(); ctx.fillPath()
        guard let img = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: img)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Timer: a Pomodoro focus run, 7 minutes in

    static func seedTimer(root: URL, now: Date) {
        var state = TimerState()
        TimerMachine.startPomodoro(&state, now: now.addingTimeInterval(-7 * 60))
        TimerStore(url: root.appendingPathComponent("timer/timer.json")).save(TimerSnapshot(state: state))
    }

    // MARK: Shelf: three files dropped on the notch

    static func seedShelf(root: URL) {
        let dir = root.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files: [(String, Data)] = [
            ("Launch plan.pdf", minimalPDF()),
            ("hero-mockup.png", artwork() ?? Data()),
            ("release-notes.md", Data("# 0.1.0\n\n- First release\n".utf8)),
        ]
        var items: [ShelfItem] = []
        for (i, (name, data)) in files.enumerated() {
            let url = dir.appendingPathComponent(name)
            try? data.write(to: url)
            if let item = try? ShelfStore.item(for: url, owned: false, id: UUID(), added: Date.now.addingTimeInterval(Double(-i) * 600)) {
                items.append(item)
            }
        }
        ShelfStore(dir: root.appendingPathComponent("shelf", isDirectory: true)).save(items)   // IsolatedModules' shelf
    }

    private static func minimalPDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 420, height: 297)
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 0.36, green: 0.55, blue: 1.0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 220, width: 420, height: 77))
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }
}
