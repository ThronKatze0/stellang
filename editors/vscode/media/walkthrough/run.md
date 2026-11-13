# Run it

- **▶ Run** above `fn main`, the ▶ button in the editor title, or **Ctrl+F5**
- The program runs in a ⭐ terminal. Type into it to send input; **Ctrl+C** stops it. When it ends, press any key to run it again.
- When a server prints its address (`listening on http://localhost:8080`), you can open it in your browser or inside VS Code. The status bar shows the port; click it to stop or restart.
- The **Routes** view lists every `app.get(...)`, `app.post(...)` and so on. While the server runs, open a `GET` route straight from there.
- **Build** writes a binary next to the file. **Show LLVM IR** shows what the compiler generated.

Set `stellang.run.env` for environment variables (like `{"PORT": "3000"}`).
