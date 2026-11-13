// Starts `stellang lsp` (the compiler itself) as the language server.
const vscode = require("vscode");
const { LanguageClient } = require("vscode-languageclient/node");

let client;

function start() {
  const command = vscode.workspace.getConfiguration("stellang").get("path") || "stellang";
  client = new LanguageClient(
    "stellang",
    "stellang",
    { command, args: ["lsp"] },
    { documentSelector: [{ scheme: "file", language: "stellang" }] }
  );
  return client.start();
}

exports.activate = (ctx) => {
  start();
  ctx.subscriptions.push(
    vscode.commands.registerCommand("stellang.restart", async () => {
      if (client) await client.stop();
      await start();
    }),
    vscode.workspace.onDidChangeConfiguration(async (e) => {
      if (e.affectsConfiguration("stellang.path")) vscode.commands.executeCommand("stellang.restart");
    })
  );
};

exports.deactivate = () => client && client.stop();
