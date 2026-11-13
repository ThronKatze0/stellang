// Copies the compiler into bin/ so the packaged extension works without installing anything.
// Builds it first if needed (cargo build --release at the repo root).
const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "../../..");
const exe = process.platform === "win32" ? "stellang.exe" : "stellang";
const built = path.join(root, "target", "release", exe);
if (!process.env.STELLANG_SKIP_BUILD) {
  execSync("cargo build --release", { cwd: root, stdio: "inherit" });
}
if (!fs.existsSync(built)) {
  console.error(`no compiler at ${built}`);
  process.exit(1);
}
const bin = path.join(__dirname, "..", "bin");
fs.mkdirSync(bin, { recursive: true });
fs.copyFileSync(built, path.join(bin, exe));
fs.chmodSync(path.join(bin, exe), 0o755);
console.log(`bundled ${built} -> bin/${exe}`);
