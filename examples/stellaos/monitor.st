// System monitor: memory, the garbage collector, timers and the desktop, live.

import web
import ui
import wm
import kernel

const CSS = """
    .mon { padding: 14px; display: flex; flex-direction: column; gap: 12px; background: #f6f5fb; height: 100% }
    .card { background: white; border-radius: 10px; padding: 12px 14px; box-shadow: 0 1px 3px gray }
    .card h3 { margin-bottom: 8px }
    .line { display: flex; justify-content: space-between; margin-bottom: 4px }
    .k { color: #8a879a }
    .v { font-weight: bold }
    progress { width: 100%; margin-bottom: 8px }
    .row { display: flex; gap: 8px }
    .row button { flex: 1 }
"""

fn size(n: int) -> str {
    if n >= 1 << 20 { return "${n / (1 << 20)}.${n % (1 << 20) * 10 / (1 << 20)} MiB" }
    if n >= 1 << 10 { return "${n / (1 << 10)} KiB" }
    return "${n} B"
}

// measured once a second
struct Stats {
    frames: int = 0,
    busy: int = 0,
    fps: int = 0,
    load: int = 0,

    fn update(self, d: wm.Desktop) {
        self.fps = d.frames - self.frames
        self.load = (d.busy_ms - self.busy) / 10
        self.frames = d.frames
        self.busy = d.busy_ms
    }
}

fn Monitor(d: wm.Desktop, stats: Stats) -> Node {
    let tick = signal(0)
    let m = kernel.memory()
    let used = m.ram - m.free
    return <div class="mon">
        <div class="card">
            <h3>"Memory"</h3>
            <div class="line"><span class="k">"In use"</span><span class="v">"${size(used)} of ${size(m.ram)}"</span></div>
            <progress value={str(used / 1024)} max={str(m.ram / 1024)}></progress>
            <div class="line"><span class="k">"Heap (live after GC)"</span><span class="v">"${size(m.live)} of ${size(m.heap)}"</span></div>
            <progress value={str(m.live / 1024)} max={str(max(m.heap / 1024, 1))}></progress>
            <div class="line"><span class="k">"Kernel image + stack"</span><span class="v">{size(m.kernel)}</span></div>
            <div class="line"><span class="k">"Device pages"</span><span class="v">{size(m.pages)}</span></div>
            <div class="line"><span class="k">"Garbage collections"</span><span class="v">{str(m.collections)}</span></div>
        </div>
        <div class="card">
            <h3>"System"</h3>
            <div class="line"><span class="k">"Up"</span><span class="v">"${kernel.uptime() / 1000} s"</span></div>
            <div class="line"><span class="k">"Windows"</span><span class="v">{str(d.windows.len())}</span></div>
            <div class="line"><span class="k">"Frames drawn"</span><span class="v">"${d.frames} (${stats.fps} a second)"</span></div>
            <div class="line"><span class="k">"Time spent drawing"</span><span class="v">"${stats.load}%"</span></div>
            <div class="line"><span class="k">"Timers"</span><span class="v">{str(kernel.timers())}</span></div>
            <div class="line"><span class="k">"Timer interrupts"</span><span class="v">{str(kernel.ticks())}</span></div>
        </div>
        <div class="row">
            <button onclick={() => {
                kernel.gc()
                tick.set(tick.get() + 1)
            }}>"Collect garbage"</button>
        </div>
    </div>
}

fn open(d: wm.Desktop) {
    let stats = Stats { frames: d.frames, busy: d.busy_ms }
    let app = ui.styled(() => <Monitor d={d} stats={stats} />, CSS)
    // once a second: measure, and render again (any signal change does)
    let beat = signal(0)
    let timer = web.every(1000, () => {
        stats.update(d)
        beat.set(beat.get() + 1)
    })
    app.close = () => web.cancel(timer)
    d.open("System Monitor", "◉", 0x00b894, 330, 470, app)
}
