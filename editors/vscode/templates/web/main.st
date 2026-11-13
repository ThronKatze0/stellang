// {{name}}: a web server. Run it, then open http://localhost:8080
import http

fn main() -> void! {
    let app = http.app()

    // middleware runs before every route
    app.use((req, res, next) => {
        res.set("x-powered-by", "stellang")
        next()
    })

    app.get("/", (req, res) => res.html("<h1>⭐ {{name}}</h1><p>Try <a href=\"/hello/world\">/hello/world</a></p>"))

    app.get("/hello/:name", (req, res) => res.send("hello, ${req.param("name")}!"))

    app.get("/time", (req, res) => res.json("{\"ms\": ${now_ms()}}"))

    let port = int(env("PORT")) catch 8080
    app.listen(port)?
}
