import Foundation
import CryptoKit
import CircleCore

// Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0).
// Writes go straight into Circle's SQLite database; the app notices within
// ~250ms and syncs them to the cloud.

setvbuf(stdout, nil, _IOLBF, 0)

// `circle-mcp --when "fri 2pm every week"` prints how a reminder phrase parses.
// Self-test of the end-to-end encryption (run by build/test-vault.command).
// `circle-mcp --vault-interop in.json out.json`: opens a row sealed by the phone app (fixed test key
// 1...32) and seals one for it, so both implementations are checked against each other.
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--vault-interop" {
    struct Pack: Codable { let row: SealedRow; let keycheck: String }
    let v = Vault(key: SymmetricKey(data: (1...32).map { UInt8($0) }))
    let pack = try! JSONDecoder().decode(Pack.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    let t = try! v.open(pack.row)
    print("JS_ROW_OPENED kind=\(t.kind.rawValue) title=\(t.title) notes=\(t.notes.debugDescription) sort=\(t.sort) remindAt=\(t.remindAt) origin=\(t.origin)")
    print("JS_KEYCHECK \(v.verify(keyCheck: pack.keycheck))")
    print("RECOVERY \(v.recoveryKey)")
    print("VAULT_WORK_KEY " + v.forVault("work").key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined())
    let mine = Todo(kind: .agent, parent: "p1", title: "from the mac ✓", notes: "n", sort: 2.5, origin: "mac1", remindAt: 1_800_000_000_000, repeatRule: "weekdays")
    let out = Pack(row: try! v.seal(mine), keycheck: try! v.keyCheck())
    try! JSONEncoder().encode(out).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
    exit(0)
}

if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--vault-selftest" {
    func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { exit(1) } }
    let v = Vault.generate()
    var t = Todo(kind: .agent, parent: "p1", title: "secret plan [[x]]", notes: "notes ✓", sort: 3.5, origin: "mac1",
                 remindAt: 1_800_000_000_000, repeatRule: "weekdays")
    t.setDone(true)
    let row = try! v.seal(t)
    check(!row.blob.contains("secret") && !row.blob.contains("plan"), "blob doesn't contain the plaintext")
    let back = try! v.open(row)
    check(back == t, "seal → open round-trips every field")
    var moved = row; moved.id = "other"
    check((try? v.open(moved)) == nil, "a blob moved to another id is rejected")
    let other = Vault.generate()
    check((try? other.open(row)) == nil, "another account's key can't open it")
    let rk = v.recoveryKey
    check(rk.count == 64 && rk.split(separator: "-").count == 13, "recovery key is 13 groups of 4 (\(rk.prefix(9))…)")
    let restored = Vault(recoveryKey: rk.lowercased().replacingOccurrences(of: "-", with: " "))
    check(restored.map { (try? $0.open(row)) == t } == true, "recovery key (any case, spaces) restores the key")
    check(Vault(recoveryKey: "nope") == nil, "garbage recovery key refused")
    let kc = try! v.keyCheck()
    check(v.verify(keyCheck: kc) && !other.verify(keyCheck: kc), "key check accepts the right key only")
    print("VAULT_SELFTEST_OK")
    exit(0)
}

// End-to-end: the app's sealing against the real server code (a local `wrangler dev`).
// circle-mcp --sync-selftest <base-url> <session-secret>
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--sync-selftest" {
    let base = CommandLine.arguments[2], secret = CommandLine.arguments[3]
    func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { exit(1) } }
    func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func session(_ user: String) -> String {
        let body = "v1.\(b64url(Data(user.utf8))).\(Int(Date().timeIntervalSince1970) + 3600)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return body + "." + b64url(Data(mac))
    }
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let user = "selftest-\(UUID().uuidString.prefix(8))"
            let tok = session(user)
            let vault = Vault.generate()
            // key check round trip
            var put = URLRequest(url: URL(string: base + "/api/keycheck")!)
            put.httpMethod = "PUT"; put.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            put.setValue("application/json", forHTTPHeaderField: "Content-Type")
            put.httpBody = try JSONSerialization.data(withJSONObject: ["keycheck": try vault.keyCheck()])
            let (_, pr) = try await URLSession.shared.data(for: put)
            check((pr as? HTTPURLResponse)?.statusCode == 200, "key check stored")
            var get = URLRequest(url: URL(string: base + "/api/keycheck")!)
            get.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            let (gd, _) = try await URLSession.shared.data(for: get)
            let kc = (try JSONSerialization.jsonObject(with: gd) as? [String: Any])?["keycheck"] as? String
            check(kc.map { vault.verify(keyCheck: $0) } == true, "key check verifies with the account key")
            check(kc.map { Vault.generate().verify(keyCheck: $0) } == false, "key check rejects a different key")

            func socket() -> URLSessionWebSocketTask {
                var r = URLRequest(url: URL(string: base.replacingOccurrences(of: "http", with: "ws") + "/sync")!)
                r.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
                let t = URLSession.shared.webSocketTask(with: r); t.resume(); return t
            }
            struct Frame: Decodable { let t: String; let rows: [SealedRow]?; let cursor: Int64? }
            func next(_ t: URLSessionWebSocketTask) async throws -> Frame {
                let m = try await t.receive()
                guard case .string(let s) = m else { throw VaultError.corrupt }
                return try JSONDecoder().decode(Frame.self, from: Data(s.utf8))
            }
            let a = socket(), b = socket()
            try await a.send(.string("{\"t\":\"hello\",\"since\":0}")); _ = try await next(a)
            try await b.send(.string("{\"t\":\"hello\",\"since\":0}")); _ = try await next(b)

            let todos = (0..<3).map { i in Todo(kind: i == 1 ? .agent : .mine, parent: "", title: "secret \(i) [[link]]", notes: "n\(i)", sort: Double(i), origin: "macA") }
            let sealed = try todos.map { try vault.seal($0) }
            let push = String(data: try JSONEncoder().encode(sealed), encoding: .utf8)!
            try await a.send(.string("{\"t\":\"push\",\"rows\":\(push)}"))
            let echo = try await next(a)
            check(echo.rows?.count == 3, "server echoes all 3 sealed rows")
            let got = try await next(b)
            let opened = try (got.rows ?? []).map { try vault.open($0) }.sorted { $0.sort < $1.sort }
            check(opened == todos, "second device receives and decrypts identical todos")
            check(!(got.rows ?? []).contains { $0.blob.contains("secret") }, "server only ever relays ciphertext")
            a.cancel(); b.cancel()
            print("SYNC_SELFTEST_OK")
            sem.signal()
        } catch {
            print("FAIL \(error)"); exit(1)
        }
    }
    sem.wait()
    exit(0)
}

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--when" {
    for phrase in CommandLine.arguments.dropFirst(2) {
        if let p = When.parse(phrase) {
            print("\(phrase) => \(p.date.formatted(.dateTime.weekday().month().day().hour().minute())) [\(p.rule.isEmpty ? "once" : p.rule)]")
        } else { print("\(phrase) => (none)") }
    }
    exit(0)
}

let repo: TodoRepo = {
    // Agents work in the vault that's open in the app.
    do { return try TodoRepo(vault: Paths.currentVault) } catch {
        FileHandle.standardError.write("circle-mcp: cannot open database: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}()
let origin = repo.device + ".mcp"

func send(_ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(d)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func reply(_ id: Any, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
func fail(_ id: Any, _ code: Int, _ msg: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": msg]])
}

func text(_ s: String, error: Bool = false) -> [String: Any] {
    ["content": [["type": "text", "text": s]], "isError": error]
}

func line(_ t: Todo) -> String {
    let when = t.remindAt > 0 && !t.done ? "  remind " + When.long(t.remindAt, rule: t.repeatRule) : ""
    return "\(t.glyph) \(t.id)  \(t.title)\(when)" + (t.notes.isEmpty ? "" : "\n      " + t.notes.replacingOccurrences(of: "\n", with: "\n      "))
}

let tools: [[String: Any]] = [
    ["name": "list_todos",
     "description": "List todos in the user's Circle todo list. Shapes show who each item is waiting on: ○ the user, △ an agent, □ something external. Filled (● ▲ ■) means done.",
     "inputSchema": ["type": "object", "properties": [
        "include_done": ["type": "boolean", "description": "Include completed todos (default false)"],
        "kind": ["type": "string", "enum": ["todo", "agent", "wait"], "description": "Only this shape: todo ○, agent △, wait □"],
        "query": ["type": "string", "description": "Optional case-insensitive text filter"]]]],
    ["name": "add_todo",
     "description": "Add a todo to the top of the user's list.",
     "inputSchema": ["type": "object", "required": ["title"], "properties": [
        "title": ["type": "string"], "notes": ["type": "string"],
        "kind": ["type": "string", "enum": ["todo", "agent", "wait"], "description": "Default todo (the user's)"],
        "parent": ["type": "string", "description": "Id of a todo to nest this under, as a subtask"],
        "remind": ["type": "string", "description": "When to remind the user, in plain words: \"tomorrow 9am\", \"fri 2pm every week\", \"30m\""]]]],
    ["name": "update_todo",
     "description": "Change a todo's title, notes or done state. id may be a unique prefix.",
     "inputSchema": ["type": "object", "required": ["id"], "properties": [
        "id": ["type": "string"], "title": ["type": "string"], "notes": ["type": "string"], "done": ["type": "boolean"],
        "kind": ["type": "string", "enum": ["todo", "agent", "wait"]],
        "parent": ["type": "string", "description": "Nest under this todo id, or \"\" for top level"],
        "remind": ["type": "string", "description": "Reminder in plain words, or \"none\" to clear"]]]],
    ["name": "hand_back",
     "description": "Give a todo back when you are blocked on something only the user or the outside world can provide. It becomes □ waiting with your reason appended to its notes.",
     "inputSchema": ["type": "object", "required": ["id", "reason"], "properties": [
        "id": ["type": "string"], "reason": ["type": "string", "description": "What you need, in one or two sentences"]]]],
    ["name": "complete_todo",
     "description": "Mark a todo as done. id may be a unique prefix.",
     "inputSchema": ["type": "object", "required": ["id"], "properties": ["id": ["type": "string"]]]],
    ["name": "delete_todo",
     "description": "Delete a todo. id may be a unique prefix.",
     "inputSchema": ["type": "object", "required": ["id"], "properties": ["id": ["type": "string"]]]],
]

func call(_ name: String, _ a: [String: Any]) throws -> [String: Any] {
    switch name {
    case "list_todos":
        let includeDone = a["include_done"] as? Bool ?? false
        let q = (a["query"] as? String)?.lowercased()
        let kind = (a["kind"] as? String).flatMap(Kind.init(rawValue:))
        var items = try repo.all(includeDeleted: false).filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty && (includeDone || !$0.done) && (kind == nil || $0.kind == kind) }
        if let q, !q.isEmpty { items = items.filter { $0.title.lowercased().contains(q) || $0.notes.lowercased().contains(q) } }
        // Render as an indented tree (children under their parent).
        let ids = Set(items.map(\.id))
        var kids: [String: [Todo]] = [:]
        for t in items { kids[ids.contains(t.parent) ? t.parent : "", default: []].append(t) }
        for k in kids.keys { kids[k]!.sort { $0.done != $1.done ? !$0.done : $0.sort < $1.sort } }
        var out: [String] = [], seen = Set<String>()
        func walk(_ p: String, _ level: Int) {
            for t in kids[p] ?? [] where seen.insert(t.id).inserted {
                out.append(String(repeating: "    ", count: level) + line(t))
                walk(t.id, level + 1)
            }
        }
        walk("", 0)
        return text(out.isEmpty ? "No todos." : out.joined(separator: "\n"))
    case "add_todo":
        guard let title = (a["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return text("title is required", error: true)
        }
        let kind = (a["kind"] as? String).flatMap(Kind.init(rawValue:)) ?? .mine
        var parent = ""
        var sort = try repo.minSort() - 1
        if let pid = a["parent"] as? String, !pid.isEmpty {
            guard let p = try repo.find(pid) else { return text("No unique todo matches parent \(pid)", error: true) }
            parent = p.id
            sort = (try repo.all(includeDeleted: false).filter { $0.parent == p.id }.map(\.sort).max() ?? 0) + 1
        }
        var t = Todo(kind: kind, parent: parent, title: title, notes: a["notes"] as? String ?? "", sort: sort, origin: origin)
        if let r = a["remind"] as? String, !r.isEmpty {
            guard let p = When.parse(r) else { return text("Could not read reminder time \"\(r)\"", error: true) }
            t.remindAt = Int64(p.date.timeIntervalSince1970 * 1000); t.repeatRule = p.rule
        }
        try repo.saveLocal(t)
        return text("Added: " + line(t))
    case "update_todo", "complete_todo", "delete_todo", "hand_back":
        guard let id = a["id"] as? String, var t = try repo.find(id) else {
            return text("No unique todo matches id \((a["id"] as? String) ?? "")", error: true)
        }
        if name == "complete_todo" { t.setDone(true) }
        else if name == "delete_todo" { t.deleted = true }
        else if name == "hand_back" {
            let reason = (a["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            t.kind = .waiting
            t.notes = (t.notes.isEmpty ? "" : t.notes + "\n\n") + "Waiting: " + (reason.isEmpty ? "agent needs input" : reason)
        }
        else {
            if let v = a["title"] as? String, !v.isEmpty { t.title = v }
            if let v = a["notes"] as? String { t.notes = v }
            if let v = a["done"] as? Bool, v != t.done { t.setDone(v) }
            if let v = (a["kind"] as? String).flatMap(Kind.init(rawValue:)) { t.kind = v }
            if let r = a["remind"] as? String {
                if r.isEmpty || r == "none" { t.remindAt = 0; t.repeatRule = "" }
                else if let p = When.parse(r) { t.remindAt = Int64(p.date.timeIntervalSince1970 * 1000); t.repeatRule = p.rule }
                else { return text("Could not read reminder time \"\(r)\"", error: true) }
            }
            if let pid = a["parent"] as? String {
                if pid.isEmpty { t.parent = "" }
                else if let p = try repo.find(pid), p.id != t.id { t.parent = p.id }
                else { return text("No unique todo matches parent \(pid)", error: true) }
            }
        }
        t = t.touched(by: origin)
        try repo.saveLocal(t)
        return text((name == "delete_todo" ? "Deleted: " : name == "hand_back" ? "Handed back: " : "Updated: ") + line(t))
    default:
        throw NSError(domain: "circle", code: -32602, userInfo: [NSLocalizedDescriptionKey: "unknown tool \(name)"])
    }
}

while let raw = readLine(strippingNewline: true) {
    guard !raw.isEmpty, let d = raw.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let method = msg["method"] as? String else { continue }
    let id = msg["id"]
    let params = msg["params"] as? [String: Any] ?? [:]
    guard let id else { continue } // notifications need no reply

    switch method {
    case "initialize":
        reply(id, ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                   "capabilities": ["tools": [:]],
                   "serverInfo": ["name": "circle", "version": "0.1.0"],
                   "instructions": "Circle is the user's personal todo list. Use it to read, add and complete their todos."])
    case "ping":
        reply(id, [:])
    case "tools/list":
        reply(id, ["tools": tools])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do { reply(id, try call(name, args)) }
        catch { reply(id, text("Error: \(error.localizedDescription)", error: true)) }
    default:
        fail(id, -32601, "method not found: \(method)")
    }
}
