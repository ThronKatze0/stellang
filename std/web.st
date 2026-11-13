// web: apps that run in the browser. Build with `stellang --web app.st` (makes app.wasm and app.js).
//
//     import web
//
//     fn Counter() -> Node {
//         let count = signal(0)        // state that survives re-rendering
//         return <button onclick={() => count.set(count.get() + 1)}>"clicked ${count.get()} times"</button>
//     }
//
//     fn main() {
//         web.mount("#app", () => <Counter />)
//     }
//
// The app re-renders after every change to a signal, and the page is patched to match (keeping
// focus, scroll and what's typed). Events: onclick={() => ...}, oninput={value => ...} (the
// field's text, or "true"/"false" for a checkbox), onkeydown={key => ...}, onsubmit={form => ...}
// (the fields as `a=1&b=2`). Components shared with a server render there as plain HTML.

import json

extern fn st_mount(selector: str, app: fn() -> Node)
extern fn st_invalidate()
extern fn st_timer(f: fn(), ms: int, repeat: int) -> int
extern fn st_clear_timer(id: int)
extern fn st_fetch(method: str, url: str, body: str, done: fn(int, str))
extern fn st_storage_get(key: str) -> str
extern fn st_storage_set(key: str, value: str)
extern fn st_location() -> str
extern fn st_navigate(path: str)
extern fn st_set_title(title: str)
extern fn st_raw(html: str) -> Node

// A value the page depends on. Make one with `signal(initial)` inside a component (it keeps its
// value from one render to the next) or anywhere else (then it's a plain shared box).
struct Signal<T> {
    value: T

    fn get(self) -> T {
        return self.value
    }

    // Change the value and re-render.
    fn set(self, v: T) {
        self.value = v
        st_invalidate()
    }

    fn update(self, f: fn(T) -> T) {
        self.set(f(self.value))
    }
}

// Render `app` into the element matching `selector` (like "#app"), and again after every change.
fn mount(selector: str, app: fn() -> Node) {
    st_mount(selector, app)
}

// Render again (signals do this for you).
fn refresh() {
    st_invalidate()
}

// Run `f` once after `ms` milliseconds; returns an id for `cancel`.
fn after(ms: int, f: fn()) -> int {
    return st_timer(f, ms, 0)
}

// Run `f` every `ms` milliseconds; returns an id for `cancel`.
fn every(ms: int, f: fn()) -> int {
    return st_timer(f, ms, 1)
}

fn cancel(id: int) {
    st_clear_timer(id)
}

// What came back from `get` / `post`.
struct Response {
    status: int, // 0 if the request failed (offline, ...)
    body: str,

    fn is_ok(self) -> bool {
        return self.status >= 200 && self.status < 300
    }

    fn json(self) -> json.Json! {
        return json.parse(self.body)
    }
}

// HTTP requests; `done` runs when the answer is there.
fn get(url: str, done: fn(Response)) {
    st_fetch("GET", url, "", (status, body) => done(Response { status, body }))
}

fn post(url: str, body: str, done: fn(Response)) {
    st_fetch("POST", url, body, (status, body) => done(Response { status, body }))
}

fn request(method: str, url: str, body: str, done: fn(Response)) {
    st_fetch(method, url, body, (status, body) => done(Response { status, body }))
}

// The current path (with ?query and #hash), for routing.
fn location() -> str {
    return st_location()
}

// Go to another path in the app without reloading (and re-render).
fn navigate(path: str) {
    st_navigate(path)
}

fn set_title(title: str) {
    st_set_title(title)
}

// Saved in the browser (localStorage); "" if there's nothing.
fn load(key: str) -> str {
    return st_storage_get(key)
}

fn save(key: str, value: str) {
    st_storage_set(key, value)
}

// Trusted HTML as a Node, as is (never pass it user input).
fn raw(html: str) -> Node {
    return st_raw(html)
}
