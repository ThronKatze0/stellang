// http: an Express-style web framework with WebSockets, written in stellang on top of `net`.
//
//     let app = http.app()
//     app.use((req, res, next) => { println(req.path); next() })
//     app.get("/hello/:name", (req, res) => res.send("hi ${req.param("name")}"))
//     app.post("/users", (req, res) => {
//         let body = json.parse(req.body)?          // errors become a 500 response
//         res.status(201).json(body.stringify())
//     })
//     app.ws("/chat", (ws, req) => {
//         ws.on_message(msg => ws.broadcast(msg))
//     })
//     app.static("/public", "./public")
//     app.listen(8080)?
//
// One thread, one event loop (like Node): many connections at once, keep-alive, WebSockets, timers.

import net
import json

extern fn st_nonblock(fd: int) -> int
extern fn st_accept_nb(fd: int) -> int
extern fn st_poll(fds: [int], timeout_ms: int) -> [int]
extern fn st_fill(fd: int) -> int
extern fn st_http_take(fd: int) -> str
extern fn st_ws_take(fd: int) -> str
extern fn st_ws_op() -> int
extern fn st_ws_send(fd: int, op: int, msg: str) -> int
extern fn st_ws_accept(key: str) -> str
extern fn st_write(fd: int, data: str) -> int
extern fn st_drop(fd: int)
extern fn st_now_ms() -> int
extern fn st_url_decode(s: str) -> str
extern fn st_file_size(path: str) -> int
extern fn st_send_file(fd: int, head: str, path: str) -> int

const IDLE_MS = 30000

// Milliseconds on a monotonic clock (for measuring time).
fn now_ms() -> int {
    return st_now_ms()
}

struct Request {
    method: str,
    path: str,               // without the query string
    url: str,                // as sent: path + query
    query: {str: str},       // ?a=1&b=two, decoded
    headers: {str: str},     // lowercase names
    params: {str: str} = {}, // `:name` segments of the route; `*` for a trailing wildcard
    cookies: {str: str},
    body: str,
    locals: {str: str} = {}, // for middleware to pass things along

    // The value of a `:name` segment of the route, e.g. `/users/:id`.
    fn param(self, name: str) -> str {
        return self.params.get(name) ?? ""
    }

    // A request header (case-insensitive).
    fn header(self, name: str) -> str? {
        return self.headers.get(name.lower())
    }

    fn cookie(self, name: str) -> str? {
        return self.cookies.get(name)
    }

    // The body parsed as JSON.
    fn json(self) -> json.Json! {
        return json.parse(self.body)
    }

    // Does the Content-Type mention `kind` (like "json")?
    fn is(self, kind: str) -> bool {
        return (self.header("content-type") ?? "").contains(kind)
    }
}

struct Response {
    code: int = 404,
    headers: {str: str} = {"content-type": "text/plain; charset=utf-8"},
    cookies: [str] = [],
    body: str = "not found",
    file: str? = none,
    sent: bool = false,

    fn status(self, code: int) -> Response {
        self.code = code
        return self
    }

    // Set a response header.
    fn set(self, name: str, value: str) -> Response {
        self.headers[name.lower()] = value
        return self
    }

    fn type(self, content_type: str) -> Response {
        return self.set("content-type", content_type)
    }

    fn send(self, body: str) {
        self.body = body
        self.sent = true
    }

    fn html(self, body: str) {
        self.type("text/html; charset=utf-8").send(body)
    }

    // Send JSON text, e.g. `res.json(to_json(user))`.
    fn json(self, body: str) {
        self.type("application/json").send(body)
    }

    fn redirect(self, url: str) {
        self.status(302).set("location", url).send("")
    }

    fn cookie(self, name: str, value: str) -> Response {
        self.cookies.push("${name}=${value}; Path=/; HttpOnly")
        return self
    }

    // Send a file from disk (binary-safe); 404 if it isn't there.
    fn send_file(self, path: str) {
        if st_file_size(path) < 0 {
            self.status(404).send("not found")
            return
        }
        self.type(mime(path)).file = path
        self.sent = true
    }

    // An empty response (204 unless a status was set).
    fn end(self) {
        if self.code == 404 || self.code == 200 {
            self.code = 204
        }
        self.send("")
    }
}

// One WebSocket connection, handed to `app.ws` handlers.
struct WebSocket {
    id: int,
    fd: int,
    path: str,
    app: App,
    open: bool = true,
    on_msg: [fn(str)] = [],
    on_end: [fn()] = [],

    // Send a text message (does nothing once the socket is closed).
    fn send(self, msg: str) {
        if self.open && st_ws_send(self.fd, 1, msg) < 0 {
            self.open = false
        }
    }

    fn on_message(self, f: fn(str)) {
        self.on_msg.push(f)
    }

    fn on_close(self, f: fn()) {
        self.on_end.push(f)
    }

    fn close(self) {
        if self.open {
            st_ws_send(self.fd, 8, "")
            self.open = false
        }
    }

    // Every other open socket connected to the same path.
    fn peers(self) -> [WebSocket] {
        return self.app.clients(self.path).filter(s => s.id != self.id)
    }

    // Send to every other socket on the same path.
    fn broadcast(self, msg: str) {
        for s in self.peers() { s.send(msg) }
    }
}

struct Route {
    method: str, // "*" for any
    parts: [str],
    handler: fn(Request, Response) -> void!,
}

struct WsRoute {
    parts: [str],
    handler: fn(WebSocket, Request) -> void!,
}

struct Middleware {
    prefix: str,
    handler: fn(Request, Response, fn()) -> void!,
}

struct Timer {
    every: int,
    due: int,
    f: fn(),
    repeat: bool,
}

struct Client {
    fd: int,
    last: int,
    ws: WebSocket? = none,
}

struct App {
    routes: [Route] = [],
    ws_routes: [WsRoute] = [],
    middleware: [Middleware] = [],
    timers: [Timer] = [],
    sockets: {int: WebSocket} = {},
    next_id: int = 0,
    log: bool = true,

    fn get(self, path: str, handler: fn(Request, Response) -> void!) { self.route("GET", path, handler) }
    fn post(self, path: str, handler: fn(Request, Response) -> void!) { self.route("POST", path, handler) }
    fn put(self, path: str, handler: fn(Request, Response) -> void!) { self.route("PUT", path, handler) }
    fn patch(self, path: str, handler: fn(Request, Response) -> void!) { self.route("PATCH", path, handler) }
    fn delete(self, path: str, handler: fn(Request, Response) -> void!) { self.route("DELETE", path, handler) }
    // Any method.
    fn all(self, path: str, handler: fn(Request, Response) -> void!) { self.route("*", path, handler) }

    fn route(self, method: str, path: str, handler: fn(Request, Response) -> void!) {
        self.routes.push(Route { method, parts: split_path(path), handler })
    }

    // A WebSocket endpoint.
    fn ws(self, path: str, handler: fn(WebSocket, Request) -> void!) {
        self.ws_routes.push(WsRoute { parts: split_path(path), handler })
    }

    // Middleware for every request: call `next()` to go on, or answer with `res` to stop.
    fn use(self, handler: fn(Request, Response, fn()) -> void!) {
        self.use_at("/", handler)
    }

    // Middleware for paths under `prefix`.
    fn use_at(self, prefix: str, handler: fn(Request, Response, fn()) -> void!) {
        self.middleware.push(Middleware { prefix, handler })
    }

    // Serve the files in `dir` under `prefix`: app.static("/public", "./public").
    fn static(self, prefix: str, dir: str) {
        let base = no_trailing_slash(prefix)
        self.get(base + "/*", (req, res) => {
            let rest = req.param("*")
            if rest.contains("..") {
                res.status(403).send("forbidden")
                return
            }
            let path = if rest == "" { dir + "/index.html" } else { dir + "/" + rest }
            res.send_file(path)
        })
    }

    // Run `f` every `ms` milliseconds while the server runs.
    fn every(self, ms: int, f: fn()) {
        self.timers.push(Timer { every: ms, due: st_now_ms() + ms, f, repeat: true })
    }

    // Run `f` once, after `ms` milliseconds.
    fn after(self, ms: int, f: fn()) {
        self.timers.push(Timer { every: ms, due: st_now_ms() + ms, f, repeat: false })
    }

    // The open WebSockets on `path`.
    fn clients(self, path: str) -> [WebSocket] {
        return self.sockets.values().filter(s => s.open && s.path == path)
    }

    // Serve forever: one thread, an event loop over all connections.
    fn listen(self, port: int) -> void! {
        let server = net.listen(port)?
        st_nonblock(server.fd)
        if self.log {
            println("listening on http://localhost:${port}")
        }
        let clients: {int: Client} = {}
        while true {
            let fds = [server.fd]
            for fd in clients.keys() { fds.push(fd) }
            let ready = st_poll(fds, self.wait_ms())
            let now = st_now_ms()
            for fd in ready {
                if fd == server.fd {
                    while true {
                        let c = st_accept_nb(server.fd)
                        if c < 0 { break }
                        clients[c] = Client { fd: c, last: now }
                    }
                    continue
                }
                let c = clients.get(fd) else { continue }
                c.last = now
                if !self.pump(c) {
                    self.hang_up(c)
                    clients.remove(fd)
                }
            }
            self.run_timers(now)
            // closed WebSockets and idle HTTP connections
            for fd, c in clients {
                let gone = match c.ws {
                    some(ws) => !ws.open,
                    none => now - c.last > IDLE_MS,
                }
                if gone {
                    self.hang_up(c)
                    clients.remove(fd)
                }
            }
        }
    }

    // How long the event loop may sleep: until the next timer, at most a second.
    fn wait_ms(self) -> int {
        var wait = 1000
        let now = st_now_ms()
        for t in self.timers { wait = min(wait, max(0, t.due - now)) }
        return wait
    }

    fn run_timers(self, now: int) {
        let due = self.timers.filter(t => t.due <= now)
        self.timers = self.timers.filter(t => t.due > now || t.repeat)
        for t in due {
            t.due = now + t.every
            t.f()
        }
    }

    // Read what arrived on `c` and handle every complete request or message. False: close it.
    fn pump(self, c: Client) -> bool {
        let state = st_fill(c.fd)
        while true {
            if let ws = c.ws {
                let msg = st_ws_take(c.fd)
                match st_ws_op() {
                    0 => break,
                    1 | 2 => {
                        for f in ws.on_msg { f(msg) }
                    },
                    8 => {
                        ws.close()
                        return false
                    },
                    9 => st_ws_send(c.fd, 10, msg),
                    _ => {},
                }
                if !ws.open { return false }
            } else {
                let raw = st_http_take(c.fd)
                if raw == "" { break }
                if !self.handle(c, raw) { return false }
            }
        }
        return state > 0
    }

    fn hang_up(self, c: Client) {
        if let ws = c.ws {
            ws.open = false
            self.sockets.remove(ws.id)
            for f in ws.on_end { f() }
        }
        st_drop(c.fd)
    }

    // One HTTP request. Returns whether to keep the connection.
    fn handle(self, c: Client, raw: str) -> bool {
        let start = st_now_ms()
        let req = parse(raw) catch e {
            st_write(c.fd, render(Response { code: 400, body: "bad request: " + e }, false))
            return false
        }
        if (req.header("upgrade") ?? "").lower() == "websocket" {
            return self.upgrade(c, req)
        }
        let res = Response {}
        self.dispatch(0, req, res)
        let keep = (req.header("connection") ?? "").lower() != "close"
        let head = render(Response { code: res.code, headers: res.headers, cookies: res.cookies, body: "" }, keep)
        var written = true
        if let path = res.file {
            written = st_send_file(c.fd, head_with_length(res, keep, st_file_size(path)), path) >= 0
        } else if req.method == "HEAD" {
            written = st_write(c.fd, head_with_length(res, keep, res.body.len())) >= 0
        } else {
            written = st_write(c.fd, render(res, keep)) >= 0
        }
        if self.log {
            println("${req.method} ${req.url} -> ${res.code} (${st_now_ms() - start} ms)")
        }
        return written && keep
    }

    // Run middleware `i`, `i + 1`, ... and then the routes.
    fn dispatch(self, i: int, req: Request, res: Response) {
        var k = i
        while k < self.middleware.len() {
            let m = self.middleware[k]
            if under(req.path, m.prefix) {
                let next = k + 1
                m.handler(req, res, () => self.dispatch(next, req, res)) catch e { fail(res, e) }
                return
            }
            k += 1
        }
        if res.sent { return }
        for r in self.routes {
            let fits = r.method == "*" || r.method == req.method || (r.method == "GET" && req.method == "HEAD")
            if !fits { continue }
            let params = match_path(r.parts, req.path) else { continue }
            req.params = params
            res.code = 200
            res.body = ""
            r.handler(req, res) catch e { fail(res, e) }
            return
        }
    }

    fn upgrade(self, c: Client, req: Request) -> bool {
        for r in self.ws_routes {
            let params = match_path(r.parts, req.path) else { continue }
            req.params = params
            let key = req.header("sec-websocket-key") ?? ""
            let sent = st_write(c.fd, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: ${st_ws_accept(key)}\r\n\r\n")
            if sent < 0 { return false }
            self.next_id += 1
            let ws = WebSocket { id: self.next_id, fd: c.fd, path: req.path, app: self }
            self.sockets[ws.id] = ws
            c.ws = ws
            if self.log {
                println("WS ${req.path} -> 101 (socket ${ws.id})")
            }
            r.handler(ws, req) catch e {
                println("websocket handler failed: ${e}")
                ws.close()
            }
            return true
        }
        st_write(c.fd, render(Response {}, false))
        return false
    }
}

fn app() -> App {
    return App {}
}

// A handler returned an error: answer 500.
fn fail(res: Response, e: str) {
    println("error: ${e}")
    res.status(500).type("text/plain; charset=utf-8").send("internal server error: ${e}")
}

fn under(path: str, prefix: str) -> bool {
    if prefix == "/" || path == prefix {
        return true
    }
    return path.starts_with(no_trailing_slash(prefix) + "/")
}

fn no_trailing_slash(s: str) -> str {
    return if s.ends_with("/") { s.slice(0, s.len() - 1) } else { s }
}

fn split_path(path: str) -> [str] {
    return path.split("/").filter(p => p != "")
}

// The route's `:name` params if the path fits it.
fn match_path(parts: [str], path: str) -> {str: str}? {
    let got = split_path(path)
    let params: {str: str} = {}
    for i, want in parts {
        if want == "*" && i == parts.len() - 1 {
            params["*"] = got.slice(min(i, got.len()), got.len()).join("/")
            return params
        }
        let seg = got.get(i) else { return none }
        if want.starts_with(":") {
            params[want.slice(1, want.len())] = st_url_decode(seg)
        } else if want != seg {
            return none
        }
    }
    if got.len() != parts.len() {
        return none
    }
    return params
}

// "a=1&b=x%20y" -> {"a": "1", "b": "x y"}
fn parse_query(q: str) -> {str: str} {
    let out: {str: str} = {}
    for pair in q.split("&") {
        if pair == "" { continue }
        let eq = pair.find("=")
        if eq < 0 {
            out[st_url_decode(pair)] = ""
        } else {
            out[st_url_decode(pair.slice(0, eq))] = st_url_decode(pair.slice(eq + 1, pair.len()))
        }
    }
    return out
}

fn parse_cookies(header: str) -> {str: str} {
    let out: {str: str} = {}
    for part in header.split(";") {
        let eq = part.find("=")
        if eq > 0 {
            out[part.slice(0, eq).trim()] = part.slice(eq + 1, part.len()).trim()
        }
    }
    return out
}

fn parse(raw: str) -> Request! {
    let end = raw.find("\r\n\r\n")
    if end < 0 {
        return err("incomplete request")
    }
    let lines = raw.slice(0, end).split("\r\n")
    let first = lines[0].split(" ")
    if first.len() != 3 {
        return err("bad request line")
    }
    let url = first[1]
    var path = url
    var query = ""
    let q = url.find("?")
    if q >= 0 {
        query = url.slice(q + 1, url.len())
        path = url.slice(0, q)
    }
    let headers: {str: str} = {}
    for i in 1..lines.len() {
        let colon = lines[i].find(":")
        if colon > 0 {
            headers[lines[i].slice(0, colon).lower()] = lines[i].slice(colon + 1, lines[i].len()).trim()
        }
    }
    return Request {
        method: first[0].upper(),
        path: st_url_decode(path),
        url,
        query: parse_query(query),
        headers,
        cookies: parse_cookies(headers.get("cookie") ?? ""),
        body: raw.slice(end + 4, raw.len()),
    }
}

fn head_with_length(res: Response, keep: bool, length: int) -> str {
    var h = "HTTP/1.1 ${res.code} ${reason(res.code)}\r\n"
    for name, value in res.headers { h += "${name}: ${value}\r\n" }
    for c in res.cookies { h += "set-cookie: ${c}\r\n" }
    let conn = if keep { "keep-alive" } else { "close" }
    return h + "content-length: ${length}\r\nconnection: ${conn}\r\n\r\n"
}

fn render(res: Response, keep: bool) -> str {
    return head_with_length(res, keep, res.body.len()) + res.body
}

fn mime(path: str) -> str {
    let dot = path.split(".")
    let ext = if dot.len() > 1 { dot[dot.len() - 1].lower() } else { "" }
    return match ext {
        "html" | "htm" => "text/html; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "json" => "application/json",
        "txt" | "md" => "text/plain; charset=utf-8",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "ico" => "image/x-icon",
        "wasm" => "application/wasm",
        "pdf" => "application/pdf",
        _ => "application/octet-stream",
    }
}

fn reason(code: int) -> str {
    return match code {
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        422 => "Unprocessable Entity",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        _ => "Unknown",
    }
}
