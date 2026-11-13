// Notes: a text editor for the files in StellaOS's file system.

import web
import ui
import wm
import ramfs

const CSS = """
    .notes { display: flex; flex-direction: column; height: 100%; background: #fbfaff }
    .bar { display: flex; gap: 8px; align-items: center; padding: 8px 10px; background: #f1eff8; border-bottom: 1px solid #e0dde9 }
    .bar input { flex: 1; width: 100px }
    .bar button.save { background: #6c5ce7; color: white; border: none }
    textarea { flex: 1; border: none; border-radius: 0; background: #fbfaff; font-family: monospace; padding: 10px 12px; height: 100px }
    .status { padding: 4px 12px; color: #8a879a; font-size: 12px; border-top: 1px solid #ecebf2 }
"""

fn Notes(fs: ramfs.RamFs, start: str) -> Node {
    let path = signal(start)
    let text = signal(fs.read(start) catch "")
    let status = signal(if start == "" { "a new note" } else { "opened ${start}" })
    let dirty = signal(false)
    let save = () => {
        let p = fs.resolve("/", path.get().trim())
        if path.get().trim() == "" {
            status.set("give the note a name (like /home/notes.txt) first")
            return
        }
        fs.write(p, text.get()) catch e {
            status.set("couldn't save: ${e}")
            return
        }
        path.set(p)
        dirty.set(false)
        status.set("saved ${p} (${text.get().len()} bytes)")
    }
    let reload = () => {
        let t = fs.read(fs.resolve("/", path.get().trim())) catch e {
            status.set("${e}")
            return
        }
        text.set(t)
        dirty.set(false)
        status.set("opened ${path.get()}")
    }
    return <div class="notes">
        <div class="bar">
            <input value={path.get()} placeholder="/home/name.txt" oninput={v => path.set(v)} onkeydown={k => if k == "Enter" { reload() }} />
            <button onclick={() => reload()}>"Open"</button>
            <button class="save" onclick={() => save()}>{if dirty.get() { "Save •" } else { "Save" }}</button>
        </div>
        <textarea oninput={v => {
            text.set(v)
            dirty.set(true)
        }}>{text.get()}</textarea>
        <div class="status">{status.get()}</div>
    </div>
}

fn open(d: wm.Desktop, fs: ramfs.RamFs, path: str) {
    let title = if path == "" { "Notes" } else { "${fs.name(path)} — Notes" }
    d.open(title, "✎", 0xfdcb6e, 460, 360, ui.styled(() => <Notes fs={fs} start={path} />, CSS))
}
