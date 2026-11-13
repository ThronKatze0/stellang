// Files: browse StellaOS's file system. Click a folder to go in, a file to edit it in Notes.

import web
import ui
import wm
import ramfs

const CSS = """
    .files { display: flex; flex-direction: column; height: 100%; background: white }
    .bar { display: flex; gap: 6px; align-items: center; padding: 8px 10px; background: #f3f2f8; border-bottom: 1px solid #e2e0ea }
    .path { flex: 1; font-weight: bold; padding: 0 6px }
    .list { flex: 1; overflow: auto; padding: 6px 0 }
    .row { display: flex; align-items: center; gap: 10px; padding: 6px 12px }
    .icon { width: 22px; height: 22px; border-radius: 6px; color: white; font-size: 12px; font-weight: bold; text-align: center; padding: 3px 0 }
    .dir { background: #74b9ff }
    .file { background: #a29bfe }
    .name { flex: 1 }
    .size { color: #9a97aa; font-size: 12px }
    .row button { padding: 2px 8px; background: white; color: #c0392b; border: 1px solid #f0d4d4 }
    .new { display: flex; gap: 6px; padding: 8px 10px; border-top: 1px solid #ecebf2; background: #faf9fd }
    .new input { flex: 1; width: 80px }
    .empty { color: #9a97aa; padding: 16px }
    .error { color: #c0392b; padding: 0 12px 6px 12px; font-size: 12px }
"""

fn Files(fs: ramfs.RamFs, open_file: fn(str)) -> Node {
    let cwd = signal("/home")
    let name = signal("")
    let problem = signal("")
    let make = (folder: bool) => {
        let n = name.get().trim()
        if n == "" {
            problem.set("type a name first")
            return
        }
        let p = fs.resolve(cwd.get(), n)
        let r = if folder { fs.mkdir(p) } else { fs.write(p, "") }
        r catch e {
            problem.set("${e}")
            return
        }
        name.set("")
        problem.set("")
    }
    let entries = fs.list(cwd.get())
    return <div class="files">
        <div class="bar">
            <button disabled={cwd.get() == "/"} onclick={() => cwd.set(fs.parent(cwd.get()))}>"↑ Up"</button>
            <span class="path">{cwd.get()}</span>
            <button onclick={() => cwd.set("/")}>"/"</button>
        </div>
        <div class="list">
            for e in entries {
                <div class="row" key={e}>
                    if e.ends_with("/") {
                        <span class="icon dir">"▤"</span>
                        <a class="name" onclick={() => cwd.set(fs.resolve(cwd.get(), e.slice(0, e.len() - 1)))}>{e}</a>
                    } else {
                        <span class="icon file">"≡"</span>
                        <a class="name" onclick={() => open_file(fs.resolve(cwd.get(), e))}>{e}</a>
                        <span class="size">"${(fs.read(fs.resolve(cwd.get(), e)) catch "").len()} B"</span>
                    }
                    <button onclick={() => {
                        fs.remove(fs.resolve(cwd.get(), if e.ends_with("/") { e.slice(0, e.len() - 1) } else { e })) catch err { problem.set("${err}") }
                        cwd.set(cwd.get())
                    }}>"✕"</button>
                </div>
            }
            if entries.is_empty() { <div class="empty">"This folder is empty."</div> }
        </div>
        if problem.get() != "" { <div class="error">{problem.get()}</div> }
        <form class="new" onsubmit={_ => make(false)}>
            <input placeholder="name" value={name.get()} oninput={v => name.set(v)} />
            <button type="button" onclick={() => make(true)}>"New folder"</button>
            <button>"New file"</button>
        </form>
    </div>
}

fn open(d: wm.Desktop, fs: ramfs.RamFs, open_file: fn(str)) {
    d.open("Files", "▤", 0x0984e3, 400, 380, ui.styled(() => <Files fs={fs} open_file={open_file} />, CSS))
}
