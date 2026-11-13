// Shared by both sides: the server renders the first page with these components, then the
// browser app (client.st, compiled to WebAssembly) takes over the same HTML.
import web
import json

struct Todo {
    id: int
    title: str
    done: bool = false
}

enum Filter { All, Open, Done }

fn TodoItem(todo: Todo, toggle: fn(), remove: fn()) -> Node {
    return <li key={todo.id} class={if todo.done { "done" } else { "" }}>
        <label>
            <input type="checkbox" checked={todo.done} onchange={_ => toggle()} />
            <span>{todo.title}</span>
        </label>
        <button class="remove" title="Remove" onclick={() => remove()}>"×"</button>
    </li>
}

fn App(initial: [Todo]) -> Node {
    let todos = signal(initial)
    let draft = signal("")
    let filter = signal(Filter.All)
    let saving = signal(false)

    // every change goes to the server, which answers with the whole list
    let send = (method: str, url: str, body: str) => {
        saving.set(true)
        web.request(method, url, body, r => {
            saving.set(false)
            let list: [Todo] = from_json(r.body) catch todos.get()
            todos.set(list)
        })
    }
    let add = () => {
        let title = draft.get().trim()
        if title == "" { return }
        draft.set("")
        send("POST", "/api/todos", to_json(Todo { id: 0, title }))
    }

    let shown = todos.get().filter(t => match filter.get() { .All => true, .Open => !t.done, .Done => t.done })
    let left = todos.get().filter(t => !t.done).len()
    return <main class="app">
        <header>
            <h1>"⭐ todos"</h1>
            <p class="sub">"Rendered on the server, running in WebAssembly."</p>
        </header>
        <form class="new" onsubmit={_ => add()}>
            <input placeholder="What needs doing?" value={draft.get()} oninput={v => draft.set(v)} autofocus />
            <button disabled={draft.get().trim() == ""}>"Add"</button>
        </form>
        <ul class="list">
            for t in shown {
                <TodoItem todo={t} toggle={() => send("PUT", "/api/todos/${t.id}", "")} remove={() => send("DELETE", "/api/todos/${t.id}", "")} />
            }
            if shown.is_empty() { <li class="empty">"Nothing here."</li> }
        </ul>
        <footer>
            <span class="left">"${left} left"</span>
            <nav>
                for f in [Filter.All, Filter.Open, Filter.Done] {
                    <button class={if f == filter.get() { "on" } else { "" }} onclick={() => filter.set(f)}>{str(f)}</button>
                }
            </nav>
            <span class="saving">{if saving.get() { "saving…" } else { "" }}</span>
        </footer>
    </main>
}
