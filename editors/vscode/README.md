# stellang for VS Code

Everything for [stellang](https://github.com/ThronKatze0/stellang), the small compiled language with
structs, enums, `T?` options, `T!` results and an Express-style web framework.

The language server is the compiler itself (`stellang lsp`). Errors, types, completions and colors
come straight from the real lexer, parser and type checker, so the extension always matches your
compiler, with nothing to update by hand.

## Features

### Completion that asks the type checker

While you type, the language server swaps the word under the cursor for a placeholder and runs the
real type checker, so it knows exactly what's in front of the `.`, even in code that doesn't compile yet.

- `x.` lists `x`'s fields and methods, with their types and docs. That includes the builtin ones
  (`xs.filter(…)`, `s.split(…)`, `m.get(…)`), with `T`, `K`, `V` filled in from the real type.
- Functions insert their parameters as tab stops. Callbacks get a lambda head, so `app.get(` writes
  `"…", (req, res) => …`.
- `.` where an enum is expected (`let s: Shape = .`, `area(.`) lists that enum's variants and their fields.
- Inside `Todo { … }`, completion lists only the fields not written yet, or **all required fields** at once.
- Inside a `match`, it offers a pattern for every case, or **all cases** at once.
- **Postfix completions**: `expr.match` (with one arm per case), `.if`, `.for`, `.let`, `.var`,
  `.println`, `.iflet`, `.else`, `.or`, `.catch`, `.try`, `.return`.
- `http.` or `json.` imports the module for you if it isn't imported yet.
- On an optional, `x.field` offers to reach through with `?.`.

### Quick fixes

- **Add the missing match arms** when a `match` doesn't handle every case.
- **Import `http`** (or any std module) when you use one without importing it.
- **Change to `…`** for misspelled names, fields and methods.

### Looks

- **Two star themes**: *Stellang Nebula* (dark: deep space, gold functions, cyan types, aurora-green
  enums) and *Stellang Daybreak* (light).
- **Semantic highlighting** that tells structs from enums from variants, fields from methods, and
  parameters from `let`s and `var`s (underlined, because they can change). The error-flow marks `?` `!` `??` `?.`
  stand out, and so do the `⭐` braces.
- A TextMate grammar generated from the compiler's own keyword table, with a separate scope for
  everything (also used for stellang code blocks in Markdown).

### The stellang sidebar

- **Programs**: every file with a `fn main`. Run, stop, restart and build from there.
- **Types**: every struct and enum in the workspace, with fields, variants and methods.
- **HTTP Routes**: every `app.get/post/put/patch/delete/ws/static/use_at`. While the server runs, open a GET route in the browser.

### Running

- `Ctrl+F5` / `Cmd+F5`, ▶ in the editor title, `▶ Run | Build` above `fn main`, or the sidebar.
- Programs run in a ⭐ terminal the extension owns. You can type input into it; Ctrl+C or `Shift+F5`
  stops the program, and any key runs it again after it exits.
- When a program prints a `http://localhost:…` address, the extension offers to open it in the
  browser or inside VS Code. The status bar shows the port; click it to restart or stop.
- **Show LLVM IR** opens the code the compiler generates.
- **Build** and **Check** are tasks. Compiler errors and runtime panics show up in the Problems
  panel through the `$stellang` problem matcher.

### And

- **New Project…** with templates (hello, web server, JSON API + WebSockets, data modeling, CLI) and
  a **Get Started** walkthrough.
- Hover types and docs, inlay type and parameter-name hints, signature help (builtin methods too),
  go to definition (into the standard library), references, rename, highlights, outline, workspace symbols,
  folding, format on save.
- The emoji keywords: **stellang: Convert Keywords to Emoji 🦍** (and back).

## Setup

From a checkout: `editors/vscode/install.sh` builds everything and installs it into `code` (or pass `codium` / `cursor`).
Or install a `.vsix` (Extensions view → `…` → *Install from VSIX…*). Then open a `.st` file.

The extension looks for the compiler in this order:

1. the `stellang.path` setting,
2. `stellang` on your `PATH`,
3. `~/.cargo/bin/stellang`,
4. the copy bundled inside the extension (platform builds).

If it finds none, it offers to run `cargo install --git https://github.com/ThronKatze0/stellang`.
To *build and run* programs you also need clang and the Boehm GC library
(`sudo apt install clang libgc-dev`, or `brew install llvm bdw-gc`). The editor features don't need them.

## Settings

| Setting | Default | |
|---|---|---|
| `stellang.path` | (search) | The compiler to use. |
| `stellang.optimization` | `-O2` | Optimization level for Run and Build. |
| `stellang.run.env` | `{}` | Environment variables for Run, e.g. `{"PORT": "3000"}`. |
| `stellang.run.args` | `[]` | Command-line arguments for Run. |
| `stellang.run.openBrowser` | `ask` | When a program prints a localhost address: `ask`, `always`, `never`. |
| `stellang.suggestTheme` | `true` | Suggest the Stellang Nebula theme once. |
| `stellang.codeLens` | `true` | `▶ Run \| Build` above `fn main`. |
| `stellang.trace.server` | `off` | Log language server traffic to *Output → stellang*. |

The extension also sets `[stellang]` defaults: 4-space indent, format on save, semantic highlighting, inlay hints, bracket colors.

## Tasks

```json
{ "type": "stellang", "command": "build", "file": "${workspaceFolder}/main.st" }
```

`command` is `build`, `run` or `check`. The tasks use the `$stellang` problem matcher.

## Building the extension

```sh
cd editors/vscode
npm install
npm run package        # builds the compiler, bundles it, writes stellang-<version>.vsix
npm run package:nobin  # a universal .vsix that uses the compiler on your PATH
```
