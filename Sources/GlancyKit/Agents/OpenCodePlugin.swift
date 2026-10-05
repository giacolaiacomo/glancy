import Foundation

/// Installs / removes Glancy's OpenCode plugin. Writes only when the user clicks Install or
/// Uninstall in Settings → Agents: one file, `~/.config/opencode/plugins/glancy.js` (OpenCode loads
/// every file in that folder at startup). `opencode.json` is never read or written. A different
/// file already at that path is moved aside to `glancy.js.backup-<time>` first.
struct OpenCodePluginInstaller: Sendable {
    nonisolated static let defaultPluginsFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/opencode/plugins", isDirectory: true)

    var pluginsFolder: URL = OpenCodePluginInstaller.defaultPluginsFolder
    var pluginURL: URL { pluginsFolder.appendingPathComponent("glancy.js") }

    /// Our file is there (recognised by its first line).
    var isInstalled: Bool {
        guard let head = try? FileHandle(forReadingFrom: pluginURL).read(upToCount: 200) else { return false }
        return String(decoding: head, as: UTF8.self).hasPrefix(Self.marker)
    }

    /// The plugin is there but older than the one this build ships.
    var isOutdated: Bool {
        isInstalled && (try? String(contentsOf: pluginURL, encoding: .utf8)) != Self.source
    }

    enum Failure: Error, Equatable { case write(String) }

    /// Writes the plugin (backing up a foreign file at the same path). Returns the backup, if any.
    @discardableResult
    func install(now: Date = .now) throws -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: pluginsFolder, withIntermediateDirectories: true)
            var backup: URL?
            if fm.fileExists(atPath: pluginURL.path), !isInstalled {
                let stamp = Int(now.timeIntervalSince1970)
                let b = pluginsFolder.appendingPathComponent("glancy.js.backup-\(stamp)")
                try fm.moveItem(at: pluginURL, to: b)
                backup = b
            }
            try Data(Self.source.utf8).write(to: pluginURL, options: .atomic)
            return backup
        } catch {
            throw Failure.write(error.localizedDescription)
        }
    }

    /// Removes the plugin, only if the file is ours.
    func uninstall() throws {
        guard isInstalled else { return }
        do { try FileManager.default.removeItem(at: pluginURL) } catch { throw Failure.write(error.localizedDescription) }
    }

    static let marker = "// Glancy plugin for OpenCode"

    /// hooks/glancy-opencode.js, verbatim (a test keeps the two identical).
    static let source = #"""
// Glancy plugin for OpenCode: appends one compact JSON line per session event to
//   ~/Library/Application Support/Glancy/agents/opencode-events.jsonl   (rotated to .1 at ~5 MB)
// so Glancy's Agents tab can show when a session is working, done, failed or waiting for a
// permission. Read-only observer: it never answers, blocks or changes anything in OpenCode, and
// any error is swallowed. Keeps only: time, event, session id, folder, tool name, the first 200
// characters of the prompt and of the reply, and which app OpenCode runs in.
// Installed by Glancy (Settings → Agents → OpenCode → Install) as ~/.config/opencode/plugins/glancy.js.
import { appendFileSync, mkdirSync, renameSync, statSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"

const OUT = join(homedir(), "Library", "Application Support", "Glancy", "agents", "opencode-events.jsonl")

export const GlancyPlugin = async ({ directory }) => {
  const env = process.env
  const host = { host_bundle: env.__CFBundleIdentifier, term_program: env.TERM_PROGRAM }
  const children = new Set()   // subagent sessions: reported through their parent only
  let ready = false

  const write = (event, sessionID, extra = {}) => {
    if (!sessionID || children.has(sessionID)) return
    try {
      if (!ready) { mkdirSync(dirname(OUT), { recursive: true }); ready = true }
      try { if (statSync(OUT).size > 5000000) renameSync(OUT, OUT + ".1") } catch {}
      const line = { ts: Date.now(), event, session_id: sessionID, cwd: directory, agent: "opencode", ...host, ...extra }
      for (const k of Object.keys(line)) if (line[k] === undefined || line[k] === null || line[k] === "") delete line[k]
      appendFileSync(OUT, JSON.stringify(line) + "\n")
    } catch {}
  }
  const cut = (s) => (typeof s === "string" ? s.slice(0, 200) : undefined)

  return {
    event: async ({ event }) => {
      const p = event?.properties ?? {}
      switch (event?.type) {
        case "session.created":
          if (p.info?.parentID) { children.add(p.info.id); return }
          write("SessionStart", p.info?.id, { title: cut(p.info?.title) })
          return
        case "session.updated":
          if (p.info?.parentID) { children.add(p.info.id); return }
          return
        case "session.status":
          if (p.status?.type === "busy") write("UserPromptSubmit", p.sessionID)
          return
        case "session.idle":
          write("Stop", p.sessionID)
          return
        case "session.error":
          if (p.error?.name === "MessageAbortedError") write("Interrupted", p.sessionID)
          else write("StopFailure", p.sessionID, { message: cut(p.error?.data?.message ?? p.error?.name) })
          return
        case "permission.asked":
        case "permission.updated":
          write("PermissionRequest", p.sessionID, { tool_name: p.permission ?? p.type ?? p.action ?? "permission" })
          return
        case "permission.replied":
          write("PostToolUse", p.sessionID, { tool_name: "permission" })
          return
        case "session.deleted":
          write("SessionEnd", p.info?.id, { reason: "deleted" })
          return
      }
    },
    "chat.message": async (input, output) => {
      const text = (output?.parts ?? []).find((x) => x?.type === "text")?.text
      write("UserPromptSubmit", input?.sessionID, { prompt: cut(text) })
    },
    "tool.execute.after": async (input) => {
      write("PostToolUse", input?.sessionID, { tool_name: input?.tool })
    },
  }
}

"""#
}
