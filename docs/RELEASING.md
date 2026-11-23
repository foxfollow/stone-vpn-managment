# Releasing StoneVPN Manager

Releases are built by `.github/workflows/release.yml` on a `vX.Y.Z` tag — same flow as
Stone Clipboarder Tool: unsigned Release build → ad-hoc signature → `StoneVPNManager.zip` →
Sparkle EdDSA signature → `docs/appcast.xml` item → GitHub Release → appcast committed to `main`
(served by GitHub Pages) → cask `stone-vpn-manager` bumped in `foxfollow/homebrew-stone`.

`.github/workflows/ci.yml` runs on every push/PR: bash syntax + shellcheck (errors), StoneVPNKit unit
tests and an unsigned Release build with the runner's Xcode.

## One-time setup

### 1. Sparkle key pair

```bash
# Sparkle tools (same version as Package.resolved / SPARKLE_VERSION in release.yml)
curl -fsSLO https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz
mkdir sparkle && tar -xJf Sparkle-2.10.1.tar.xz -C sparkle

sparkle/bin/generate_keys --account stonevpn-manager           # creates the key in your login Keychain, prints the PUBLIC key
sparkle/bin/generate_keys --account stonevpn-manager -x sparkle_private_key.txt   # exports the PRIVATE key
```

- **Public key** → repository variable `SPARKLE_PUBLIC_KEY` (Settings → Secrets and variables → Actions →
  Variables). CI bakes it into `SUPublicEDKey`. Alternatively commit it as the `SPARKLE_PUBLIC_KEY`
  build setting in the Xcode project — it is public.
- **Private key** → repository secret `SPARKLE_PRIVATE_KEY` (the file's content). Then delete the exported
  file; the Keychain copy is your backup. Never commit it.

The workflow verifies the zip's signature against the public key baked into the built app, so a
mismatched pair fails the release instead of breaking updates for everyone.

```bash
gh variable set SPARKLE_PUBLIC_KEY --body "<public key>"
gh secret set SPARKLE_PRIVATE_KEY < sparkle_private_key.txt && rm -P sparkle_private_key.txt
```

### 2. Homebrew tap access

Preferred — a **deploy key** with write access to `foxfollow/homebrew-stone` only:

```bash
ssh-keygen -t ed25519 -N "" -C "stone-vpn-managment release" -f tap_key
gh repo deploy-key add tap_key.pub -R foxfollow/homebrew-stone --allow-write -t "stone-vpn-managment release"
gh secret set HOMEBREW_TAP_DEPLOY_KEY -R foxfollow/stone-vpn-managment < tap_key && rm -P tap_key tap_key.pub
```

Fallback — a fine-grained PAT (Contents: Read and write on the tap) as `HOMEBREW_TAP_TOKEN`.
Without either, the release still works; the cask bump is skipped with a warning.

The cask file `Casks/stone-vpn-manager.rb` must exist in the tap before the first release — the workflow
only bumps `version` and `sha256`.

### 3. GitHub Pages

Settings → Pages → Source: **Deploy from a branch**, branch `main`, folder **`/docs`**.
The site and `appcast.xml` (the app's `SUFeedURL`) are served from there:
`https://foxfollow.github.io/stone-vpn-managment/`.

### 4. Actions permissions

Settings → Actions → General → Workflow permissions: **Read and write** (the workflow creates the release
and pushes the appcast to `main`). If `main` is protected, allow `github-actions[bot]` to push or the
appcast commit step fails.

### 5. Code quality (SonarCloud)

`shellcheck.yml` and `codeql.yml` need nothing. For `sonar.yml`:

1. sonarcloud.io → **+ → Analyze new project** → organization `foxfollow` → `stone-vpn-managment`
   (key `foxfollow_stone-vpn-managment`, as in `sonar-project.properties`).
2. Administration → Analysis Method: turn **Automatic Analysis off** (the workflow uploads coverage).
3. My Account → Security → generate a token → `gh secret set SONAR_TOKEN -R foxfollow/stone-vpn-managment`.

Until the secret exists the Sonar job only prints a warning. Coverage = StoneVPNKit unit tests
(`tools/coverage-to-sonar.sh` turns `swift test --enable-code-coverage` into Sonar's generic format).

## Cutting a release

1. Bump **both** versions in `app/StoneVPNManager/StoneVPNManager.xcodeproj/project.pbxproj` (all four
   target configurations):
   - `MARKETING_VERSION` = `X.Y.Z` — must equal the tag;
   - `CURRENT_PROJECT_VERSION` = integer, higher than the last `<sparkle:version>` in `docs/appcast.xml`.
2. Write the notes into the `<new>` block of `docs/appcast.xml` (`<li>` per line). The workflow moves them
   into the appcast item and the GitHub release body.
3. Commit to `main`, then:

   ```bash
   git tag v0.2.0 && git push origin v0.2.0
   ```

   or run the workflow manually (Actions → Build and Release → version `X.Y.Z`).

If the helper's XPC protocol changed, bump `HelperConst.version` — users then see "outdated — reinstall"
in Settings → Helper after updating.

## Notes

- Release builds pass `STONEVPN_UPDATES=YES` (Sparkle on) and an empty `STONEVPN_REPO_PATH` (no runner
  path baked into Info.plist). Local builds keep Sparkle off: a Team-signed build can't be updated by an
  ad-hoc release anyway.
- Ad-hoc signing order: Sparkle.framework (deep) → `StoneVPNManagerHelper` with identifier
  `com.foxfollow.stonevpnmanager.helper` → the app. In ad-hoc builds the helper accepts XPC only from the
  cdhash of the bundle it lives in (`clientRequirement()` in `StoneVPNManagerHelper/main.swift`).
- Bumping Sparkle (Dependabot): update `SPARKLE_VERSION` and `SPARKLE_SHA256` in `release.yml` together
  (`shasum -a 256 Sparkle-X.Y.Z.tar.xz`, compare with the digest on the GitHub release).
