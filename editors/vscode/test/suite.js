// End-to-end checks inside a real VS Code: the extension starts the compiler's language server and
// every editor feature answers. No test framework, just assertions.
const vscode = require("vscode");
const assert = require("assert");
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function until(what, f, ms = 20000) {
  const end = Date.now() + ms;
  for (;;) {
    const v = await f();
    if (v) return v;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(200);
  }
}

function get(port, p) {
  return new Promise((resolve) => {
    http.get({ host: "127.0.0.1", port, path: p }, (res) => {
      let b = "";
      res.on("data", (d) => (b += d));
      res.on("end", () => resolve(b));
    }).on("error", () => resolve(null));
  });
}

exports.run = async () => {
  const results = [];
  const check = async (name, f) => {
    try {
      await f();
      results.push(`ok   ${name}`);
    } catch (e) {
      results.push(`FAIL ${name}: ${e.message}`);
    }
  };
  const root = vscode.workspace.workspaceFolders[0].uri.fsPath;
  const uri = vscode.Uri.file(path.join(root, "todos.st"));
  const doc = await vscode.workspace.openTextDocument(uri);
  await vscode.window.showTextDocument(doc);
  const at = (s, off = 0) => doc.positionAt(doc.getText().indexOf(s) + off);
  const ext = vscode.extensions.getExtension("stellang.stellang");

  await check("activates on .st files", async () => {
    await until("activation", () => ext.isActive);
    assert.strictEqual(doc.languageId, "stellang");
  });
  await check("hover shows types from the type checker", async () => {
    const h = await until("hover", async () => {
      const r = await vscode.commands.executeCommand("vscode.executeHoverProvider", uri, at("store.add(", 7));
      return r.length && r;
    });
    const text = h.flatMap((x) => x.contents.map((c) => c.value ?? c)).join("\n");
    assert.match(text, /fn Store\.add\(self, title: str, priority: Priority\) -> Todo/);
  });
  await check("diagnostics follow edits", async () => {
    const pos = at("ws.send(\"echo", 3);
    const edit = new vscode.WorkspaceEdit();
    edit.insert(uri, pos, "x");
    assert.ok(await vscode.workspace.applyEdit(edit));
    const d = await until("an error", () => vscode.languages.getDiagnostics(uri).find((x) => /xsend/.test(x.message)));
    assert.strictEqual(d.severity, vscode.DiagnosticSeverity.Error);
    const undo = new vscode.WorkspaceEdit();
    undo.delete(uri, new vscode.Range(pos, pos.translate(0, 1)));
    assert.ok(await vscode.workspace.applyEdit(undo));
    await until("errors to clear", () => vscode.languages.getDiagnostics(uri).length === 0).catch((e) => {
      throw new Error(`${e.message}: ${JSON.stringify(vscode.languages.getDiagnostics(uri).map((d) => d.message))} text has xsend: ${doc.getText().includes("xsend")}`);
    });
  });
  await check("completion after a dot knows the type", async () => {
    const r = await vscode.commands.executeCommand("vscode.executeCompletionItemProvider", uri, at("store.add(\"try", 6));
    const labels = r.items.map((i) => (typeof i.label === "string" ? i.label : i.label.label));
    for (const want of ["add", "find", "todos"]) assert.ok(labels.includes(want), `${want} in ${labels}`);
  });
  await check("go to definition", async () => {
    const r = await vscode.commands.executeCommand("vscode.executeDefinitionProvider", uri, at("store.find(int", 7));
    assert.strictEqual(r[0].range.start.line, doc.positionAt(doc.getText().indexOf("fn find")).line);
  });
  await check("go to definition into std", async () => {
    const r = await vscode.commands.executeCommand("vscode.executeDefinitionProvider", uri, at("http.app()", 6));
    assert.match((r[0].uri ?? r[0].targetUri).fsPath, /std.*http\.st$/);
  });
  await check("references", async () => {
    const r = await vscode.commands.executeCommand("vscode.executeReferenceProvider", uri, at("fn find", 4));
    assert.ok(r.length >= 3, `found ${r.length}`);
  });
  await check("rename", async () => {
    const r = await vscode.commands.executeCommand("vscode.executeDocumentRenameProvider", uri, at("let publish", 5), "emit");
    assert.ok(r.get(uri).length >= 4);
  });
  await check("inlay type hints", async () => {
    const r = await vscode.commands.executeCommand("vscode.executeInlayHintProvider", uri, new vscode.Range(0, 0, doc.lineCount, 0));
    const labels = r.map((h) => (typeof h.label === "string" ? h.label : h.label.map((p) => p.value).join("")));
    assert.ok(labels.includes(": Store"), labels.join(" "));
  });
  await check("signature help", async () => {
    const r = await vscode.commands.executeCommand("vscode.executeSignatureHelpProvider", uri, at("store.add(\"try stellang\", ", 26));
    assert.strictEqual(r.activeParameter, 1);
    assert.match(r.signatures[0].label, /priority: Priority/);
  });
  await check("document symbols", async () => {
    const r = await vscode.commands.executeCommand("vscode.executeDocumentSymbolProvider", uri);
    const names = r.map((s) => s.name);
    for (const want of ["Todo", "Store", "Priority", "main"]) assert.ok(names.includes(want), names.join(" "));
  });
  await check("workspace symbols", async () => {
    const r = await vscode.commands.executeCommand("vscode.executeWorkspaceSymbolProvider", "Priority");
    assert.ok(r.some((s) => s.name === "Priority"));
  });
  await check("semantic tokens", async () => {
    const legend = await vscode.commands.executeCommand("vscode.provideDocumentSemanticTokensLegend", uri);
    const t = await vscode.commands.executeCommand("vscode.provideDocumentSemanticTokens", uri);
    assert.ok(legend.tokenTypes.includes("enumMember") && t.data.length > 500);
  });
  await check("folding", async () => {
    const r = await vscode.commands.executeCommand("vscode.executeFoldingRangeProvider", uri);
    assert.ok(r.length > 10);
  });
  await check("code lens: Run | Build", async () => {
    const r = await vscode.commands.executeCommand("vscode.executeCodeLensProvider", uri);
    assert.deepStrictEqual(r.map((l) => l.command.title), ["▶ Run", "Build"]);
  });
  await check("formatting", async () => {
    const r = await vscode.commands.executeCommand("vscode.executeFormatDocumentProvider", uri, { tabSize: 4, insertSpaces: true });
    assert.ok(!r || r.length === 0, `already formatted, got ${JSON.stringify(r)?.slice(0, 300)}`);
  });
  await check("emoji conversion", async () => {
    const t = await vscode.workspace.openTextDocument({ language: "stellang", content: "fn main() {\n    let x = 1\n}\n" });
    await vscode.window.showTextDocument(t);
    await vscode.commands.executeCommand("stellang.toEmoji");
    assert.match(t.getText(), /🦍 main\(\) ⭐/);
    await vscode.commands.executeCommand("stellang.toPlain");
    assert.match(t.getText(), /^fn main\(\) \{/);
    await vscode.commands.executeCommand("workbench.action.revertAndCloseActiveEditor");
  });
  await check("build task writes a binary", async () => {
    const file = path.join(os.tmpdir(), "stellang-vscode-test", "hello.st");
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, 'fn main() { println("hi") }\n');
    fs.rmSync(file.replace(/\.st$/, ""), { force: true });
    await vscode.window.showTextDocument(await vscode.workspace.openTextDocument(file));
    const done = new Promise((r) => vscode.tasks.onDidEndTaskProcess((e) => r(e.exitCode)));
    await vscode.commands.executeCommand("stellang.build");
    assert.strictEqual(await done, 0);
    assert.ok(fs.existsSync(file.replace(/\.st$/, "")));
  });
  await check("run starts the program", async () => {
    await vscode.workspace.getConfiguration("stellang").update("run.env", { PORT: "18766" }, vscode.ConfigurationTarget.Global);
    await vscode.commands.executeCommand("stellang.run", vscode.Uri.file(path.join(root, "server.st")));
    const body = await until("the server", () => get(18766, "/hello/vscode"), 60000);
    assert.strictEqual(body, "hi vscode!");
    await vscode.workspace.getConfiguration("stellang").update("run.env", undefined, vscode.ConfigurationTarget.Global);
    vscode.window.terminals.forEach((t) => t.dispose());
  });

  // ---- smarter completion, quick fixes ----
  const scratch = path.join(os.tmpdir(), "stellang-vscode-test", "scratch.st");
  fs.mkdirSync(path.dirname(scratch), { recursive: true });
  const base = [
    "enum Shape { Circle(float), Rect { w: float, h: float }, Empty }",
    "struct Todo {",
    "    id: int,",
    "    title: str,",
    "    done: bool = false,",
    "}",
    "fn area(s: Shape) -> float {",
    "    return match s {",
    "        .Empty => 0.0,",
    "    }",
    "}",
    "fn main() {",
    "    let t = Todo { id: 1, title: \"x\" }",
    "    println(t.title)",
    "}",
    "",
  ].join("\n");
  fs.writeFileSync(scratch, base);
  const sdoc = await vscode.workspace.openTextDocument(scratch);
  await vscode.window.showTextDocument(sdoc);
  const typeAt = async (line, text) => {
    const e = new vscode.WorkspaceEdit();
    e.insert(sdoc.uri, new vscode.Position(line, 0), text + "\n");
    await vscode.workspace.applyEdit(e);
    return new vscode.Position(line, text.length);
  };
  const labels = async (pos) => {
    const r = await vscode.commands.executeCommand("vscode.executeCompletionItemProvider", sdoc.uri, pos);
    return r.items.map((i) => (typeof i.label === "string" ? i.label : i.label.label));
  };
  const reset = async () => {
    const e = new vscode.WorkspaceEdit();
    e.replace(sdoc.uri, new vscode.Range(0, 0, sdoc.lineCount, 0), base);
    await vscode.workspace.applyEdit(e);
  };
  await check("completion offers the fields a struct literal still needs", async () => {
    const pos = await typeAt(14, "    let u = Todo { id: 2, ");
    const ls = await until("fields", async () => {
      const l = await labels(pos);
      return l.includes("title") && l;
    });
    assert.ok(!ls.includes("id") && ls.includes("done"), ls.slice(0, 10).join(","));
    await reset();
  });
  await check("completion knows which enum a .Variant needs", async () => {
    const pos = await typeAt(14, "    let s: Shape = .");
    const ls = await until("variants", async () => {
      const l = await labels(pos);
      return l.includes("Circle") && l;
    });
    assert.ok(ls.includes("Rect") && ls.includes("Empty"), ls.join(","));
    await reset();
  });
  await check("postfix completion: value.match writes every arm", async () => {
    const pos = await typeAt(14, "    area(.Empty).");
    const r = await until("postfix", async () => {
      const x = await vscode.commands.executeCommand("vscode.executeCompletionItemProvider", sdoc.uri, pos);
      return x.items.find((i) => i.label === "match" || i.label?.label === "match") && x;
    });
    assert.ok(r.items.some((i) => (i.label.label ?? i.label) === "floor"));
    await reset();
  });
  await check("quick fix adds missing match arms", async () => {
    const d = await until("match diagnostic", () => vscode.languages.getDiagnostics(sdoc.uri).find((x) => /doesn't handle/.test(x.message)));
    const actions = await vscode.commands.executeCommand("vscode.executeCodeActionProvider", sdoc.uri, d.range, vscode.CodeActionKind.QuickFix.value);
    const fix = actions.find((a) => /missing match arms/.test(a.title));
    assert.ok(fix, actions.map((a) => a.title).join(","));
    await vscode.workspace.applyEdit(fix.edit);
    assert.ok(sdoc.getText().includes(".Circle(x) =>") && sdoc.getText().includes(".Rect { w, h } =>"));
    await until("no errors", () => vscode.languages.getDiagnostics(sdoc.uri).length === 0);
    await reset();
  });
  await check("quick fix imports a std module", async () => {
    const e = new vscode.WorkspaceEdit();
    e.replace(sdoc.uri, new vscode.Range(0, 0, sdoc.lineCount, 0), "fn main() {\n    let app = http.app()\n}\n");
    await vscode.workspace.applyEdit(e);
    const d = await until("unknown http", () => vscode.languages.getDiagnostics(sdoc.uri).find((x) => /`http`/.test(x.message)));
    const actions = await vscode.commands.executeCommand("vscode.executeCodeActionProvider", sdoc.uri, d.range, vscode.CodeActionKind.QuickFix.value);
    const fix = actions.find((a) => a.title === "Import `http`");
    assert.ok(fix, actions.map((a) => a.title).join(","));
    await vscode.workspace.applyEdit(fix.edit);
    assert.ok(sdoc.getText().startsWith("import http\n"));
    await reset();
  });
  await sdoc.save();
  await vscode.commands.executeCommand("workbench.action.closeActiveEditor");

  // ---- the app: sidebar, runner, templates, IR, themes ----
  const api = ext.exports;
  await check("Programs view lists the programs", async () => {
    const items = await api.trees.programs.getChildren();
    const names = items.map((i) => i.label);
    assert.ok(names.includes("todos.st") && names.includes("server.st"), names.join(","));
  });
  await check("Types view shows structs and enums with their fields", async () => {
    const items = await until("types", async () => {
      const x = await api.trees.model.getChildren();
      return x.some((i) => i.label === "Todo") && x;
    });
    // (examples/fullstack has a Todo of its own)
    const kids = [];
    for (const todo of items.filter((i) => i.label === "Todo")) kids.push(...(await api.trees.model.getChildren(todo)).map((i) => i.label));
    assert.ok(kids.includes("title") && kids.includes("priority"), kids.join(","));
    assert.ok(items.some((i) => i.label === "Priority"));
  });
  await check("HTTP Routes view finds the routes", async () => {
    const files = await api.trees.routes.getChildren();
    const all = (await Promise.all(files.map((f) => api.trees.routes.getChildren(f)))).flat().map((i) => i.label);
    assert.ok(all.includes("GET /todos") && all.includes("WS /feed") && !all.includes("GET status"), all.join(","));
  });
  await check("the runner notices a server's address, stops and restarts it", async () => {
    await vscode.workspace.getConfiguration("stellang").update("run.env", { PORT: "18767" }, vscode.ConfigurationTarget.Global);
    await vscode.workspace.getConfiguration("stellang").update("run.openBrowser", "never", vscode.ConfigurationTarget.Global);
    const file = path.join(root, "server.st");
    api.runner.run(file);
    const r = await until("the url", () => api.runner.runs.get(file)?.url, 60000);
    assert.ok(/:18767/.test(r), r);
    await api.runner.stop(file);
    await until("stopped", async () => (await get(18767, "/hello/x")) === null);
    api.runner.runs.get(file).restart();
    await until("restarted", () => get(18767, "/hello/again"), 60000);
    vscode.window.terminals.forEach((t) => t.dispose());
    await until("cleaned up", () => api.runner.runs.size === 0);
    await vscode.workspace.getConfiguration("stellang").update("run.env", undefined, vscode.ConfigurationTarget.Global);
  });
  await check("every project template compiles", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "stellang-templates-"));
    for (const id of api.templates) {
      api.createProject(id, path.join(dir, id), `t-${id}`);
      for (const f of id === "fullstack" ? ["server.st", "client.st"] : ["main.st"]) {
        const main = path.join(dir, id, f);
        const done = new Promise((r) => vscode.tasks.onDidEndTaskProcess((e) => r(e.exitCode)));
        await vscode.window.showTextDocument(await vscode.workspace.openTextDocument(main));
        await vscode.commands.executeCommand("stellang.check");
        assert.strictEqual(await done, 0, `${id}/${f} doesn't type-check`);
      }
    }
  });
  await check("JSX: completion offers components, then their props", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "stellang-jsx-"));
    const file = path.join(dir, "ui.st");
    fs.writeFileSync(file, 'import web\n\nfn Badge(count: int, label: str?) -> Node {\n    return <b title={label}>{count}</b>\n}\n\nfn App() -> Node {\n    return <main>\n    </main>\n}\n');
    const d = await vscode.workspace.openTextDocument(file);
    const ed = await vscode.window.showTextDocument(d);
    await until("diagnostics settle", async () => (await vscode.commands.executeCommand("vscode.executeHoverProvider", d.uri, new vscode.Position(2, 4))).length);
    await ed.edit((e) => e.insert(new vscode.Position(8, 0), "        <\n"));
    const tags = await until("tag completion", async () => {
      const r = await vscode.commands.executeCommand("vscode.executeCompletionItemProvider", d.uri, new vscode.Position(8, 9));
      return r.items.some((i) => i.label === "Badge" || i.label.label === "Badge") && r;
    });
    const badge = tags.items.find((i) => (i.label.label || i.label) === "Badge");
    assert.match(badge.insertText.value, /^Badge count=\{\$\{1\}\} \/>$/, badge.insertText.value);
    assert.ok(tags.items.some((i) => (i.label.label || i.label) === "div"));
    await ed.edit((e) => e.replace(new vscode.Range(8, 0, 9, 0), "        <Badge \n"));
    const props = await until("prop completion", async () => {
      const r = await vscode.commands.executeCommand("vscode.executeCompletionItemProvider", d.uri, new vscode.Position(8, 15));
      return r.items.some((i) => (i.label.label || i.label) === "count") && r;
    });
    assert.ok(props.items.some((i) => (i.label.label || i.label) === "label"));
    await vscode.commands.executeCommand("workbench.action.revertAndCloseActiveEditor");
  });
  await check("the runner builds a browser app and serves it", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "stellang-browser-"));
    api.createProject("browser", path.join(dir, "app"), "app");
    const file = path.join(dir, "app", "main.st");
    api.runner.run(file);
    const url = await until("the url", () => api.runner.runs.get(file)?.url, 90000);
    const port = +new URL(url).port;
    assert.match(await get(port, "/"), /<script src="\/main\.js"><\/script>/);
    assert.match(await get(port, "/main.js"), /stellang web loader/);
    await api.runner.stop(file);
    vscode.window.terminals.forEach((t) => t.dispose());
    await until("cleaned up", () => api.runner.runs.size === 0);
  });
  await check("Show LLVM IR opens the generated code", async () => {
    await vscode.window.showTextDocument(await vscode.workspace.openTextDocument(path.join(root, "server.st")));
    await vscode.commands.executeCommand("stellang.showIr");
    const ir = await until("the .ll", () => vscode.workspace.textDocuments.find((d) => d.fileName.endsWith("server.ll")));
    assert.ok(ir.getText().includes("define"));
  });
  await check("the star themes load", async () => {
    for (const t of ["Stellang Nebula", "Stellang Daybreak"]) {
      await vscode.workspace.getConfiguration("workbench").update("colorTheme", t, vscode.ConfigurationTarget.Global);
      await until(t, () => vscode.window.activeColorTheme.kind === (t.includes("Nebula") ? vscode.ColorThemeKind.Dark : vscode.ColorThemeKind.Light));
    }
  });

  await vscode.commands.executeCommand("workbench.action.files.revert");
  const report = results.join("\n");
  console.log(`\n${report}\n`);
  fs.writeFileSync(path.join(os.tmpdir(), "stellang-vscode-test-report.txt"), report);
  if (results.some((r) => r.startsWith("FAIL"))) throw new Error("some checks failed");
};
