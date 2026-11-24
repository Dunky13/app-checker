# Handoff: first release (v0.1.0)

Status on 2026-11-24: the app is built, tested, reviewed and pushed to `main`. The release itself has not been made, because notarization credentials were not available. Until it is made, `appcast.xml` does not exist and Sparkle has nothing to update from.

## What exists

- The app and its repository are named Kanarie. They were called App Checker (`Dunky13/app-checker`) until 2026-11-24; GitHub redirects the old address. The bundle identifier is `io.went.kanarie`. Settings, saved state and a stored API key of an App Checker build are not carried over, which affects no one because nothing was released. The icon and the README logo (a canary carrying a blue medieval shield) are drawn by `scripts/make-icon.swift`.
- A menu bar app (no Dock icon, starts at login) that lists apps, Homebrew formulae and casks, commands in `~/.local/bin`, global npm and pnpm packages and editor extensions, with a green, yellow, red or grey verdict per item. See the [README](../README.md).
- Verdicts from the curated findings ([findings/](../findings), one folder per app and one file per version from which a finding holds, 44 apps), an on-demand AI lookup (Claude Code CLI or an OpenAI-compatible endpoint such as OpenRouter) and an offline hint that stays grey.
- A form on every item to submit a finding or a correction as a prefilled GitHub issue, with the app's format checks, what the checks read on that Mac, and a search of the cited pages for the names the finding relies on.
- Sparkle 2 for updates, fed from `appcast.xml` on `main`. The same EdDSA key signs `findings/index.json`, which lists every finding file with its hash, and the app refuses downloaded findings that do not match a signed index or whose index is older than the one it has.
- `scripts/build-app.sh`, `scripts/sign-findings.sh`, `scripts/release.sh`, and CI that runs the tests and a release build on every push.

## Evidence

Checked by running it, on one Mac (macOS 27, Apple Silicon):

- `swift test`: 39 tests in 10 suites pass locally. CI results are linked from each commit and pull request page.
- First run: window opens, login item is registered, notification permission is requested. Second launch is silent and Sparkle asks once about automatic checks.
- A new app bundle dropped into `~/Applications` was detected in about 12 seconds and produced a notification.
- Search, the filter menu, the detail pane, the copy button, the "Data Access Blocked" note, and the AI marker in the list.
- A real lookup through the Claude Code CLI with web search, and a lookup through the OpenAI-compatible backend against a local stub (key read from the keychain, no redirect followed).
- The findings download, with a test build that read the `findings-folder` branch and shipped an older bundled copy (serial 1, one changed file): it fetched the signed index, replaced its copy, and its cache was identical to the committed folder. A relaunch with nothing new left the cache untouched. A cached file changed by hand to claim "no telemetry" was not used (the item stayed yellow) and was replaced at the next launch. With the cache deleted and the saved serial set above the published one, the published index was refused.
- The submit form, with a seeded AI result that named an invented variable: the form showed what its check read on the Mac, the source check fetched the cited page and reported the name as not found, and Continue Anyway opened a GitHub issue page with the title and the finding filled in. An item without any finding opened an empty form that listed what was missing and kept Continue disabled. With a local web server running, cited links to `127.0.0.1`, to `localhost` and to a public address that redirects to the local server were all left out (the server logged no request, and did log one when `curl` followed the same redirect), while a public page in the same list was fetched. After the HTTPS rule: a plain HTTP link and an HTTPS link that redirects to plain HTTP or to this Mac were not fetched; an HTTPS link and an HTTPS link redirecting to another HTTPS page were.
- The submit form after the review fixes, as a correction of the Homebrew finding: Cancel during the fetch closed the form and opened no browser tab. Continue fetched 2 of the 3 cited pages (GitHub answered the third request with an error at that moment), reported `HOMEBREW_NO_ANALYTICS` as found and `analyticsdisabled = true` as not found, and Continue Anyway opened an issue that says which finding it corrects and from which version, with every name and reading in a code span. Replace These Checks swapped the two kept checks for the variable fields.
- `Kanarie --list` on that Mac: 216 items, of which 15 yellow, 3 green and 198 grey. The native Claude Code install is found as `bin:claude`.

Reviewed independently (Claude Opus, high effort), each round followed by fixes:

1. Standards and security review of the first commit.
2. Spec and rules accuracy review: every rule compared with the vendor's documentation or source.
3. Three re-reviews of the fixes, which closed the remaining false-green cases (GitHub CLI precedence, two Homebrew installs, commented-out settings, extensions in several editors). The last one found no false green.
4. Review of the submit form and of version selection: its findings (forged Markdown in the issue, corrections always proposed as the first file, no total time limit, part-of-a-word matches, address ranges, a dropped file for a dashed pre-release) are fixed and covered by tests.
5. Re-review of those fixes: it found that a version with a packager's label after the dash (`5.4.0-0ubuntu1`) lost the file for `5.4` and could show green by omission, that any port could be named in a cited link, and that an AI answer could claim to correct a finding. All three are fixed and covered by tests, together with its smaller findings.
6. Re-check of that round: versions with a patch letter or label straight after the numbers (`9.9p2`, `1.1.1w`) lost the file for their release in the same way, and a word-boundary change hid variable names behind a dot or colon. Both are fixed and covered by tests.

## Not verified

- The release script, notarization, the stapled app on another Mac, and a real Sparkle update. None of these can run before the first release exists.
- Submitting an issue: the prefilled page was opened and read, not submitted. Corrections of a curated finding and a body too long for a link were tested in unit tests only.
- OpenRouter itself (only a local stub was used), and the notification for an updated (as opposed to new) item.
- Editors that were not installed on the test Mac: VS Code Insiders, VSCodium and Windsurf. Their settings folder names come from their documentation.
- An Intel Mac and a Mac with two Homebrew installs.
- These rule details: whether Chrome's usage statistics are on by default in every region, the `dev.zed.Zed-Preview` bundle identifier, which values Turborepo and Gatsby accept besides `1`.

## To release

On the maintainer's Mac, with the Developer ID certificate and the Sparkle key in the login keychain, from a clean and pushed `main`:

```sh
# Once. Asks for an app-specific password from account.apple.com and stores it in the keychain.
xcrun notarytool store-credentials kanarie-notary --apple-id <apple id> --team-id <team id>

NOTARY_KEYCHAIN_PROFILE=kanarie-notary scripts/release.sh 0.1.0
```

Expected: tests pass, notarization status `Accepted`, the app is stapled and passes `spctl`, a GitHub release `v0.1.0` with `Kanarie-0.1.0-universal.zip` exists, and a commit `Release 0.1.0` adds `appcast.xml`. macOS may ask once for permission to use the Sparkle key: choose Always Allow. If notarization times out, do not submit again: continue with `xcrun notarytool wait <id>` using the receipt in `build/notary/`.

Then check updating end to end:

```sh
CODESIGN_IDENTITY="Developer ID Application" scripts/build-app.sh 0.0.9
open "build/Kanarie.app"   # menu bar bird > Check for Updates…
```

Expected: Sparkle offers 0.1.0, installs it and relaunches.

Back up the Sparkle private key (`.build/artifacts/sparkle/Sparkle/bin/generate_keys -x <file>`, then store the file in a password manager and delete it). Without it no update and no rules change can be signed.

After any change below `findings/`: run `scripts/sign-findings.sh` and commit `index.json` and `index.json.sig` with it, otherwise the test fails and installed apps keep their old findings.

## Known limits, left open on purpose

- The source check gives every page 20 seconds and starts no page after a minute, so it can take up to 80 seconds. The name lookup of a host cannot be interrupted by Cancel; the form closes and the lookup ends on its own.
- Names that a command only carries as a flag, a `git config` key or a JSON key are not looked for on the cited pages.
- The submit form keeps the checks of the finding it started from, or drops them all ("Replace These Checks") so one variable can be named by hand; other checks are written by the maintainer.
- The form's source check reads the page as served, so a name on a page that is built in the browser is reported as not found. A short name that is also a common word (a settings key such as `enabled`) is found on almost any page. It fetches only HTTPS pages from public addresses, so a cited page that is only served over plain HTTP counts as not fetched.
- What "public address" cannot catch: this Mac's or the router's own public address, and a host inside a company network that uses public addresses and a certificate from a company-installed authority. For the first, the certificate check still has to pass before a request is sent.
- What the checks of an AI lookup read on the Mac is shown in the form and left out of the issue. Checks typed by hand and checks of a curated finding are reported as matches or does not match.
- A version written as a date with dashes (`2026-11-24`) is read both as a date and, the npm way, as a pre-release of `2026`, so against files it may show the strictest of two findings.
- A yellow item whose switch cannot be read (a setting inside an app, or a tool's own `telemetry disable` command) stays yellow. There is no "mark as done".
- Opt-in tools without a readable state (Angular, Aider, Google Cloud CLI) are green with a note that the choice cannot be read.
- No notification when a verdict changes without a version change, and none for a reinstall at the same version.
- Commands that add a line to `~/.zshrc` assume zsh, the macOS default.
- A block comment (`/* … */`) around a setting is not recognised as a comment; `#`, `//` and `;` lines are.
- GitHub CLI: unusual spellings of an "off" value (`GH_TELEMETRY=FALSE`) show yellow, not green. That is the safe direction. The rule reads `~/.config/gh/config.yml` only, so with a custom `GH_CONFIG_DIR` or `XDG_CONFIG_HOME` a leftover file there can wrongly show green.
- Variables are read from the login shell at launch and on Rescan, so a change to a shell profile shows up after Rescan.
- The findings format is version 1. No build was released before the move from one rules file to the findings folder, so no older app can misread it. Raise `version` in the index and `supportedVersion` together for the next format change.
- A word after the version numbers is read as a pre-release, so a version such as OpenSSL's `1.1.1w` sorts before `1.1.1`. No app with such versions has more than one file yet.
- Pre-releases on different channels of one release are never ordered, also where a convention exists (beta before rc). Such an item gets the strictest of the findings that might hold, which can be yellow where green would be right, or red where yellow would be. The same holds for an item without a readable version, such as Homebrew itself or a cask at `latest`: version files cannot tell its builds apart.
- The highest findings serial the app accepted is kept in `state.json`. Deleting the whole Kanarie support folder, or a `state.json` that can no longer be read, resets it to the serial of the findings the app then loads, cached or shipped.
- A product name with a digit in front of the version (`python3-1.2`) is read as part of the version. No scanned item reports its version that way.
- An extension with a different version in each editor is judged by the first editor's version.
- If the findings change on the server between the download of the index and of a file, that download is rejected and tried again the next day.
- Stopping a batch of AI lookups lets the running lookup finish. A lookup that times out stops the CLI but not programs the CLI started.
- Verdicts are computed on the main thread, which is fine for a few hundred items.
- The model object that ties scanning, saving and notifications together has no unit tests; it was checked by running the app.
- Not scanned: apps outside the two Applications folders, iPhone and iPad apps, other Homebrew prefixes, and editors other than the six listed in the README.
