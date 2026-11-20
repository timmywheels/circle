import Foundation
import Observation
import CircleCore

enum Autonomy: String, CaseIterable {
    case ask, edits, yolo
    var label: String {
        switch self {
        case .ask: return "ask (read-only)"
        case .edits: return "edits (auto-approve file edits)"
        case .yolo: return "yolo (skip all approvals)"
        }
    }
}

/// One agent CLI Circle knows how to drive. Add entries here to support more.
struct AgentDef: Identifiable {
    let id: String          // binary name
    let name: String
    let suggestedModels: [String]
    /// Builds argv (without the binary) for a one-shot run.
    let args: (_ prompt: String, _ model: String, _ autonomy: Autonomy, _ mcp: String, _ cwd: String) -> [String]
    /// Output format the runner should parse.
    let streamJSON: Bool

    static let all: [AgentDef] = [
        AgentDef(id: "claude", name: "Claude Code",
                 suggestedModels: ["opus", "sonnet", "haiku"],
                 args: { prompt, model, autonomy, mcp, _ in
                     let cfg = #"{"mcpServers":{"circle":{"command":"\#(mcp)","args":[]}}}"#
                     var a = ["-p", prompt, "--model", model, "--output-format", "stream-json", "--verbose",
                              "--mcp-config", cfg, "--allowedTools", "mcp__circle"]
                     switch autonomy {
                     case .ask: a += ["--permission-mode", "plan"]
                     case .edits: a += ["--permission-mode", "acceptEdits"]
                     case .yolo: a += ["--dangerously-skip-permissions"]
                     }
                     return a
                 }, streamJSON: true),
        AgentDef(id: "codex", name: "Codex",
                 suggestedModels: AgentDef.codexModels(),
                 args: { prompt, model, autonomy, mcp, cwd in
                     var a = ["exec", "--skip-git-repo-check", "-C", cwd,
                              "-c", "mcp_servers.circle.command=\"\(mcp)\""]
                     if !model.isEmpty && model != "default" { a += ["-m", model] }
                     switch autonomy {
                     case .ask: a += ["-s", "read-only"]
                     case .edits: a += ["--full-auto"]
                     case .yolo: a += ["--dangerously-bypass-approvals-and-sandbox"]
                     }
                     return a + [prompt]
                 }, streamJSON: false),
        AgentDef(id: "gemini", name: "Gemini CLI",
                 suggestedModels: ["gemini-2.5-pro", "gemini-2.5-flash"],
                 args: { prompt, model, autonomy, _, _ in
                     var a = ["-m", model, "-p", prompt]
                     if autonomy == .yolo { a.append("-y") }
                     return a
                 }, streamJSON: false),
        AgentDef(id: "opencode", name: "opencode",
                 suggestedModels: ["default"],
                 args: { prompt, model, _, _, _ in
                     model == "default" ? ["run", prompt] : ["run", "-m", model, prompt]
                 }, streamJSON: false),
    ]

    /// Codex's own configured default model, then a fallback.
    static func codexModels() -> [String] {
        var out = ["default"]
        let cfg = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        if let s = try? String(contentsOf: cfg, encoding: .utf8) {
            for line in s.split(separator: "\n") {
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("model") && !l.hasPrefix("model_"), let q = l.split(separator: "\"").dropFirst().first {
                    out.append(String(q)); break
                }
            }
        }
        return out
    }
}

/// Finds agent CLIs using the user's login-shell PATH (GUI apps don't inherit it).
@MainActor @Observable
final class AgentRegistry {
    private(set) var available: [AgentDef] = []
    private(set) var paths: [String: String] = [:]
    private(set) var shellPATH: String = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    private(set) var scanned = false

    var agentID: String = UserDefaults.standard.string(forKey: "agent") ?? "claude" {
        didSet { UserDefaults.standard.set(agentID, forKey: "agent") }
    }
    var model: String = UserDefaults.standard.string(forKey: "model") ?? "sonnet" {
        didSet { UserDefaults.standard.set(model, forKey: "model") }
    }
    var autonomy: Autonomy = Autonomy(rawValue: UserDefaults.standard.string(forKey: "autonomy") ?? "") ?? .edits {
        didSet { UserDefaults.standard.set(autonomy.rawValue, forKey: "autonomy") }
    }
    var cwd: String = UserDefaults.standard.string(forKey: "cwd") ?? FileManager.default.homeDirectoryForCurrentUser.path {
        didSet { UserDefaults.standard.set(cwd, forKey: "cwd") }
    }
    /// Models the user typed in, remembered per agent.
    var customModels: [String: [String]] = (UserDefaults.standard.dictionary(forKey: "customModels") as? [String: [String]]) ?? [:] {
        didSet { UserDefaults.standard.set(customModels, forKey: "customModels") }
    }

    var current: AgentDef? { available.first { $0.id == agentID } ?? available.first }

    func models(for a: AgentDef) -> [String] {
        var seen = Set<String>()
        return (a.suggestedModels + (customModels[a.id] ?? [])).filter { seen.insert($0).inserted }
    }

    func choose(_ a: AgentDef, model m: String) {
        agentID = a.id
        model = m
        if !a.suggestedModels.contains(m) && !(customModels[a.id] ?? []).contains(m) {
            customModels[a.id, default: []].append(m)
        }
    }

    func scan() {
        Task.detached(priority: .utility) {
            let path = Self.loginShellPATH()
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let extra = ["\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.bun/bin", "\(home)/.npm-global/bin",
                         "/opt/homebrew/bin", "/usr/local/bin"]
            let dirs = path.split(separator: ":").map(String.init) + extra
            var found: [String: String] = [:]
            for def in AgentDef.all {
                for d in dirs {
                    let p = (d as NSString).appendingPathComponent(def.id)
                    if FileManager.default.isExecutableFile(atPath: p) { found[def.id] = p; break }
                }
            }
            let fullPATH = (dirs.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }).joined(separator: ":")
            await MainActor.run {
                self.shellPATH = fullPATH
                self.paths = found
                self.available = AgentDef.all.filter { found[$0.id] != nil }
                self.scanned = true
                // Keep the saved choice valid.
                if let cur = self.current, cur.id != self.agentID {
                    self.agentID = cur.id
                    self.model = cur.suggestedModels.first ?? "default"
                }
            }
        }
    }

    nonisolated static func loginShellPATH() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "printf '__CIRCLE__%s' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return ProcessInfo.processInfo.environment["PATH"] ?? "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(data: data, encoding: .utf8) ?? ""
        guard let r = s.range(of: "__CIRCLE__") else { return ProcessInfo.processInfo.environment["PATH"] ?? "" }
        return String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Path to the circle-mcp binary inside the app bundle.
    static var mcpPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/circle-mcp").path
    }

    /// Registers circle-mcp globally with installed agents so they can manage todos
    /// in any session, not only runs started from Circle.
    func installMCP() -> String {
        var notes: [String] = []
        let mcp = Self.mcpPath
        if let claude = paths["claude"] {
            let r = Self.run(claude, ["mcp", "add", "--scope", "user", "circle", "--", mcp], path: shellPATH)
            notes.append(r.ok || r.out.contains("already exists") ? "claude ✓" : "claude ✗")
        }
        if paths["codex"] != nil {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
            var s = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if !s.contains("[mcp_servers.circle]") {
                s += "\n[mcp_servers.circle]\ncommand = \"\(mcp)\"\n"
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                notes.append((try? s.write(to: url, atomically: true, encoding: .utf8)) != nil ? "codex ✓" : "codex ✗")
            } else { notes.append("codex ✓") }
        }
        return notes.isEmpty ? "no agents found" : "mcp installed: " + notes.joined(separator: "  ")
    }

    nonisolated static func run(_ bin: String, _ args: [String], path: String) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (false, "\(error)") }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(data: d, encoding: .utf8) ?? "")
    }
}
