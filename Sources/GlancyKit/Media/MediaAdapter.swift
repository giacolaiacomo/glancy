import Darwin
import Foundation

/// Runs ungive/mediaremote-adapter (BSD-3, `Vendor/mediaremote-adapter`): the Apple-signed
/// `/usr/bin/perl` is entitled to MediaRemote and loads the bundled helper framework, which prints
/// JSON lines. Nothing here touches the main thread; callers hop back themselves.
public struct MediaAdapter: Sendable {
    public let script: URL
    public let framework: URL
    public let testClient: URL?
    static let perl = "/usr/bin/perl"

    public init(script: URL, framework: URL, testClient: URL?) {
        self.script = script; self.framework = framework; self.testClient = testClient
    }

    /// The bundled adapter (`Contents/Resources`, `Contents/Frameworks`, `Contents/MacOS`), or
    /// `GLANCY_MEDIA_ADAPTER_DIR` (a CMake build dir holding the three), or — debug builds run
    /// from the repo — `build/mediaremote-adapter`.
    public static func locate() -> MediaAdapter? {
        let fm = FileManager.default
        let b = Bundle.main
        if let script = b.url(forResource: "mediaremote-adapter", withExtension: "pl"),
           let fw = b.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework"),
           fm.fileExists(atPath: fw.path) {
            return MediaAdapter(script: script, framework: fw,
                                testClient: b.url(forAuxiliaryExecutable: "MediaRemoteAdapterTestClient"))
        }
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["GLANCY_MEDIA_ADAPTER_DIR"] { dirs.append(URL(fileURLWithPath: env)) }
        #if DEBUG
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        dirs.append(repo.appendingPathComponent("build/mediaremote-adapter"))
        #endif
        for dir in dirs {
            let fw = dir.appendingPathComponent("MediaRemoteAdapter.framework")
            let candidates = [dir.appendingPathComponent("mediaremote-adapter.pl"),
                              dir.deletingLastPathComponent().deletingLastPathComponent()
                                  .appendingPathComponent("Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl")]
            guard fm.fileExists(atPath: fw.path), let script = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else { continue }
            let tc = dir.appendingPathComponent("MediaRemoteAdapterTestClient")
            return MediaAdapter(script: script, framework: fw, testClient: fm.isExecutableFile(atPath: tc.path) ? tc : nil)
        }
        return nil
    }

    func arguments(_ command: [String]) -> [String] {
        [script.path, framework.path] + (testClient.map { [$0.path] } ?? []) + command
    }

    // MARK: One-shot commands

    /// `test`: exit 0 = the adapter works on this macOS. Falls back to `get` succeeding when the
    /// test client is missing. 10 s timeout (boring.notch's MediaChecker).
    public func healthCheck() async -> Bool {
        if testClient != nil {
            let r = await Self.run(arguments(["test"]), timeout: 10)
            return r.status == 0
        }
        let r = await Self.run(arguments(["get", "--no-artwork", "--micros"]), timeout: 10)
        return r.status == 0 && AdapterParser.parseGet(r.output) != nil
    }

    /// `get` once, with artwork (base64, possibly hundreds of KB) unless `artwork` is false.
    public func fetch(artwork: Bool) async -> (update: AdapterUpdate, artwork: Data?)? {
        var cmd = ["get", "--micros"]
        if !artwork { cmd.append("--no-artwork") }
        let r = await Self.run(arguments(cmd), timeout: 5)
        guard r.status == 0 else { return nil }
        return AdapterParser.parseGet(r.output)
    }

    struct RunResult: Sendable { var status: Int32; var output: Data }

    /// Runs perl with a timeout, reading stdout fully off-thread (no pipe-buffer deadlock).
    static func run(_ args: [String], timeout: TimeInterval) async -> RunResult {
        await withCheckedContinuation { (cont: CheckedContinuation<RunResult, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: perl)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: RunResult(status: -1, output: Data())); return }
                let pid = p.processIdentifier
                ChildProcesses.register(pid)
                defer { ChildProcesses.unregister(pid) }
                let killer = DispatchWorkItem { kill(pid, SIGKILL) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
                p.waitUntilExit()
                killer.cancel()
                let status = p.terminationReason == .uncaughtSignal ? -2 : p.terminationStatus
                cont.resume(returning: RunResult(status: status, output: data))
            }
        }
    }
}

/// The long-lived `stream --no-diff --no-artwork --debounce=200 --micros` child. Lines are split
/// and parsed on the pipe's background queue; `onUpdate` and `onExit` are called there too.
public final class AdapterStream: @unchecked Sendable {
    public static let streamArguments = ["stream", "--no-diff", "--no-artwork", "--debounce=200", "--micros"]

    private let lock = NSLock()
    private var process: Process?
    private var buffer = Data()
    private var stopping = false

    /// Where the child's pid is kept for orphan reaping (tests use their own file).
    let pidFileURL: URL

    public init() { pidFileURL = Self.pidFile }
    init(pidFile: URL) { pidFileURL = pidFile }

    public var isRunning: Bool { lock.withLock { process?.isRunning == true } }
    /// The child's pid while it runs (diagnostics, tests).
    var pid: Int32? { lock.withLock { process?.isRunning == true ? process?.processIdentifier : nil } }

    /// Starts the child. `onExit(expected)` — expected is false when it died on its own.
    public func start(_ adapter: MediaAdapter, onUpdate: @escaping @Sendable (AdapterUpdate) -> Void,
                      onExit: @escaping @Sendable (_ expected: Bool) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard process == nil else { return true }
        Self.reapOrphan(pidFileURL)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: MediaAdapter.perl)
        p.arguments = adapter.arguments(Self.streamArguments)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        buffer = Data()
        stopping = false
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            if chunk.isEmpty { fh.readabilityHandler = nil; return }
            self?.consume(chunk, onUpdate)
        }
        p.terminationHandler = { [weak self] proc in
            ChildProcesses.unregister(proc.processIdentifier)
            guard let self else { return }
            let expected: Bool = self.lock.withLock {
                let e = self.stopping
                if self.process === proc { self.process = nil }
                return e
            }
            Self.writePID(nil, to: self.pidFileURL)
            onExit(expected)
        }
        do { try p.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return false
        }
        process = p
        ChildProcesses.register(p.processIdentifier)
        Self.writePID(p.processIdentifier, to: pidFileURL)
        return true
    }

    /// SIGTERM (the adapter exits cleanly on it).
    public func stop() {
        let p: Process? = lock.withLock {
            stopping = true
            let p = process
            return p
        }
        guard let p, p.isRunning else { return }
        p.terminate()
    }

    private func consume(_ chunk: Data, _ onUpdate: @Sendable (AdapterUpdate) -> Void) {
        let lines: [Data] = lock.withLock {
            buffer.append(chunk)
            var out: [Data] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                out.append(buffer[buffer.startIndex..<nl])
                buffer = Data(buffer[buffer.index(after: nl)...])
            }
            // A runaway line without newline (never seen) must not grow forever.
            if buffer.count > 4 << 20 { buffer = Data() }
            return out
        }
        // With --debounce only the last state of a burst matters.
        for line in lines.reversed() {
            if let u = AdapterParser.parseStreamLine(line) { onUpdate(u); break }
        }
    }

    // MARK: Orphans

    /// If Glancy died, its perl child lingers until its next write; the next launch kills it.
    static var pidFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glancy/media-adapter.pid")
    }

    static func writePID(_ pid: Int32?, to url: URL = pidFile) {
        if let pid {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? String(pid).write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func reapOrphan(_ pidFile: URL = pidFile) {
        guard let s = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else { return }
        defer { writePID(nil, to: pidFile) }
        // Only a perl whose parent is gone (re-parented to launchd) and that runs our script.
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
              info.pbi_ppid == 1 else { return }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == MediaAdapter.perl else { return }
        kill(pid, SIGTERM)
    }
}
