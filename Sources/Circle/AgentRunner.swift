import Foundation
import Observation
import CircleCore

@MainActor @Observable
final class AgentRun: Identifiable {
    enum Status: String { case running, done, failed, cancelled }
    let id = Todo.newID()
    let todoID: String
    let agent: String
    let model: String
    let cwd: String
    let startedAt = Clock.now()
    var endedAt: Int64?
    var status: Status = .running
    var output = ""
    @ObservationIgnored var process: Process?

    init(todoID: String, agent: String, model: String, cwd: String) {
        self.todoID = todoID; self.agent = agent; self.model = model; self.cwd = cwd
    }
}

/// Launches agent CLIs and streams their output into AgentRun objects.
@MainActor @Observable
final class AgentRunner {
    private(set) var runs: [String: AgentRun] = [:]   // latest run per todo
    @ObservationIgnored private let store: Store
    @ObservationIgnored private let registry: AgentRegistry

    init(store: Store, registry: AgentRegistry) {
        self.store = store
        self.registry = registry
    }

    func run(for todoID: String) -> AgentRun? { runs[todoID] }

    func isRunning(_ todoID: String) -> Bool { runs[todoID]?.status == .running }

    static func prompt(for t: Todo, subtasks: [Todo] = []) -> String {
        var p = "Task from my Circle todo list (id \(t.id)):\n\n\(t.title)\n"
        if !t.notes.isEmpty { p += "\nNotes:\n\(t.notes)\n" }
        if !subtasks.isEmpty {
            p += "\nSubtasks:\n" + subtasks.map { "\($0.glyph) \($0.id)  \($0.title)" }.joined(separator: "\n") + "\n"
            p += "Complete each subtask with complete_todo as you finish it.\n"
        }
        p += """

        Do the task in the current working directory. You have a `circle` MCP server for my todo list: \
        when the task is fully done, call complete_todo with id "\(t.id)". If you are blocked on something \
        only I can provide (a decision, credentials, access), call hand_back with the id and what you need. \
        If you discover follow-up work, add it with add_todo using parent "\(t.id)" so it nests under this task. Finish with a short summary of what you did.
        """
        return p
    }

    @discardableResult
    func start(_ t: Todo) -> AgentRun? {
        guard !isRunning(t.id), let def = registry.current, let bin = registry.paths[def.id] else { return nil }
        let cwd = registry.cwd
        let r = AgentRun(todoID: t.id, agent: def.id, model: registry.model, cwd: cwd)
        runs[t.id] = r

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = def.args(Self.prompt(for: t, subtasks: store.children(t.id)), registry.model, registry.autonomy, AgentRegistry.mcpPath, cwd)
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = registry.shellPATH
        env["CIRCLE_TODO_ID"] = t.id
        env["NO_COLOR"] = "1"
        p.environment = env
        p.standardInput = FileHandle.nullDevice

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let parser = LineParser(json: def.streamJSON)
        let errParser = LineParser(json: false)

        out.fileHandleForReading.readabilityHandler = { [weak r] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            let text = parser.feed(d)
            if !text.isEmpty { DispatchQueue.main.async { r?.output += text } }
        }
        err.fileHandleForReading.readabilityHandler = { [weak r] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            let text = errParser.feed(d)
            if !text.isEmpty { DispatchQueue.main.async { r?.output += text } }
        }
        p.terminationHandler = { [weak self, weak r] proc in
            let code = proc.terminationStatus
            let reason = proc.terminationReason
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { // let pipes drain
                guard let r else { return }
                if r.status == .running {
                    r.status = (reason == .uncaughtSignal) ? .cancelled : (code == 0 ? .done : .failed)
                }
                if code != 0 && r.status == .failed { r.output += "\n[exit \(code)]\n" }
                r.endedAt = Clock.now()
                r.process = nil
                self?.store.saveRun(r)
            }
        }
        r.output = "$ \(def.id) · \(registry.model) · \(registry.autonomy.rawValue) · \(abbreviate(cwd))\n\n"
        do {
            try p.run()
            r.process = p
        } catch {
            r.status = .failed
            r.output = "failed to launch \(bin): \(error.localizedDescription)\n"
        }
        store.saveRun(r)
        return r
    }

    func cancel(_ todoID: String) {
        guard let r = runs[todoID], r.status == .running, let p = r.process else { return }
        r.status = .cancelled
        p.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if p.isRunning { p.terminate() } }
    }

    /// Loads the last persisted run for a todo when nothing is in memory.
    func loadHistory(_ todoID: String) {
        guard runs[todoID] == nil else { return }
        store.lastRun(todoID) { [weak self] rec in
            guard let self, let rec, self.runs[todoID] == nil else { return }
            let r = AgentRun(todoID: rec.todoID, agent: rec.agent, model: rec.model, cwd: rec.cwd)
            r.status = AgentRun.Status(rawValue: rec.status) ?? .done
            if r.status == .running { r.status = .cancelled } // app quit mid-run
            r.output = rec.output
            self.runs[todoID] = r
        }
    }
}

func abbreviate(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

/// Splits a byte stream into lines; for Claude's stream-json, renders events as readable text.
final class LineParser: @unchecked Sendable {
    private var buffer = Data()
    private let json: Bool
    private let lock = NSLock()

    init(json: Bool) { self.json = json }

    func feed(_ d: Data) -> String {
        lock.lock(); defer { lock.unlock() }
        buffer.append(d)
        var out = ""
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if json { out += Self.render(Data(line)) }
            else if let s = String(data: line, encoding: .utf8) { out += Self.stripANSI(s) + "\n" }
        }
        return out
    }

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    static func render(_ line: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return String(data: line, encoding: .utf8).map { $0 + "\n" } ?? ""
        }
        switch obj["type"] as? String {
        case "assistant":
            guard let msg = obj["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return "" }
            var s = ""
            for c in content {
                switch c["type"] as? String {
                case "text": s += (c["text"] as? String ?? "") + "\n"
                case "tool_use":
                    let name = (c["name"] as? String ?? "tool").replacingOccurrences(of: "mcp__circle__", with: "circle.")
                    s += "→ \(name)\(Self.toolHint(c["input"]))\n"
                default: break
                }
            }
            return s
        case "result":
            let cost = (obj["total_cost_usd"] as? Double).map { String(format: " · $%.3f", $0) } ?? ""
            let secs = (obj["duration_ms"] as? Double).map { String(format: " · %.1fs", $0 / 1000) } ?? ""
            let isErr = (obj["is_error"] as? Bool) == true
            return "\n— \(isErr ? "error" : "done")\(secs)\(cost)\n"
        default:
            return ""
        }
    }

    private static func toolHint(_ input: Any?) -> String {
        guard let i = input as? [String: Any] else { return "" }
        for k in ["file_path", "command", "pattern", "path", "url", "title", "description"] {
            if let v = i[k] as? String {
                let one = v.split(separator: "\n").first.map(String.init) ?? v
                return " " + (one.count > 80 ? String(one.prefix(80)) + "…" : one)
            }
        }
        return ""
    }
}
