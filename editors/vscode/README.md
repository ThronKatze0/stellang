# stellang for VS Code

Everything for [stellang](https://github.com/ThronKatze0/stellang), the small compiled language with
structs, enums, `T?` options, `T!` results and an Express-style web framework.

The language server is the compiler itself (`stellang lsp`). Errors, types, completions and colors
come straight from the real lexer, parser and type checker, so the extension always matches your
compiler, with nothing to update by hand.

## Features

- **Errors as you type**: the compiler's own messages, underlined where they happen.
- **Hover**: the type of any variable, field or call, with the doc comment above declarations.
- **Inlay hints**: `let user = find(id)` shows `: User?` after the name.
- **Completion**: keywords, builtins, your functions, types and variants. After a `.` it suggests
  the members of that value's actual type, a module's items, or an enum's variants.
- **Signature help** while you type the arguments of a call.
- **Go to definition** (also into the standard library), **find all references**, **rename**,
  **highlight occurrences**.
- **Outline / breadcrumbs / Go to Symbol** in the file and across the workspace.
- **Format** on save (`stellang fmt`), **folding**, bracket colorizing, comment toggling.
- **Semantic highlighting** that knows types, enum variants, functions, methods and modules, plus a
  TextMate grammar generated from the compiler's keyword table (it also highlights stellang code blocks in Markdown).
- **Run** with `Ctrl+F5` / `Cmd+F5`, the ▶ button in the editor title, or the `▶ Run | Build`
  lens above `fn main`. Each run gets a fresh terminal, so a restarted server gets its port back.
- **Build** and **Check** as tasks. Compiler errors and runtime panics show up in the Problems panel
  through the `$stellang` problem matcher.
- **Snippets**: `main`, `fn`, `struct`, `enum`, `match`, `matchopt`, `iflet`, `letelse`, `server`,
  `get`, `ws`, `use`, …
- **File icon** for `.st` files and a status bar item showing which compiler is in use.
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
| `stellang.codeLens` | `true` | `▶ Run \| Build` above `fn main`. |
| `stellang.trace.server` | `off` | Log language server traffic to *Output → stellang*. |

The extension also sets `[stellang]` defaults: 4-space indent, format on save, semantic highlighting.

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
