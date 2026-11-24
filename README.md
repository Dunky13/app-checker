# App Checker

A macOS menu bar app that lists the software on your Mac and tells you whether it sends telemetry, whether you have switched that off, and how to switch it off.

Many tools collect usage data unless you opt out, and the opt-out is often an environment variable that is only mentioned in an issue tracker. App Checker keeps those switches in one rules file and checks them against your Mac.

## What it checks

- Apps in `/Applications` and `~/Applications`, including one folder below them
- Homebrew itself, formulae you installed on request (not their dependencies) and casks that install commands rather than an app
- Commands in `~/.local/bin`, where installers such as the one for Claude Code put standalone tools
- Global npm and pnpm packages
- Extensions of VS Code, VS Code Insiders, VSCodium, Cursor, Windsurf and Kiro. An extension is green only when every editor that has it is switched off.

It runs in the background, starts at login, watches those locations, and sends a notification when something new or updated may send telemetry.

Not covered: apps kept anywhere else, iPhone and iPad apps running on a Mac, and Homebrew outside `/opt/homebrew` and `/usr/local`. You are notified about installs and version changes, not when a rule or one of your settings changes a verdict later.

## What the colours mean

| Icon | Meaning |
| --- | --- |
| Green check | No telemetry, or telemetry is switched off on this Mac |
| Yellow warning | Telemetry is on, or on by default where the setting cannot be read, and there is a way to switch it off. The item shows how, with a link, and a copy button when the switch is a command. |
| Red cross | Telemetry is on and no opt-out is known |
| Grey question mark | Unknown |

A verdict comes from, in this order:

1. **The rules database** ([rules.json](rules.json)), curated by hand with sources.
2. **An AI lookup**, only when you ask for one. The result is marked as unverified and lists its sources.
3. **An offline hint.** For other apps, Homebrew items and commands, the app searches the program file for the names of well-known analytics services. A match stays grey: it is a lead worth looking up, not proof. npm packages and extensions are not searched.

App Checker never changes a setting for you. A yellow item stays yellow until the app can see the switch: variables are read from your login shell, so a variable must be in your shell profile, and some switches (a setting inside an app, or a tool's own `telemetry disable` command) cannot be read at all. The item says which case applies.

## Install

Download the latest `AppChecker-<version>-universal.zip` from [Releases](https://github.com/Dunky13/app-checker/releases), unzip it and move App Checker to Applications. It needs macOS 15 or later and updates itself through [Sparkle](https://sparkle-project.org).

The app has no Dock icon. Look for the shield in the menu bar. If you use a menu bar manager, or your Mac has a notch and a full menu bar, the icon may be hidden: opening the app again from Finder shows the list.

## AI lookup

Lookups run only when you click **Look Up with AI** on an item, or the sparkles button for every item in the current list that has no verdict yet. Choose the backend in Settings:

- **Claude Code CLI** (default): runs your local `claude` command with web search, using your own Claude login.
- **OpenAI-compatible API**: any chat completions endpoint, for example [OpenRouter](https://openrouter.ai). The API key is stored in your keychain. On OpenRouter the web search plugin is switched on; other endpoints answer from what the model already knows.

A lookup sends the item's name, identifier and version to that backend. Answers can be wrong, so check the listed sources before relying on one. Items judged by a lookup carry a sparkles mark in the list.

The Claude Code CLI is started without your Claude settings, and with its own metrics and error reports switched off (`DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`).

## Privacy

App Checker has no telemetry. It talks to the network in three cases:

- At launch and then once a day it downloads `rules.json` from this repository (can be switched off in Settings). The file is only used if it carries the maintainer's signature.
- Sparkle checks this repository for updates, after asking you once. The anonymous system profile is disabled.
- AI lookups, when you ask for them.

At launch and when you choose Rescan, the app starts your login shell once to read its variables, which runs your shell startup files, and asks `npm` and `pnpm` for their global folder with their update check switched off. Other rescans reuse that answer, so a change to your shell profile shows up after Rescan.

## macOS "Data Access Blocked"

Some apps keep their settings in a protected folder, for example Docker Desktop. macOS can then stop App Checker from reading the setting and show a "Data Access Blocked" notice. The item says so instead of guessing. To allow the read, open System Settings > Privacy & Security > Files & Folders, then choose Rescan. App Checker does not retry a blocked file until you rescan.

## Rules

Each rule in [rules.json](rules.json) matches one or more item IDs:

| Prefix | Example |
| --- | --- |
| `app:` bundle identifier | `app:com.microsoft.VSCode` |
| `brew:` formula | `brew:gh` (`brew:homebrew` is Homebrew itself, `brew:homebrew-usr-local` the install in `/usr/local`) |
| `cask:` command-line cask | `cask:codex` |
| `bin:` command in `~/.local/bin` | `bin:claude` |
| `npm:` package | `npm:next` |
| `ext:` extension, lower case | `ext:ms-python.python` |

```json
{
  "match": ["brew:example"],
  "name": "Example CLI",
  "telemetry": "opt-out",
  "summary": "Sends anonymous usage events unless disabled.",
  "policyURL": "https://example.com/privacy",
  "optOut": {
    "instructions": "Set the variable in your shell profile.",
    "command": "export EXAMPLE_TELEMETRY=0",
    "url": "https://example.com/docs/telemetry"
  },
  "disabledWhen": [{ "env": "EXAMPLE_TELEMETRY", "equals": "0" }],
  "sources": ["https://example.com/docs/telemetry"]
}
```

`telemetry` is `none`, `opt-in`, `opt-out` or `forced`. `disabledWhen` and `enabledWhen` are lists of checks; one matching check is enough. On an opt-out rule, `enabledWhen` lists switches that force telemetry on, and a match there wins over `disabledWhen`. A check reads one value:

- `{ "env": "NAME", "equals": "0" }`: a variable in your login shell. Without `equals`, any non-empty value matches.
- `{ "defaults": "bundle.id", "key": "name", "equals": "0" }`: a macOS preference. Booleans read as `1` and `0`.
- `{ "json": "~/path/settings.json", "key": "a.b", "equals": "false" }`: a value in a JSON or JSONC file. Booleans read as `true` and `false`.
- `{ "file": "~/path/config", "contains": "text" }`: text in a file. Lines commented out with `#`, `//` or `;` are ignored.

File paths must start with `~/` or a Homebrew prefix. Rules cannot run commands, by design. In an extension rule, a path below `~/Library/Application Support/Code/` is read from each editor that has the extension.

A `command` is one line, and it should make the change permanent: `echo 'export NAME=1' >> ~/.zshrc`, not `export NAME=1`.

Found a wrong or missing rule? [Open an issue](https://github.com/Dunky13/app-checker/issues/new) or a pull request with a source. `swift test` validates the file.

The app only accepts a downloaded `rules.json` that is signed with the same key as app updates. The maintainer signs after merging a rules change with `scripts/sign-rules.sh`, which writes `rules.json.sig`. Until then the app keeps the rules it already has.

## Build

Requires Xcode 16 or later.

```sh
swift test
scripts/build-app.sh            # ad-hoc signed app in build/
open "build/App Checker.app"
```

Print the verdicts without the interface:

```sh
"build/App Checker.app/Contents/MacOS/AppChecker" --list
```

## Release

`scripts/release.sh <version>` tests, builds, signs with a Developer ID, notarizes, staples, creates the GitHub release and updates `appcast.xml`. It needs:

- a Developer ID Application certificate in the keychain,
- notarization credentials: `NOTARY_KEYCHAIN_PROFILE`, or `NOTARY_KEY_FILE` with `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`,
- the Sparkle EdDSA private key in the login keychain (or `SPARKLE_KEY_FILE`). Keep a backup: without it no update or rules file can be signed,
- the `gh` CLI, signed in.

## License

[MIT](LICENSE)
