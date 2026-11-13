// http: a small Express-style web framework, written in stellang on top of `net`.
//
//     let app = http.app()
//     app.get("/hello/:name", (req, res) => res.send("hi ${req.param("name")}"))
//     app.listen(8080)?

import net

struct Request {
    method: str,
    path: str,
    query: str,
    headers: {str: str}, // lowercase names
    params: {str: str},
    body: str,
}

impl Request {
    // The value of a `:name` segment of the route, e.g. `/users/:id`.
    fn param(self, name: str) -> str {
        return self.params.get(name, "")
    }

    // A request header (case-insensitive), or "" if missing.
    fn header(self, name: str) -> str {
        return self.headers.get(name.lower(), "")
    }
}

struct Response {
    code: int,
    content_type: str,
    body: str,
}

impl Response {
    fn status(self, code: int) -> Response {
        self.code = code
        return self
    }

    fn send(self, body: str) {
        self.body = body
    }

    fn html(self, body: str) {
        self.content_type = "text/html; charset=utf-8"
        self.body = body
    }

    fn json(self, body: str) {
        self.content_type = "application/json"
        self.body = body
    }
}

struct Route {
    method: str,
    parts: [str],
    handler: fn(Request, Response),
}

struct App {
    routes: [Route],
}

fn app() -> App {
    return App { routes: [] }
}

impl App {
    fn get(self, path: str, handler: fn(Request, Response)) {
        self.route("GET", path, handler)
    }

    fn post(self, path: str, handler: fn(Request, Response)) {
        self.route("POST", path, handler)
    }

    fn route(self, method: str, path: str, handler: fn(Request, Response)) {
        self.routes.push(Route { method, parts: path.split("/"), handler })
    }

    // Serve forever, one connection at a time.
    fn listen(self, port: int) -> void! {
        let server = net.listen(port)?
        println("listening on http://localhost:${port}")
        while true {
            let conn = server.accept() catch e {
                continue
            }
            self.serve(conn)
            conn.close()
        }
    }

    fn serve(self, conn: net.Conn) {
        let raw = conn.read() catch e {
            return
        }
        let res = Response { code: 404, content_type: "text/plain; charset=utf-8", body: "not found" }
        let req = parse(raw) catch e {
            res.status(400).send("bad request: " + e)
            conn.write(render(res)) catch e {}
            return
        }
        for route in self.routes {
            if route.method == req.method && matches(route.parts, req) {
                res.status(200).send("")
                route.handler(req, res)
                break
            }
        }
        println("${req.method} ${req.path} -> ${res.code}")
        conn.write(render(res)) catch e {}
    }
}

// Does the request path fit the route? Fills in `:name` params.
fn matches(parts: [str], req: Request) -> bool {
    let got = req.path.split("/")
    if got.len() != parts.len() {
        return false
    }
    let params: {str: str} = {}
    for i in 0..parts.len() {
        let want = parts[i]
        if want.starts_with(":") {
            params[want.slice(1, want.len())] = got[i]
        } else if want != got[i] {
            return false
        }
    }
    req.params = params
    return true
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
    var path = first[1]
    var query = ""
    let q = path.find("?")
    if q >= 0 {
        query = path.slice(q + 1, path.len())
        path = path.slice(0, q)
    }
    let headers: {str: str} = {}
    for i in 1..lines.len() {
        let colon = lines[i].find(":")
        if colon > 0 {
            let name = lines[i].slice(0, colon).lower()
            let value = lines[i].slice(colon + 1, lines[i].len()).trim()
            headers[name] = value
        }
    }
    let body = raw.slice(end + 4, raw.len())
    return Request { method: first[0], path, query, headers, params: {}, body }
}

fn render(res: Response) -> str {
    return "HTTP/1.1 ${res.code} ${reason(res.code)}\r\n"
        + "Content-Type: ${res.content_type}\r\n"
        + "Content-Length: ${res.body.len()}\r\n"
        + "Connection: close\r\n\r\n"
        + res.body
}

fn reason(code: int) -> str {
    return match code {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        500 => "Internal Server Error",
        _ => "Unknown",
    }
}
