# Publishing the extension

Releases are automatic: push a tag `vX.Y.Z` that matches `version` in `package.json`, and the
`vscode extension` workflow tests the extension, builds a `.vsix` for each platform (each with the compiler
inside) plus a universal one, attaches them to a GitHub release, and publishes them to the VS Code
Marketplace and Open VSX (for VSCodium, Cursor, Gitpod, ...).

## One-time setup

### VS Code Marketplace

1. Sign in at <https://marketplace.visualstudio.com/manage> with a Microsoft account and create a publisher.
   Its ID must equal `publisher` in `package.json` (currently `stellang`; change one or the other).
2. Create a personal access token at <https://dev.azure.com> → *User settings* → *Personal access tokens*:
   organization **All accessible organizations**, scope **Marketplace → Manage**.
3. Add it to the GitHub repository as the secret `VSCE_PAT`
   (*Settings → Secrets and variables → Actions → New repository secret*).

### Open VSX (optional)

1. Sign in at <https://open-vsx.org> with GitHub, sign the publisher agreement, and create an access token.
2. Create the namespace once: `npx ovsx create-namespace stellang -p <token>`.
3. Add the token as the secret `OVSX_PAT`.

A missing secret only skips that registry; the GitHub release still happens.

## Releasing

```sh
# bump "version" in editors/vscode/package.json (and CHANGELOG.md), commit, then:
git tag v0.2.0
git push origin v0.2.0
```
