// The browser half: picks up the todos the server put in the page and runs the app.
// (`stellang dev` builds this to public/client.wasm + public/client.js)
import web
import shared

fn main() {
    let todos: [shared.Todo] = from_json(web.read_data("todos")) catch []
    web.mount("#app", () => <shared.App initial={todos} />)
}
