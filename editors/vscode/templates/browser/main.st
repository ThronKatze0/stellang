// {{name}}: a stellang app that runs in the browser (compiled to WebAssembly).
// Press ▶ to build it and open it, or: stellang --web main.st
import web

// Components are functions that return JSX.
fn Counter(label: str, start: int) -> Node {
    let count = signal(start) // state that survives re-rendering
    return <div class="counter">
        <span>{label}</span>
        <button onclick={() => count.set(count.get() - 1)}>"−"</button>
        <b>{count.get()}</b>
        <button onclick={() => count.set(count.get() + 1)}>"+"</button>
    </div>
}

struct Note {
    id: int
    text: str
}

fn Notes() -> Node {
    // saved in the browser, so they're still there after a reload
    let notes: web.Signal<[Note]> = signal(from_json(web.load("notes")) catch [])
    let draft = signal("")
    let add = () => {
        if draft.get().trim() == "" { return }
        let id = if notes.get().is_empty() { 1 } else { notes.get()[notes.get().len() - 1].id + 1 }
        notes.get().push(Note { id, text: draft.get() })
        web.save("notes", to_json(notes.get()))
        draft.set("")
    }
    let remove = (id: int) => {
        notes.set(notes.get().filter(n => n.id != id))
        web.save("notes", to_json(notes.get()))
    }
    return <section>
        <h2>"Notes"</h2>
        <form onsubmit={_ => add()}>
            <input placeholder="Write something…" value={draft.get()} oninput={v => draft.set(v)} />
            <button disabled={draft.get().trim() == ""}>"Add"</button>
        </form>
        <ul>
            for n in notes.get() {
                <li key={n.id}>{n.text} <button onclick={() => remove(n.id)}>"×"</button></li>
            }
            if notes.get().is_empty() { <li class="empty">"No notes yet."</li> }
        </ul>
    </section>
}

fn App() -> Node {
    let seconds = signal(0)
    if seconds.get() == 0 {
        web.every(1000, () => seconds.set(seconds.get() + 1))
        seconds.set(1)
    }
    return <main>
        <h1>"⭐ {{name}}"</h1>
        <p class="dim">"Open for ${seconds.get() - 1} s."</p>
        <Counter label="Stars" start={3} />
        <Notes />
    </main>
}

fn main() {
    web.mount("#app", () => <App />)
}
