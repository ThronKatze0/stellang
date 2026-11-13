# Writing stellang

The language server knows every type, so completion does too:

- `x.` lists `x`'s fields and methods, including builtin ones like `xs.filter(...)`.
- `.` where an enum is expected lists its variants: `let s: Shape = .` → `.Circle(…)`.
- Inside `Todo { }`, completion offers the missing fields, or **all required fields** at once.
- In a `match`, it offers every case, or **all cases** at once. A `match` that misses some gets a quick fix (💡) that adds them.
- **Postfix completions**: `value.match`, `.if`, `.for`, `.let`, `.println`, `.iflet`, `.catch`, `.try`.
- Typing `json.` imports `json` for you. Misspelled names get a *Change to …* fix.
- Hints show inferred types (`: [Todo]`) and parameter names. Hover anything for its type and doc comment.
- **F12** goes to the definition, even into the standard library. **F2** renames everywhere.
