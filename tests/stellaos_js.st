// StellaOS's JavaScript engine and DOM, checked inside QEMU (run by tests/e2e.rs: stellaos_js).
// Each case is a script whose last console.log line must equal the expected text.

import kernel
import html
import jsdom

struct Case {
    name: str,
    code: str,
    want: str,
}

fn main() {
    let cases = [
        Case { name: "arithmetic and strings", code: "console.log(1 + 2 * 3, 7 / 2, 2 ** 10, 0.1 + 0.2, '5' * 2, '5' + 2, -7 % 3)", want: "7 3.5 1024 0.30000000000000004 10 52 -1" },
        Case { name: "closures per iteration", code: "const f = []; for (let i = 0; i < 3; i++) f.push(() => i); console.log(f.map(g => g()).join())", want: "0,1,2" },
        Case { name: "classes, super, getters", code: "class A { constructor(x) { this.x = x } get double() { return this.x * 2 } hi() { return 'A' } } class B extends A { hi() { return super.hi() + 'B' } } const b = new B(4); console.log(b.double, b.hi(), b instanceof A)", want: "8 AB true" },
        Case { name: "destructuring and spread", code: "const { a, b: [c, d = 4], ...rest } = { a: 1, b: [3], e: 5 }; console.log(a, c, d, JSON.stringify(rest), Math.max(...[1, 9, 2]))", want: "1 3 4 {\"e\":5} 9" },
        Case { name: "regular expressions", code: "console.log('2024-03-05'.replace(/(\\d+)-(\\d+)-(\\d+)/, '$3.$2.$1'), /^[a-z]+@[a-z]+\\.com$/i.test('Ada@Example.com'), 'a1b22'.match(/\\d+/g).join('|'))", want: "05.03.2024 true 1|22" },
        Case { name: "JSON round trip", code: "console.log(JSON.stringify(JSON.parse('{\"x\":[1,{\"y\":null}],\"s\":\"q\\\\\"\"}')))", want: "{\"x\":[1,{\"y\":null}],\"s\":\"q\\\"\"}" },
        Case { name: "exceptions", code: "let r; try { null.x } catch (e) { r = e instanceof TypeError } finally { r = r + '!' } console.log(r)", want: "true!" },
        Case { name: "promises and async", code: "let out = []; (async () => { out.push(await Promise.resolve(1)); out.push(await new Promise(r => r(2))) })(); Promise.all([3, Promise.resolve(4)]).then(v => { out.push(v.join('+')); console.log(out.join()) })", want: "1,2,3+4" },
        Case { name: "Map, Set, sort", code: "const m = new Map([['b', 2], ['a', 1]]); console.log([...m.keys()].sort().join(), new Set([3, 3, 1]).size, [10, 9, 1].sort().join(), [10, 9, 1].sort((x, y) => x - y).join())", want: "a,b 2 1,10,9 1,9,10" },
        Case { name: "the DOM", code: "const ul = document.getElementById('list'); ['x', 'y'].forEach(t => { const li = document.createElement('li'); li.textContent = t; li.className = 'item'; ul.appendChild(li) }); ul.firstElementChild.classList.add('first'); console.log(document.querySelectorAll('#list > li.item').length, ul.innerHTML, document.querySelector('.first').textContent)", want: "2 <li class=\"item first\">x</li><li class=\"item\">y</li> x" },
        Case { name: "events", code: "let n = 0; const b = document.getElementById('btn'); b.addEventListener('click', e => { n++; e.preventDefault() }); document.addEventListener('click', () => n += 10); b.click(); console.log(n)", want: "11" },
        Case { name: "inline handlers", code: "window.hits = 0; document.getElementById('inline').click(); console.log(hits)", want: "1" },
        Case { name: "storage", code: "localStorage.setItem('k', 'v'); console.log(localStorage.getItem('k'), localStorage.getItem('nope'))", want: "v null" },
        Case { name: "a runaway loop is stopped", code: "while (true) {}", want: "error: the script ran too long and was stopped" },
        Case { name: "deep recursion is a RangeError", code: "function f(n) { return f(n + 1) } try { f(0) } catch (e) { console.log(e.name) }", want: "RangeError" },
        Case { name: "a catastrophic regex gives up", code: "console.log(/(a+)+b/.test('a'.repeat(40)))", want: "false" },
        Case { name: "no network", code: "fetch('https://example.com/').catch(e => console.log('blocked'))", want: "blocked" },
        Case { name: "no XMLHttpRequest", code: "try { new XMLHttpRequest() } catch (e) { console.log(e.message.includes('no network')) }", want: "true" },
        Case { name: "reserved attributes", code: "try { document.body.setAttribute('data-on-click', '0') } catch (e) { console.log(e.message) }", want: "the attribute 'data-on-click' is reserved" },
        Case { name: "no eval", code: "try { eval('1') } catch (e) { console.log(e.name) }", want: "EvalError" },
        Case { name: "the page is the whole world", code: "console.log(document.body.parentNode === document, typeof require, typeof process)", want: "true undefined undefined" },
    ]
    var good = 0
    for c in cases {
        let doc = html.parse("<ul id=\"list\"></ul><button id=\"btn\">b</button><button id=\"inline\" onclick=\"hits++\">i</button>")
        let d = jsdom.open(doc.root, "https://example.com/", "t", {}, 7)
        d.run_script(c.code, c.name)
        let got = d.log.last() ?? ""
        if got == c.want {
            good += 1
            println("ok ${c.name}")
        } else {
            println("FAIL ${c.name}: got [${got}], want [${c.want}]")
        }
    }
    println("passed ${good}/${cases.len()}")
}
