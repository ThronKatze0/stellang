// An Express-style web server in stellang.
// Run: stellang examples/server.st && ./server   (PORT=3000 ./server for another port)

import http

fn main() -> void! {
    let app = http.app()
    var visits = 0

    app.get("/", (req, res) => {
        visits += 1
        res.html("<h1>hello from stellang</h1><p>visit number ${visits}</p>")
    })

    app.get("/hello/:name", (req, res) => res.send("hi ${req.param("name")}!"))

    app.get("/square/:n", (req, res) => {
        let n = int(req.param("n")) catch e {
            res.status(400).send(e)
            return
        }
        res.send(str(n * n))
    })

    app.post("/echo", (req, res) => res.json(req.body))

    let port = int(env("PORT")) catch 8080
    app.listen(port)?
}
