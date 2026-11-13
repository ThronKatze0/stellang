// A JSON API + a WebSocket feed, modeled with structs and enums.
// Run: stellang examples/todos.st && ./todos   then open http://localhost:8080
//
//   curl localhost:8080/todos
//   curl -X POST localhost:8080/todos -d '{"title": "write docs", "priority": "High"}'
//   curl -X PATCH localhost:8080/todos/1/done
//   websocat ws://localhost:8080/feed        (every change is pushed here)

import http
import json

enum Priority { Low, Normal, High }

enum Status {
    Open,
    Done { at: int },
}

struct Todo {
    id: int,
    title: str,
    priority: Priority = .Normal,
    status: Status = .Open,
    note: str?,
}

enum Event {
    Added(Todo),
    Completed(id: int),
    Removed(id: int),
}

struct Store {
    todos: [Todo] = [],
    next: int = 1,

    fn add(self, title: str, priority: Priority) -> Todo {
        let t = Todo { id: self.next, title, priority }
        self.next += 1
        self.todos.push(t)
        return t
    }

    fn find(self, id: int) -> Todo? {
        return self.todos.find(t => t.id == id)
    }
}

fn priority(s: str) -> Priority! {
    return match s {
        "Low" | "low" => .Low,
        "Normal" | "normal" | "" => .Normal,
        "High" | "high" => .High,
        _ => err("priority must be Low, Normal or High, not \"${s}\""),
    }
}

fn main() -> void! {
    let app = http.app()
    let store = Store {}
    store.add("try stellang", .High)

    // tell every connected feed about a change
    let publish = (e: Event) => {
        for ws in app.clients("/feed") { ws.send(to_json(e)) }
    }

    // middleware: a request id header on every response, and an API key for writes
    var requests = 0
    app.use((req, res, next) => {
        requests += 1
        res.set("x-request-id", str(requests))
        next()
    })
    app.use_at("/todos", (req, res, next) => {
        if req.method != "GET" && (req.header("x-api-key") ?? "dev") != "dev" {
            res.status(401).send("bad api key")
            return
        }
        next()
    })

    app.get("/todos", (req, res) => {
        let only = req.query.get("status")
        let list = store.todos.filter(t => match only {
            some("open") => t.status == .Open,
            some("done") => t.status != .Open,
            _ => true,
        })
        res.json(to_json(list))
    })

    app.get("/todos/:id", (req, res) => {
        let id = int(req.param("id"))?
        let t = store.find(id) else {
            res.status(404).json(to_json({"error": "no todo ${id}"}))
            return
        }
        res.json(to_json(t))
    })

    app.post("/todos", (req, res) => {
        let body = req.json()?
        let title = body.get("title")?.as_str() else {
            res.status(422).json(to_json({"error": "title is required"}))
            return
        }
        let t = store.add(title, priority(body.get("priority")?.as_str() ?? "")?)
        t.note = body.get("note")?.as_str()
        publish(.Added(t))
        res.status(201).json(to_json(t))
    })

    app.patch("/todos/:id/done", (req, res) => {
        let t = store.find(int(req.param("id"))?) else { return res.status(404).end() }
        if let Done { at } = t.status {
            res.status(409).send("already done at ${at}")
            return
        }
        t.status = .Done { at: now_ms() }
        publish(.Completed(t.id))
        res.json(to_json(t))
    })

    app.delete("/todos/:id", (req, res) => {
        let id = int(req.param("id"))?
        let before = store.todos.len()
        store.todos = store.todos.filter(t => t.id != id)
        if store.todos.len() == before { return res.status(404).end() }
        publish(.Removed(id))
        res.end()
    })

    app.ws("/feed", (ws, req) => {
        ws.send(to_json({"hello": "${store.todos.len()} todos"}))
        ws.on_message(msg => ws.send("echo: ${msg}"))
    })

    // a tiny chat: everything one socket says goes to the others
    app.ws("/chat/:room", (ws, req) => {
        let name = req.query.get("name") ?? "guest ${ws.id}"
        ws.broadcast("${name} joined ${req.param("room")}")
        ws.on_message(msg => ws.broadcast("${name}: ${msg}"))
        ws.on_close(() => ws.broadcast("${name} left"))
    })

    app.every(30000, () => {
        for ws in app.clients("/feed") { ws.send("{\"ping\": true}") }
    })

    app.get("/stats", (req, res) => {
        res.cookie("seen", "yes").json(to_json({"todos": store.todos.len(), "requests": requests, "feeds": app.clients("/feed").len()}))
    })

    app.static("/", "examples/public")

    let port = int(env("PORT")) catch 8080
    app.listen(port)?
}
