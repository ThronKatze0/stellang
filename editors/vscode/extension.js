// The stellang extension. The compiler is the language server (`stellang lsp`), so everything
// the editor knows about the language comes from the compiler itself.
const vscode = require("vscode");
const cp = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { LanguageClient, State } = require("vscode-languageclient/node");
const { Runner } = require("./src/runner");
const views = require("./src/views");
const { newProject, create, TEMPLATES } = require("./src/projects");

const REPO = "https://github.com/ThronKatze0/stellang";
const EXE = process.platform === "win32" ? "stellang.exe" : "stellang";

let ctx;
let client;
let output;
let status;
let compiler; // { path, source, version }
let runner;
const config = () => vscode.workspace.getConfiguration("stellang");

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
    { label: "$(file-code) Show LLVM IR", cmd: "stellang.showIr" },
    { label: "$(new-folder) New Project…", cmd: "stellang.newProject" },
    { label: "$(star-full) Get Started", cmd: "stellang.walkthrough" },
    { label: "$(paintcan) Star Themes…", cmd: "stellang.useTheme" },
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
  runner.run(doc.uri.fsPath);
}

/** Stop / restart / open the running program. */
async function runMenu() {
  const r = runner.current();
  if (!r) return;
  const items = [];
  if (r.url) items.push({ label: `$(globe) Open ${r.url}`, run: () => vscode.env.openExternal(vscode.Uri.parse(r.url)) });
  if (r.url) items.push({ label: "$(browser) Open in Editor", run: () => vscode.commands.executeCommand("simpleBrowser.show", r.url) });
  items.push({ label: "$(debug-restart) Restart", run: () => r.restart() });
  if (r.child) items.push({ label: "$(debug-stop) Stop", run: () => r.kill() });
  items.push({ label: "$(terminal) Show Output", run: () => r.terminal.show() });
  const pick = await vscode.window.showQuickPick(items, { placeHolder: `${r.name}: ${r.state}` });
  pick?.run();
}

/** The program's LLVM IR, beside the source. */
async function showIr(uri) {
  const doc = await targetDoc(uri);
  if (!doc) return;
  const file = doc.uri.fsPath;
  const out = path.join(os.tmpdir(), "stellang-ir", path.basename(file, ".st") + ".ll");
  fs.mkdirSync(path.dirname(out), { recursive: true });
  const opt = config().get("optimization");
  cp.execFile(compiler.path, [opt, file, "--emit-llvm", "-o", out], { cwd: path.dirname(file) }, async (err, _o, stderr) => {
    if (err) {
      vscode.window.showErrorMessage(`stellang: ${(stderr || err.message).trim().split("\n")[0]}`);
      return;
    }
    const ir = await vscode.workspace.openTextDocument(out);
    await vscode.window.showTextDocument(ir, { viewColumn: vscode.ViewColumn.Beside, preview: true, preserveFocus: true });
  });
}

const THEMES = [
  { label: "$(star-full) Stellang Nebula", description: "dark: deep space, gold stars", theme: "Stellang Nebula" },
  { label: "$(star-empty) Stellang Daybreak", description: "light", theme: "Stellang Daybreak" },
];

async function useTheme() {
  const pick = await vscode.window.showQuickPick(THEMES, { placeHolder: "A color theme made for stellang" });
  if (pick) await vscode.workspace.getConfiguration("workbench").update("colorTheme", pick.theme, vscode.ConfigurationTarget.Global);
}

/** Once: point out the themes (only if a stellang file is open and another theme is in use). */
function offerTheme(context) {
  if (context.globalState.get("themeOffered") || !config().get("suggestTheme")) return;
  const current = vscode.workspace.getConfiguration("workbench").get("colorTheme") || "";
  if (current.startsWith("Stellang")) return;
  context.globalState.update("themeOffered", true);
  vscode.window
    .showInformationMessage("stellang comes with a star-themed color theme, made for its syntax.", "Try Stellang Nebula", "Daybreak (light)", "No thanks")
    .then((pick) => {
      const theme = pick === "Try Stellang Nebula" ? "Stellang Nebula" : pick === "Daybreak (light)" ? "Stellang Daybreak" : null;
      if (theme) vscode.workspace.getConfiguration("workbench").update("colorTheme", theme, vscode.ConfigurationTarget.Global);
    });
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

/** Arguments a command got from a tree item, a URI, or nothing. */
const fileArg = (x) => (x?.file ? vscode.Uri.file(x.file) : x?.resourceUri ?? x);

// ---- activation ----

exports.activate = async (context) => {
  ctx = context;
  output = vscode.window.createOutputChannel("stellang");
  status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 10);
  status.command = "stellang.statusMenu";
  status.name = "stellang";

  runner = new Runner(() => compiler, config);
  context.subscriptions.push(runner);
  const trees = views.register(context, runner);

  const cmd = (id, f) => context.subscriptions.push(vscode.commands.registerCommand(id, f));
  cmd("stellang.run", (x) => run(fileArg(x)));
  cmd("stellang.build", (x) => build(fileArg(x)));
  cmd("stellang.check", (x) => check(fileArg(x)));
  cmd("stellang.stop", (x) => runner.stop(x?.file));
  cmd("stellang.restartRun", (x) => (x?.file ? runner.run(x.file) : runner.current()?.restart()));
  cmd("stellang.runMenu", runMenu);
  cmd("stellang.showIr", (x) => showIr(fileArg(x)));
  cmd("stellang.newProject", (id) => newProject(context, typeof id === "string" ? id : undefined));
  cmd("stellang.useTheme", useTheme);
  cmd("stellang.walkthrough", () =>
    vscode.commands.executeCommand("workbench.action.openWalkthrough", "stellang.stellang#stellang.start", false)
  );
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
  if (vscode.window.activeTextEditor?.document.languageId === "stellang") offerTheme(context);
  else {
    const once = vscode.window.onDidChangeActiveTextEditor((ed) => {
      if (ed?.document.languageId === "stellang") {
        once.dispose();
        offerTheme(context);
      }
    });
    context.subscriptions.push(once);
  }
  await startClient();
  // for tests and other extensions
  return { runner, trees, createProject: (id, dir, name) => create(context, id, dir, name), templates: TEMPLATES.map((t) => t.id) };
};

exports.deactivate = () => client?.stop();
