// The server half: a JSON API, and the first page rendered from the same components.
//
//     stellang dev .        (then open http://localhost:8080)
import http
import json
import web
import shared

fn Page(todos: [shared.Todo]) -> Node {
    return <html lang="en">
        <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <title>"stellang todos"</title>
            <link rel="stylesheet" href="/style.css" />
        </head>
        <body>
            <div id="app"><shared.App initial={todos} /></div>
            {web.data("todos", to_json(todos))}
            <script src="/client.js"></script>
        </body>
    </html>
}

fn main() -> void! {
    var todos = [
        shared.Todo { id: 1, title: "Write the app in one language" },
        shared.Todo { id: 2, title: "Render it on the server", done: true },
        shared.Todo { id: 3, title: "Run it in WebAssembly" },
    ]
    var next = 4
    let app = http.app()

    app.get("/", (req, res) => res.page(<Page todos={todos} />))
    app.get("/api/todos", (req, res) => res.json(to_json(todos)))
    app.post("/api/todos", (req, res) => {
        let t: shared.Todo = from_json(req.body)?
        todos.push(shared.Todo { id: next, title: t.title })
        next += 1
        res.status(201).json(to_json(todos))
    })
    app.put("/api/todos/:id", (req, res) => {
        let id = int(req.param("id"))?
        for t in todos {
            if t.id == id { t.done = !t.done }
        }
        res.json(to_json(todos))
    })
    app.delete("/api/todos/:id", (req, res) => {
        let id = int(req.param("id"))?
        todos = todos.filter(t => t.id != id)
        res.json(to_json(todos))
    })
    app.static("/", "./public")

    println("todos on http://localhost:8080")
    app.listen(8080)?
}
