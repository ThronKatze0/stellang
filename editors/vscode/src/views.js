// The stellang sidebar: the programs in the workspace (run, stop, build), the data model (every
// struct and enum, from the language server), and the HTTP routes the programs define.
const vscode = require("vscode");
const path = require("path");

const EXCLUDE = "{**/node_modules/**,**/.git/**,**/target/**}";
const icon = (id, color) => new vscode.ThemeIcon(id, color ? new vscode.ThemeColor(color) : undefined);

async function stFiles() {
  const uris = await vscode.workspace.findFiles("**/*.st", EXCLUDE, 500);
  return uris.sort((a, b) => a.fsPath.localeCompare(b.fsPath));
}

async function textOf(uri) {
  const open = vscode.workspace.textDocuments.find((d) => d.uri.toString() === uri.toString());
  if (open) return open.getText();
  return Buffer.from(await vscode.workspace.fs.readFile(uri)).toString("utf8");
}

function rel(uri) {
  return vscode.workspace.asRelativePath(uri, false);
}

function openAt(uri, line, col = 0) {
  const pos = new vscode.Position(line, col);
  return { command: "vscode.open", title: "Open", arguments: [uri, { selection: new vscode.Range(pos, pos) }] };
}

class Tree {
  constructor() {
    this.emitter = new vscode.EventEmitter();
    this.onDidChangeTreeData = this.emitter.event;
    this.timer = undefined;
  }
  refresh() {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.emitter.fire(), 300);
  }
  getTreeItem(e) {
    return e;
  }
}

// ---- programs ----

class Programs extends Tree {
  constructor(runner) {
    super();
    this.runner = runner;
    runner.onDidChange(() => this.emitter.fire());
  }
  async getChildren() {
    const out = [];
    for (const uri of await stFiles()) {
      const text = await textOf(uri);
      const m = /(?:^|\n)\s*(?:fn|🦍)\s+main\s*\(/.exec(text);
      if (!m) continue;
      const run = this.runner.runs.get(uri.fsPath);
      const live = run?.child;
      const it = new vscode.TreeItem(path.basename(uri.fsPath), vscode.TreeItemCollapsibleState.None);
      it.resourceUri = uri;
      it.contextValue = live ? "program.running" : "program";
      it.description = live ? (run.url ? `● ${run.url}` : `● ${run.state}`) : path.dirname(rel(uri)) === "." ? "" : path.dirname(rel(uri));
      it.iconPath = live ? icon("debug-start", "charts.green") : run?.state === "failed" ? icon("error", "charts.red") : icon("star-full", "charts.yellow");
      it.tooltip = new vscode.MarkdownString(`**${rel(uri)}**\n\n${live ? `running${run.url ? ` on ${run.url}` : ""}` : "click to open · ▶ to run"}`);
      const line = text.slice(0, m.index + m[0].length).split("\n").length - 1;
      it.command = openAt(uri, line);
      it.file = uri.fsPath;
      out.push(it);
    }
    return out;
  }
}

// ---- the data model ----

const KIND = vscode.SymbolKind;
const symIcon = {
  [KIND.Struct]: ["symbol-struct", "symbolIcon.structForeground"],
  [KIND.Enum]: ["symbol-enum", "symbolIcon.enumeratorForeground"],
  [KIND.EnumMember]: ["symbol-enum-member", "symbolIcon.enumeratorMemberForeground"],
  [KIND.Field]: ["symbol-field", "symbolIcon.fieldForeground"],
  [KIND.Method]: ["symbol-method", "symbolIcon.methodForeground"],
  [KIND.Function]: ["symbol-function", "symbolIcon.functionForeground"],
  [KIND.Constant]: ["symbol-constant", "symbolIcon.constantForeground"],
};

class Model extends Tree {
  constructor() {
    super();
    this.showFunctions = false;
  }
  item(uri, s) {
    const kids = (s.children || []).filter((c) => this.showFunctions || c.kind !== KIND.Function);
    const it = new vscode.TreeItem(s.name, kids.length ? vscode.TreeItemCollapsibleState.Collapsed : vscode.TreeItemCollapsibleState.None);
    const [i, c] = symIcon[s.kind] || ["symbol-misc"];
    it.iconPath = icon(i, c);
    let detail = s.detail || "";
    if (s.kind === KIND.Field) detail = detail.replace(/^.*?:\s*/, "");
    else if (s.kind === KIND.EnumMember) detail = detail.replace(/^[^(){]*?(?=[({]|$)/, "");
    else if (s.kind === KIND.Method || s.kind === KIND.Function) detail = detail.replace(/^fn\s+[\w.]+/, "");
    else if (s.kind === KIND.Struct || s.kind === KIND.Enum) detail = `${s.kind === KIND.Struct ? "struct" : "enum"} · ${rel(uri)}`;
    it.description = detail;
    it.tooltip = new vscode.MarkdownString().appendCodeblock(s.detail || s.name, "stellang");
    it.command = openAt(uri, s.selectionRange.start.line, s.selectionRange.start.character);
    it.children = kids.map((k) => this.item(uri, k));
    return it;
  }
  async getChildren(e) {
    if (e) return e.children;
    const out = [];
    for (const uri of await stFiles()) {
      let syms = [];
      try {
        syms = (await vscode.commands.executeCommand("vscode.executeDocumentSymbolProvider", uri)) || [];
      } catch {
        continue;
      }
      for (const s of syms) {
        if (s.kind === KIND.Struct || s.kind === KIND.Enum || (this.showFunctions && s.kind === KIND.Function)) out.push(this.item(uri, s));
      }
    }
    // types first (by name), then functions
    out.sort((a, b) => (a.iconPath.id === "symbol-function") - (b.iconPath.id === "symbol-function") || a.label.localeCompare(b.label));
    return out;
  }
}

// ---- HTTP routes ----

// `.get("/path", handler)`: a path that starts with `/` (or is `*`) and a second argument
const ROUTE_RE = /\.(get|post|put|patch|delete|all|ws|static|use_at)\(\s*"(\/[^"]*|\*)"\s*,/g;
const VERB_ICON = {
  get: ["arrow-down", "charts.blue"],
  post: ["add", "charts.green"],
  put: ["edit", "charts.orange"],
  patch: ["edit", "charts.yellow"],
  delete: ["trash", "charts.red"],
  all: ["globe", "charts.purple"],
  ws: ["plug", "charts.purple"],
  static: ["files", "charts.foreground"],
  use_at: ["filter", "charts.foreground"],
};

class Routes extends Tree {
  constructor(runner) {
    super();
    this.runner = runner;
    runner.onDidChange(() => this.emitter.fire());
  }
  async getChildren(e) {
    if (e) return e.children;
    const files = [];
    for (const uri of await stFiles()) {
      const text = await textOf(uri);
      const routes = [];
      for (const m of text.matchAll(ROUTE_RE)) {
        const line = text.slice(0, m.index).split("\n").length - 1;
        const lineText = text.split("\n")[line];
        if (/^\s*\/\//.test(lineText)) continue; // commented out
        const verb = m[1];
        const label = verb === "use_at" ? `use ${m[2]}` : verb === "static" ? `static ${m[2]}` : `${verb.toUpperCase()} ${m[2]}`;
        const it = new vscode.TreeItem(label);
        const [i, c] = VERB_ICON[verb];
        it.iconPath = icon(i, c);
        it.description = `line ${line + 1}`;
        it.command = openAt(uri, line, m.index - text.lastIndexOf("\n", m.index) - 1);
        const run = this.runner.runs.get(uri.fsPath);
        if (run?.url && (verb === "get" || verb === "static") && !m[2].includes(":") && !m[2].includes("*")) {
          it.contextValue = "route.open";
          it.url = new URL(m[2], run.url).toString();
          it.tooltip = `${it.url}`;
        }
        routes.push(it);
      }
      if (!routes.length) continue;
      const f = new vscode.TreeItem(rel(uri), vscode.TreeItemCollapsibleState.Expanded);
      f.iconPath = icon("server-environment", "charts.yellow");
      f.description = `${routes.length} route${routes.length === 1 ? "" : "s"}`;
      f.children = routes;
      files.push(f);
    }
    return files;
  }
}

function register(context, runner) {
  const programs = new Programs(runner);
  const model = new Model();
  const routes = new Routes(runner);
  const views = [
    vscode.window.createTreeView("stellang.programs", { treeDataProvider: programs }),
    vscode.window.createTreeView("stellang.model", { treeDataProvider: model, showCollapseAll: true }),
    vscode.window.createTreeView("stellang.routes", { treeDataProvider: routes, showCollapseAll: true }),
  ];
  const all = () => [programs, model, routes].forEach((t) => t.refresh());
  const watcher = vscode.workspace.createFileSystemWatcher("**/*.st");
  context.subscriptions.push(
    ...views,
    watcher,
    watcher.onDidCreate(all),
    watcher.onDidDelete(all),
    watcher.onDidChange(all),
    vscode.workspace.onDidSaveTextDocument((d) => d.languageId === "stellang" && all()),
    vscode.workspace.onDidChangeTextDocument((e) => e.document.languageId === "stellang" && [model, routes].forEach((t) => t.refresh())),
    vscode.commands.registerCommand("stellang.refreshViews", all),
    vscode.commands.registerCommand("stellang.model.toggleFunctions", () => {
      model.showFunctions = !model.showFunctions;
      model.refresh();
    }),
    vscode.commands.registerCommand("stellang.openRoute", (it) => it?.url && vscode.env.openExternal(vscode.Uri.parse(it.url)))
  );
  return { programs, model, routes };
}

module.exports = { register };
