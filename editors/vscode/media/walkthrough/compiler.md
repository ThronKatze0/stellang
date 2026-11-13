# The compiler is the language server

stellang's errors, hovers, completions and highlighting all come from the compiler itself (`stellang lsp`), so they always match the language.

The extension finds it in this order:

1. the `stellang.path` setting
2. `stellang` on your `PATH`
3. `~/.cargo/bin/stellang`
4. the copy bundled with the extension

To build programs you also need **clang** and the **Boehm GC** library:

- Debian/Ubuntu: `sudo apt install clang libgc-dev`
- Fedora: `sudo dnf install clang gc-devel`
- macOS: `brew install llvm bdw-gc`

The ⭐ in the status bar shows which compiler is in use. Click it for actions.
