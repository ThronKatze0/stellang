// "New Project…": a folder with a working program from one of the templates in templates/.
const vscode = require("vscode");
const fs = require("fs");
const path = require("path");

const TEMPLATES = [
  { id: "hello", label: "$(star-full) Hello, stars", detail: "A small program: structs, optionals, string interpolation." },
  { id: "web", label: "$(server) Web server", detail: "An Express-style HTTP server with routes and middleware." },
  { id: "api", label: "$(plug) JSON API + WebSockets", detail: "A todo API modeled with structs and enums, a live WebSocket feed and a web page." },
  { id: "model", label: "$(symbol-enum) Data modeling", detail: "Structs, enums with data, methods and exhaustive match." },
  { id: "cli", label: "$(terminal) Command-line tool", detail: "Reads a file and handles errors with `!` and `catch`." },
];

function copy(from, to, name) {
  fs.mkdirSync(to, { recursive: true });
  for (const e of fs.readdirSync(from, { withFileTypes: true })) {
    const src = path.join(from, e.name);
    const dst = path.join(to, e.name);
    if (e.isDirectory()) copy(src, dst, name);
    else fs.writeFileSync(dst, fs.readFileSync(src, "utf8").replace(/\{\{name\}\}/g, name));
  }
}

/** Write template `id` into `dir` (a new folder) as project `name`. */
function create(ctx, id, dir, name) {
  copy(ctx.asAbsolutePath(path.join("templates", id)), dir, name);
  fs.writeFileSync(path.join(dir, ".gitignore"), "/main\n*.ll\n");
  fs.writeFileSync(
    path.join(dir, "README.md"),
    `# ${name}\n\nA [stellang](https://github.com/ThronKatze0/stellang) program.\n\n\`\`\`sh\nstellang main.st && ./main\n\`\`\`\n\nIn VS Code: open \`main.st\` and press ▶ (or Ctrl+F5).\n`
  );
}

async function newProject(ctx, preset) {
  const t = preset ? TEMPLATES.find((x) => x.id === preset) : await vscode.window.showQuickPick(TEMPLATES, { title: "New stellang project", placeHolder: "Pick a template", matchOnDetail: true });
  if (!t) return;
  const name = await vscode.window.showInputBox({
    title: "New stellang project",
    prompt: "Project name (the folder to create)",
    value: t.id === "hello" ? "stars" : `my-${t.id}`,
    validateInput: (v) => (/^[A-Za-z0-9_][A-Za-z0-9_.-]*$/.test(v) ? undefined : "Letters, digits, `_`, `-` and `.` only"),
  });
  if (!name) return;
  const parent = await vscode.window.showOpenDialog({
    title: `Where should "${name}" go?`,
    canSelectFolders: true,
    canSelectFiles: false,
    openLabel: "Create here",
    defaultUri: vscode.workspace.workspaceFolders?.[0]?.uri,
  });
  if (!parent?.[0]) return;
  const dir = path.join(parent[0].fsPath, name);
  if (fs.existsSync(dir) && fs.readdirSync(dir).length) {
    vscode.window.showErrorMessage(`${dir} already exists and isn't empty.`);
    return;
  }
  create(ctx, t.id, dir, name);
  const main = vscode.Uri.file(path.join(dir, "main.st"));
  const here = vscode.workspace.workspaceFolders?.some((f) => dir.startsWith(f.uri.fsPath + path.sep));
  if (here) {
    await vscode.window.showTextDocument(main);
    return;
  }
  const pick = await vscode.window.showInformationMessage(`Created ${name}.`, "Open", "Open in New Window", "Add to Workspace");
  if (pick === "Open") await vscode.commands.executeCommand("vscode.openFolder", vscode.Uri.file(dir));
  else if (pick === "Open in New Window") await vscode.commands.executeCommand("vscode.openFolder", vscode.Uri.file(dir), { forceNewWindow: true });
  else if (pick === "Add to Workspace") {
    vscode.workspace.updateWorkspaceFolders(vscode.workspace.workspaceFolders?.length ?? 0, 0, { uri: vscode.Uri.file(dir) });
    await vscode.window.showTextDocument(main);
  } else await vscode.window.showTextDocument(main);
}

module.exports = { newProject, create, TEMPLATES };
