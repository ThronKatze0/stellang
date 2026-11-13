// Calculator: a web-style app (JSX + signals) on the desktop. Click the keys or type.

import web
import ui
import wm
import calc

const CSS = """
    .calc { display: flex; flex-direction: column; gap: 10px; padding: 14px; height: 100%; background: #f4f3f9 }
    .screen { background: #23212e; border-radius: 10px; padding: 12px 14px; text-align: right }
    .expr { color: #9e9ab3; font-size: 13px; height: 18px }
    .result { color: white; font-size: 26px; font-weight: bold }
    .error { color: #ff7f8f; font-size: 15px }
    .keys { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; flex: 1 }
    .keys button { font-size: 16px; padding: 10px 0; background: white; border: 1px solid #dddbe7; border-radius: 9px }
    .keys button.op { background: #ece9fb; color: #5a48d6; font-weight: bold }
    .keys button.eq { background: #6c5ce7; color: white; border: none; font-weight: bold }
"""

const KEYS = ["C", "(", ")", "/", "7", "8", "9", "*", "4", "5", "6", "-", "1", "2", "3", "+", "0", "%", "⌫", "="]

fn Calculator() -> Node {
    let expr = signal("")
    let shown = signal("0")
    let failed = signal(false)
    let press = (k: str) => {
        if k == "C" || k == "Escape" {
            expr.set("")
            shown.set("0")
            failed.set(false)
        } else if k == "⌫" || k == "Backspace" {
            let cs = expr.get().chars()
            if !cs.is_empty() { cs.pop() }
            expr.set(cs.join(""))
        } else if k == "=" || k == "Enter" {
            if expr.get().trim() == "" { return }
            let v = calc.eval(expr.get()) catch e {
                shown.set("${e}")
                failed.set(true)
                return
            }
            shown.set(str(v))
            failed.set(false)
            expr.set(str(v))
        } else if "0123456789+-*/%()".contains(k) && k.len() == 1 {
            expr.set(expr.get() + k)
        }
    }
    return <div class="calc">
        <div class="screen">
            <div class="expr">{expr.get()}</div>
            <div class={if failed.get() { "error" } else { "result" }}>{shown.get()}</div>
        </div>
        <div class="keys" onkeydown={k => press(k)}>
            for k in KEYS {
                <button class={if k == "=" { "eq" } else if "/*-+()%C⌫".contains(k) { "op" } else { "" }} onclick={() => press(k)}>{k}</button>
            }
        </div>
    </div>
}

fn open(d: wm.Desktop) {
    d.open("Calculator", "=", 0x6c5ce7, 280, 360, ui.styled(() => <Calculator />, CSS))
}
