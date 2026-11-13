// Downloads VS Code, starts it with this extension on the repo's examples/, runs test/suite.js.
// `npm test` (needs a display: use xvfb-run on Linux CI).
const fs = require("fs");
const os = require("os");
const path = require("path");
const { runTests } = require("@vscode/test-electron");

runTests({
  extensionDevelopmentPath: path.resolve(__dirname, ".."),
  extensionTestsPath: path.resolve(__dirname, "suite.js"),
  launchArgs: [
    path.resolve(__dirname, "../../../examples"),
    "--disable-extensions",
    "--skip-welcome",
    "--skip-release-notes",
    // a fresh profile each run, so no restored editors from an earlier run
    `--user-data-dir=${fs.mkdtempSync(path.join(os.tmpdir(), "stellang-vscode-"))}`,
  ],
}).catch((e) => {
  console.error(e);
  process.exit(1);
});
