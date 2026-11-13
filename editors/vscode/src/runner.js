// Runs programs in a terminal the extension owns (a pseudoterminal), so it knows what is running,
// can stop and restart it, and notices when a server starts listening.
const vscode = require("vscode");
const cp = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const URL_RE = /\bhttps?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::\]):(\d+)\S*/;
const RESET = "\x1b[0m";
const DIM = "\x1b[2m";
const GOLD = "\x1b[38;2;255;209;102m";
const RED = "\x1b[38;2;255;93;143m";
const GREEN = "\x1b[38;2;79;224;160m";

class Run {
  constructor(runner, file) {
    this.runner = runner;
    this.file = file;
    this.name = path.basename(file);
    this.state = "starting"; // starting | building | running | exited | failed
    this.url = undefined;
    this.child = undefined;
    this.started = 0;
    this.writeEmitter = new vscode.EventEmitter();
    this.closeEmitter = new vscode.EventEmitter();
    const pty = {
      onDidWrite: this.writeEmitter.event,
      onDidClose: this.closeEmitter.event,
      open: () => this.start(),
      close: () => this.kill(true),
      handleInput: (data) => this.input(data),
    };
    this.terminal = vscode.window.createTerminal({ name: `⭐ ${this.name}`, pty, iconPath: new vscode.ThemeIcon("star-full") });
  }

  write(s) {
    this.writeEmitter.fire(s.replace(/\r?\n/g, "\r\n"));
  }

  set(state) {
    this.state = state;
    this.runner.changed();
  }

  async start() {
    const { compiler, config } = this.runner;
    const c = compiler();
    if (!c) {
      this.write(`${RED}The stellang compiler wasn't found.${RESET}\n`);
      return this.set("failed");
    }
    const outDir = path.join(os.tmpdir(), "stellang-run");
    fs.mkdirSync(outDir, { recursive: true });
    const exe = path.join(outDir, path.basename(this.file, ".st") + (process.platform === "win32" ? ".exe" : ""));
    const opt = config().get("optimization");
    this.url = undefined;
    this.set("building");
    this.write(`${GOLD}⭐ building${RESET} ${DIM}${this.file}${RESET}\n`);
    const t0 = Date.now();
    const build = cp.spawn(c.path, [opt, this.file, "-o", exe], { cwd: path.dirname(this.file) });
    this.child = build;
    build.stdout.on("data", (d) => this.write(d.toString()));
    build.stderr.on("data", (d) => this.write(`${RED}${d}${RESET}`));
    build.on("error", (e) => {
      this.write(`${RED}${e.message}${RESET}\n`);
      this.set("failed");
    });
    build.on("close", (code) => {
      if (this.child !== build) return; // stopped meanwhile
      if (code !== 0) {
        this.write(`\n${RED}✗ build failed${RESET} ${DIM}(see Problems)${RESET}\n`);
        this.child = undefined;
        return this.set("failed");
      }
      this.write(`${GREEN}✓ built${RESET} ${DIM}in ${Date.now() - t0} ms${RESET}\n\n`);
      this.exec(exe);
    });
  }

  exec(exe) {
    const env = { ...process.env, ...(this.runner.config().get("run.env") || {}) };
    const args = this.runner.config().get("run.args") || [];
    const child = cp.spawn(exe, args, { cwd: path.dirname(this.file), env });
    this.child = child;
    this.started = Date.now();
    this.set("running");
    const scan = (s) => {
      if (this.url) return;
      const m = URL_RE.exec(s);
      if (m) {
        this.url = m[0].replace("0.0.0.0", "localhost").replace("[::]", "localhost");
        this.runner.changed();
        this.runner.announce(this);
      }
    };
    child.stdout.on("data", (d) => {
      const s = d.toString();
      this.write(s);
      scan(s);
    });
    child.stderr.on("data", (d) => {
      const s = d.toString();
      this.write(`${RED}${s}${RESET}`);
      scan(s);
    });
    child.on("error", (e) => {
      this.write(`${RED}${e.message}${RESET}\n`);
      this.set("failed");
    });
    child.on("close", (code, signal) => {
      if (this.child !== child) return;
      this.child = undefined;
      const secs = ((Date.now() - this.started) / 1000).toFixed(1);
      const how = signal ? `stopped (${signal})` : `exited with code ${code}`;
      this.write(`\n${code === 0 ? GREEN : DIM}● ${how}${RESET} ${DIM}after ${secs} s — press any key to run again${RESET}\n`);
      this.url = undefined;
      this.set(code === 0 || signal ? "exited" : "failed");
    });
  }

  input(data) {
    if (!this.child || this.state !== "running") {
      if (this.state === "exited" || this.state === "failed") this.restart();
      return;
    }
    if (data === "\x03") return this.kill(); // ctrl+c
    const text = data.replace(/\r/g, "\n");
    this.write(data === "\r" ? "\n" : data.replace(/\x7f/g, "\b \b"));
    try {
      this.child.stdin.write(text);
    } catch {
      // the program closed stdin
    }
  }

  kill(closing) {
    const c = this.child;
    this.child = undefined;
    if (c && c.exitCode === null) {
      try {
        c.kill("SIGTERM");
        setTimeout(() => c.exitCode === null && c.kill("SIGKILL"), 1500);
      } catch {
        // gone already
      }
      if (!closing) {
        this.write(`\n${DIM}● stopped${RESET}\n`);
        this.url = undefined;
        this.set("exited");
      }
    }
    if (closing) this.runner.forget(this);
  }

  restart() {
    this.kill();
    this.write(`\x1b[2J\x1b[3J\x1b[H`); // clear
    this.start();
  }
}

class Runner {
  constructor(compiler, config) {
    this.compiler = compiler;
    this.config = config;
    this.runs = new Map(); // file -> Run
    this.changeEmitter = new vscode.EventEmitter();
    this.onDidChange = this.changeEmitter.event;
    this.status = vscode.window.createStatusBarItem("stellang.running", vscode.StatusBarAlignment.Left, 9);
    this.status.name = "stellang: running program";
    this.status.command = "stellang.runMenu";
  }

  run(file, { focus = true } = {}) {
    let r = this.runs.get(file);
    if (r) {
      r.restart();
    } else {
      r = new Run(this, file);
      this.runs.set(file, r);
    }
    r.terminal.show(!focus);
    this.changed();
    return r;
  }

  stop(file) {
    const r = file ? this.runs.get(file) : this.current();
    r?.kill();
  }

  current() {
    const active = vscode.window.activeTextEditor?.document.uri.fsPath;
    return this.runs.get(active) ?? [...this.runs.values()].reverse().find((r) => r.child) ?? [...this.runs.values()].pop();
  }

  forget(run) {
    if (this.runs.get(run.file) === run) this.runs.delete(run.file);
    this.changed();
  }

  announce(run) {
    const mode = this.config().get("run.openBrowser");
    if (mode === "always") return vscode.env.openExternal(vscode.Uri.parse(run.url));
    if (mode === "never") return;
    vscode.window.showInformationMessage(`⭐ ${run.name} is listening on ${run.url}`, "Open in Browser", "Open in Editor").then((pick) => {
      if (pick === "Open in Browser") vscode.env.openExternal(vscode.Uri.parse(run.url));
      if (pick === "Open in Editor") vscode.commands.executeCommand("simpleBrowser.show", run.url);
    });
  }

  changed() {
    const live = [...this.runs.values()].filter((r) => r.child);
    vscode.commands.executeCommand("setContext", "stellang.running", live.length > 0);
    if (live.length) {
      const r = live[live.length - 1];
      const port = r.url ? ` $(globe) ${new URL(r.url).port}` : "";
      this.status.text = `$(debug-stop) ${r.name}${port}`;
      this.status.tooltip = `${r.name} is ${r.state}${r.url ? ` on ${r.url}` : ""} — click for actions`;
      this.status.show();
    } else {
      this.status.hide();
    }
    this.changeEmitter.fire();
  }

  dispose() {
    for (const r of this.runs.values()) r.kill(true);
    this.status.dispose();
  }
}

module.exports = { Runner };
