# Publishing the extension

Nothing publishes automatically. To put it on the registries by hand:

## VS Code Marketplace

1. Sign in at <https://marketplace.visualstudio.com/manage> and create a publisher. Its ID must equal
   `publisher` in `package.json` (currently `stellang`; change one or the other).
2. Create a personal access token at <https://dev.azure.com> → *User settings* → *Personal access tokens*:
   organization **All accessible organizations**, scope **Marketplace → Manage**.
3. From `editors/vscode`:

   ```sh
   npm install
   npm run package                                   # stellang-<version>.vsix, compiler inside (this platform)
   npx vsce publish --packagePath stellang-*.vsix -p <token>
   ```

   A `.vsix` built with `npm run package` carries a compiler for the machine that built it; to publish
   per-platform builds, package on each platform with `npx vsce package --target <linux-x64|darwin-arm64|...>`.
   `npm run package:nobin` makes a universal one that uses the `stellang` on the user's PATH.

## Open VSX (VSCodium, Cursor, ...)

1. Sign in at <https://open-vsx.org> with GitHub, sign the publisher agreement, create an access token.
2. `npx ovsx create-namespace stellang -p <token>` once, then `npx ovsx publish stellang-*.vsix -p <token>`.
