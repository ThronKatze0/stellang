# Changelog

## 0.4.0

- The language grew generics, traits and JSX, and compiles to WebAssembly: the grammar and the
  language server know all of it (type parameters, traits, tags, components, attributes, events).
- JSX completion: components with their required props, HTML elements, props and attributes, events,
  closing tags.
- Full-stack apps run under `stellang dev`; browser apps are built with `--web` and served locally.
- New templates: Full-stack app, Browser app.
- Theme colors for tags, components, attributes, events, traits and type parameters.

## 0.3.0

- Completion from the type checker, even in code that doesn't parse: members of any expression
  (builtin methods with their real types), `.Variant` for the expected enum, missing struct fields,
  match arms, parameter tab stops, lambda heads for callbacks, auto-import, postfix completions.
- Quick fixes: add missing match arms, import a std module, did-you-mean.
- Signature help and hover for builtin methods and functions; parameter-name inlay hints.
- Two color themes, Stellang Nebula and Stellang Daybreak. A finer grammar, and semantic tokens for
  `var` (mutable), parameters, field declarations and std functions.
- A stellang sidebar: Programs, Types, HTTP Routes.
- A runner that owns its terminal: stop, restart, input, server address detection with Open in Browser.
- New Project templates, a Get Started walkthrough, Show LLVM IR.

## 0.2.0

- Language server features: diagnostics, hover, inlay type hints, completion, signature help,
  go to definition, references, rename, document highlights, symbols, folding, formatting,
  semantic tokens, code lenses.
- Run / Build / Check commands, task provider, `$stellang` problem matcher.
- Snippets, Markdown code block highlighting, file icon, status bar.
- Finds the compiler in the settings, on PATH, in ~/.cargo/bin, or bundled.
