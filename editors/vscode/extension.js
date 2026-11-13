// The stellang extension. The compiler is the language server (`stellang lsp`), so everything
// the editor knows about the language comes from the compiler itself.
const vscode = require("vscode");
const cp = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { LanguageClient, State } = require("vscode-languageclient/node");

const REPO = "https://github.com/ThronKatze0/stellang";
const EXE = process.platform === "win32" ? "stellang.exe" : "stellang";

let ctx;
let client;
let output;
let status;
let compiler; // { path, source, version }
let runTerminal;

// ---- finding the compiler ----

function executable(p) {
  try {
    fs.accessSync(p, fs.constants.X_OK);
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
}

function expand(p) {
  const folder = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath ?? "";
  return p.replace(/^~(?=$|[\\/])/, os.homedir()).replace(/\$\{workspaceFolder\}/g, folder);
}

/** The setting, then PATH, then ~/.cargo/bin, then the copy bundled with the extension. */
function findCompiler() {
  const set = vscode.workspace.getConfiguration("stellang").get("path");
  const candidates = [];
  if (set) candidates.push([expand(set), "setting stellang.path"]);
  for (const dir of (process.env.PATH || "").split(path.delimiter)) {
    if (dir) candidates.push([path.join(dir, EXE), "PATH"]);
  }
  candidates.push([path.join(os.homedir(), ".cargo", "bin", EXE), "~/.cargo/bin"]);
  candidates.push([ctx.asAbsolutePath(path.join("bin", EXE)), "bundled with the extension"]);
  for (const [p, source] of candidates) {
    if (!executable(p)) continue;
    let version = "?";
    try {
      version = cp.execFileSync(p, ["--version"], { encoding: "utf8", timeout: 5000 }).trim();
    } catch {
      // an older compiler without --version still works
    }
    return { path: p, source, version };
  }
  if (set) vscode.window.showErrorMessage(`stellang.path points to "${set}", which isn't an executable.`);
  return null;
}

async function offerInstall() {
  const pick = await vscode.window.showWarningMessage(
    "The stellang compiler wasn't found, so there are no errors, hovers or completions yet.",
    "Install with cargo",
    "Set path…",
    "Retry"
  );
  if (pick === "Install with cargo") {
    const t = vscode.window.createTerminal("install stellang");
    t.show();
    t.sendText(`cargo install --git ${REPO} && echo "done: run 'stellang: Restart Language Server'"`);
  } else if (pick === "Set path…") {
    const f = await vscode.window.showOpenDialog({ canSelectMany: false, openLabel: "Use this compiler" });
    if (f?.[0]) await vscode.workspace.getConfiguration("stellang").update("path", f[0].fsPath, vscode.ConfigurationTarget.Global);
  } else if (pick === "Retry") {
    await restart();
  }
}

// ---- the language server ----

async function startClient() {
  compiler = findCompiler();
  if (!compiler) {
    setStatus("error", "compiler not found — click to fix");
    offerInstall();
    return;
  }
  setStatus("starting");
  client = new LanguageClient(
    "stellang",
    "stellang",
    { command: compiler.path, args: ["lsp"] },
    {
      documentSelector: [
        { scheme: "file", language: "stellang" },
        { scheme: "untitled", language: "stellang" },
      ],
      outputChannel: output,
      middleware: {
        provideCodeLenses: (doc, token, next) =>
          vscode.workspace.getConfiguration("stellang").get("codeLens") ? next(doc, token) : [],
      },
    }
  );
  client.onDidChangeState((e) => {
    if (e.newState === State.Running) setStatus("ready");
    else if (e.newState === State.Stopped) setStatus("error", "language server stopped — click to restart");
  });
  try {
    await client.start();
  } catch (e) {
    setStatus("error", String(e));
    output.appendLine(`could not start ${compiler.path} lsp: ${e}`);
  }
}

async function restart() {
  if (client) {
    try {
      await client.stop();
    } catch {
      // already stopped
    }
    client = undefined;
  }
  await startClient();
}

// ---- status bar ----

function setStatus(state, detail) {
  const icon = { starting: "$(sync~spin)", ready: "$(star-full)", error: "$(warning)" }[state];
  status.text = `${icon} stellang`;
  status.backgroundColor = state === "error" ? new vscode.ThemeColor("statusBarItem.warningBackground") : undefined;
  const md = new vscode.MarkdownString(
    compiler
      ? `**${compiler.version}**  \n\`${compiler.path}\`  \n(${compiler.source})`
      : "**stellang**: compiler not found"
  );
  if (detail) md.appendMarkdown(`\n\n${detail}`);
  md.appendMarkdown("\n\n_Click for actions_");
  status.tooltip = md;
  updateStatusVisibility();
}

function updateStatusVisibility() {
  const ed = vscode.window.activeTextEditor;
  if (ed?.document.languageId === "stellang") status.show();
  else status.hide();
}

async function statusMenu() {
  const items = [
    { label: "$(play) Run File", cmd: "stellang.run" },
    { label: "$(tools) Build File", cmd: "stellang.build" },
    { label: "$(check) Check File", cmd: "stellang.check" },
    { label: "$(refresh) Restart Language Server", cmd: "stellang.restart" },
    { label: "$(output) Show Output", cmd: "stellang.showOutput" },
    { label: "$(gear) Settings", cmd: "workbench.action.openSettings", args: ["@ext:stellang.stellang"] },
  ];
  if (!compiler) items.unshift({ label: "$(cloud-download) Install the compiler…", run: offerInstall });
  const pick = await vscode.window.showQuickPick(items, { placeHolder: compiler ? compiler.version : "stellang" });
  if (pick?.run) pick.run();
  else if (pick) vscode.commands.executeCommand(pick.cmd, ...(pick.args || []));
}

// ---- run / build / check ----

/** The stellang document to act on: the one given (code lens, explorer), else the active editor. Saved first. */
async function targetDoc(uri) {
  let doc;
  if (uri) doc = await vscode.workspace.openTextDocument(typeof uri === "string" ? vscode.Uri.parse(uri) : uri);
  else doc = vscode.window.activeTextEditor?.document;
  if (!doc || doc.languageId !== "stellang") {
    vscode.window.showWarningMessage("Open a .st file first.");
    return null;
  }
  if (doc.isUntitled || doc.isDirty) {
    if (!(await doc.save()) || doc.isUntitled) {
      vscode.window.showWarningMessage("Save the file first.");
      return null;
    }
  }
  if (!compiler) {
    offerInstall();
    return null;
  }
  return doc;
}

const q = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

let clangChecked = false;
function warnIfNoClang() {
  if (clangChecked) return;
  clangChecked = true;
  try {
    cp.execFileSync("clang", ["--version"], { stdio: "ignore", timeout: 5000 });
  } catch {
    vscode.window.showWarningMessage(
      "Building stellang programs needs clang and the Boehm GC library: `sudo apt install clang libgc-dev` (Debian/Ubuntu) or `brew install llvm bdw-gc` (macOS)."
    );
  }
}

async function run(uri) {
  const doc = await targetDoc(uri);
  if (!doc) return;
  warnIfNoClang();
  const file = doc.uri.fsPath;
  const dir = path.dirname(file);
  const outDir = path.join(os.tmpdir(), "stellang-run");
  fs.mkdirSync(outDir, { recursive: true });
  const out = path.join(outDir, path.basename(file, ".st"));
  const opt = vscode.workspace.getConfiguration("stellang").get("optimization");
  const env = vscode.workspace.getConfiguration("stellang").get("run.env") || {};
  // a fresh terminal each time: stopping the last run frees its port
  if (runTerminal) runTerminal.dispose();
  runTerminal = vscode.window.createTerminal({ name: `▶ ${path.basename(file)}`, cwd: dir, env });
  runTerminal.show(true);
  runTerminal.sendText(`${q(compiler.path)} ${opt} ${q(file)} -o ${q(out)} && ${q(out)}`);
}

function task(kind, file) {
  const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(file)) ?? vscode.TaskScope.Workspace;
  const opt = vscode.workspace.getConfiguration("stellang").get("optimization");
  const args =
    kind === "check"
      ? ["check", file]
      : kind === "build"
        ? [opt, file, "-o", path.join(path.dirname(file), path.basename(file, ".st"))]
        : [opt, file, "-o", path.join(os.tmpdir(), "stellang-run", path.basename(file, ".st"))];
  const exec =
    kind === "run"
      ? new vscode.ShellExecution(`${q(compiler?.path ?? "stellang")} ${args.map(q).join(" ")} && ${q(args[3])}`, { cwd: path.dirname(file) })
      : new vscode.ProcessExecution(compiler?.path ?? "stellang", args, { cwd: path.dirname(file) });
  const t = new vscode.Task({ type: "stellang", command: kind, file }, folder, `${kind} ${path.basename(file)}`, "stellang", exec, "$stellang");
  if (kind === "build") t.group = vscode.TaskGroup.Build;
  t.presentationOptions = { reveal: vscode.TaskRevealKind.Always, clear: true };
  return t;
}

async function build(uri) {
  const doc = await targetDoc(uri);
  if (!doc) return;
  warnIfNoClang();
  vscode.tasks.executeTask(task("build", doc.uri.fsPath));
}

async function check(uri) {
  const doc = await targetDoc(uri);
  if (!doc) return;
  vscode.tasks.executeTask(task("check", doc.uri.fsPath));
}

/** `stellang fmt --emoji|--plain` on the open document, as one undoable edit. */
async function convert(mode) {
  const ed = vscode.window.activeTextEditor;
  if (!ed || ed.document.languageId !== "stellang" || !compiler) return;
  const tmp = path.join(os.tmpdir(), `stellang-fmt-${process.pid}.st`);
  fs.writeFileSync(tmp, ed.document.getText());
  try {
    cp.execFileSync(compiler.path, ["fmt", mode, tmp], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    const text = fs.readFileSync(tmp, "utf8");
    const all = new vscode.Range(ed.document.positionAt(0), ed.document.positionAt(ed.document.getText().length));
    await ed.edit((e) => e.replace(all, text));
  } catch (e) {
    vscode.window.showErrorMessage(`stellang fmt: ${(e.stderr || e.message || "").toString().trim()}`);
  } finally {
    fs.rmSync(tmp, { force: true });
  }
}

async function newFile() {
  const doc = await vscode.workspace.openTextDocument({ language: "stellang", content: "" });
  const ed = await vscode.window.showTextDocument(doc);
  ed.insertSnippet(new vscode.SnippetString('fn main() {\n\tprintln("hello from stellang ⭐")$0\n}\n'));
}

// ---- activation ----

exports.activate = async (context) => {
  ctx = context;
  output = vscode.window.createOutputChannel("stellang");
  status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 10);
  status.command = "stellang.statusMenu";
  status.name = "stellang";

  const cmd = (id, f) => context.subscriptions.push(vscode.commands.registerCommand(id, f));
  cmd("stellang.run", run);
  cmd("stellang.build", build);
  cmd("stellang.check", check);
  cmd("stellang.toEmoji", () => convert("--emoji"));
  cmd("stellang.toPlain", () => convert("--plain"));
  cmd("stellang.restart", restart);
  cmd("stellang.showOutput", () => output.show());
  cmd("stellang.newFile", newFile);
  cmd("stellang.statusMenu", statusMenu);

  context.subscriptions.push(
    output,
    status,
    vscode.window.onDidChangeActiveTextEditor(updateStatusVisibility),
    vscode.window.onDidCloseTerminal((t) => {
      if (t === runTerminal) runTerminal = undefined;
    }),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("stellang.path")) restart();
      if (e.affectsConfiguration("stellang.codeLens") && client) restart();
    }),
    vscode.tasks.registerTaskProvider("stellang", {
      provideTasks() {
        const doc = vscode.window.activeTextEditor?.document;
        if (doc?.languageId !== "stellang" || doc.isUntitled) return [];
        return ["build", "run", "check"].map((k) => task(k, doc.uri.fsPath));
      },
      resolveTask(t) {
        const file = t.definition.file
          ? expand(t.definition.file)
          : vscode.window.activeTextEditor?.document.uri.fsPath;
        if (!file) return undefined;
        const r = task(t.definition.command, file);
        r.definition = t.definition;
        return r;
      },
    })
  );
  setStatus("starting");
  await startClient();
};

exports.deactivate = () => client?.stop();
