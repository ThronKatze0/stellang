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

  await vscode.commands.executeCommand("workbench.action.files.revert");
  const report = results.join("\n");
  console.log(`\n${report}\n`);
  fs.writeFileSync(path.join(os.tmpdir(), "stellang-vscode-test-report.txt"), report);
  if (results.some((r) => r.startsWith("FAIL"))) throw new Error("some checks failed");
};
