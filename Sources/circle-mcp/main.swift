import Foundation
import CircleCore

// Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0).
// Writes go straight into Circle's SQLite database; the app notices within
// ~250ms and syncs them to the cloud.

setvbuf(stdout, nil, _IOLBF, 0)

let repo: TodoRepo = {
    do { return try TodoRepo() } catch {
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
    "\(t.glyph) \(t.id)  \(t.title)" + (t.notes.isEmpty ? "" : "\n      " + t.notes.replacingOccurrences(of: "\n", with: "\n      "))
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
        "parent": ["type": "string", "description": "Id of a todo to nest this under, as a subtask"]]]],
    ["name": "update_todo",
     "description": "Change a todo's title, notes or done state. id may be a unique prefix.",
     "inputSchema": ["type": "object", "required": ["id"], "properties": [
        "id": ["type": "string"], "title": ["type": "string"], "notes": ["type": "string"], "done": ["type": "boolean"],
        "kind": ["type": "string", "enum": ["todo", "agent", "wait"]],
        "parent": ["type": "string", "description": "Nest under this todo id, or \"\" for top level"]]]],
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
        var items = try repo.all(includeDeleted: false).filter { (includeDone || !$0.done) && (kind == nil || $0.kind == kind) }
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
        let t = Todo(kind: kind, parent: parent, title: title, notes: a["notes"] as? String ?? "", sort: sort, origin: origin)
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
