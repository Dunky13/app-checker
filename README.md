<img src="Resources/logo.png" width="128" alt="Kanarie logo: a yellow canary on a perch, carrying a blue medieval shield">

# Kanarie

Kanarie is Dutch for canary, as in the canary in a coal mine: it lets you know which apps have set up telemetry on your system.

It is a macOS menu bar app that lists the software on your Mac and tells you whether it sends telemetry, whether you have switched that off, and how to switch it off.

Homepage: https://dunky13.github.io/kanarie/

Many tools collect usage data unless you opt out, and the opt-out is often an environment variable that is only mentioned in an issue tracker. Kanarie keeps those switches in one folder of findings, one per app, and checks them against your Mac.

## Meet Arie

Arie is Kanarie's canary, and he does not sing. Not for seed, not for company, not for anyone. Only when something starts droning in the background does he get so cross that he sings right back at it.

Miners once took canaries underground to warn them of bad air. Arie keeps watch over your Mac instead, from his perch in the menu bar. While he has nothing to complain about, he keeps his beak shut and dozes.

But Arie cannot stand a hum in the background. When something new or updated on your Mac may send telemetry, quietly droning data off your Mac, he lets you know: he sings at it, or at least ruffles his feathers. That is the notification you get.

- **Green:** Arie dozes. There is nothing to hear, or you switched it off.
- **Yellow:** Arie ruffles his feathers. Something hums, but there is a switch, and he shows you where it is.
- **Red:** Arie sings at it, loudly. It hums, and there is no known way to switch it off.
- **Grey:** Arie cocks his head. He cannot tell.

## Screenshots

![The Kanarie window: a list of items that send telemetry, with Homebrew selected and the steps to switch its analytics off](docs/screenshots/list.png)

Every item shows what it collects, whether that is switched off on this Mac, and how to switch it off, with sources.

![The form to suggest a correction, filled in with the Homebrew finding](docs/screenshots/submit.png)

A finding can be proposed or corrected from the app. Kanarie checks it and then opens a prefilled GitHub issue in your browser.

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
| Yellow warning | Telemetry is on, or on by default where the setting cannot be read, and there is a way to switch it off. The item shows how, with a link, and a button for the command: **Run** it, **Add** the variable it sets to your shell profile, or **Copy** it. |
| Red cross | Telemetry is on and no opt-out is known |
| Grey question mark | Unknown |
| Grey crossed-out circle | No longer installed. Listed last, so a finding can still be submitted for it; its verdict is in the detail pane. |

A verdict comes from, in this order:

1. **The findings** ([findings/](findings)), curated by hand with sources, per app and per version.
2. **An AI lookup**, only when you ask for one. The result is marked as unverified and lists its sources.
3. **An offline hint.** For other apps, Homebrew items and commands, the app searches the program file for the names of well-known analytics services. A match stays grey: it is a lead worth looking up, not proof. npm packages and extensions are not searched.

Kanarie changes nothing on its own. When the switch is a command, you can have it run once (**Run**), or, when the command only sets a variable, have the variable added to the profile your login shell reads (**Add to ~/.zshrc**: `.zshrc` for zsh, also below `ZDOTDIR`; for bash the first of `~/.bash_profile`, `~/.bash_login` and `~/.profile` that exists; `~/.profile` for sh; `config.fish` for fish, also below `XDG_CONFIG_HOME`; each in its own syntax). Both ask first and show the exact command or lines. **Copy** is offered instead for another shell, a command that is not plain short ASCII, and a variable that cannot be added safely: quoting, other redirections or files, a value other than a switch (`0`, `1`, `true`, `false`, `yes`, `no`, `on`, `off`, `disabled`), or a variable that changes what runs, where traffic goes or what is trusted (`PATH`, `DYLD_*`, `*_PROXY`, `*TLS*`, `*VERIFY*` and the like). A yellow item stays yellow until the app can see the switch: variables are read from your login shell, so a variable must be in your shell profile, and some switches (a setting inside an app, or a tool's own `telemetry disable` command) cannot be read at all. The item says which case applies.

## Install

With [Homebrew](https://brew.sh):

```sh
brew tap dunky13/kanarie https://github.com/Dunky13/kanarie
brew install --cask dunky13/kanarie/kanarie
```

Or download the latest `Kanarie-<version>-universal.dmg` from [Releases](https://github.com/Dunky13/kanarie/releases), open it and drag Kanarie onto Applications.

Either way it needs macOS 15 or later and updates itself through [Sparkle](https://sparkle-project.org). The cask lives in this repository ([Casks/kanarie.rb](Casks/kanarie.rb)), which is why the tap needs the address. Use the full name as shown for the first install: Homebrew refuses a short name from a tap it has not been told to trust.

If you installed it with Homebrew, remove it again, with its settings and the API key of the AI lookup, in one go:

```sh
brew uninstall --cask --zap dunky13/kanarie/kanarie && brew untap dunky13/kanarie
```

Kanarie lives in the menu bar: look for the bird. While its list window is open it is also in the Dock and the app switcher (Command-Tab). If you use a menu bar manager, or your Mac has a notch and a full menu bar, the icon may be hidden: opening the app again from Finder shows the list.

## AI lookup

Lookups run only when you ask for them:

- **Look Up with AI** on one item.
- Select several items in the list (Shift or Command click, or Command-A) and look them up together. Items the Kanarie findings already cover are left out.
- The sparkles button in the toolbar, for every item in the current list that has no verdict yet.

Several items go out in groups of five per request, which costs less than one request for each. Stopping a batch ends the request that is running, and its items get no answer. The price of a group is that the model reads the names and the pages for all five in one conversation: a page or an item name written to mislead it could colour the answers for the other items of that group, where a lookup of one item can only spoil its own. In a group, an answer is filed under an item only when it carries both that item's number in the list and its identifier, kind included. A lookup of one item takes the one answer it gets, unless that answer names another item. Choose the backend in Settings:

- **Claude Code CLI** (default): runs your local `claude` command with web search, using your own Claude login.
- **OpenAI-compatible API**: any chat completions endpoint, for example [OpenRouter](https://openrouter.ai). The API key is stored in your keychain. On OpenRouter the web search plugin is switched on; other endpoints answer from what the model already knows.

A lookup sends the item's name, identifier and version to that backend. Answers can be wrong, so check the listed sources before relying on one. Items judged by a lookup carry a sparkles mark in the list.

The search field looks in names and identifiers. The filter menu next to it narrows the list by status (red, yellow, green, grey), by where the verdict comes from (Kanarie findings, AI lookup, analytics code found, nothing known, or everything that is not from an AI lookup) and by kind. Filters and search work together, and both bulk lookups follow them.

**Show Lookup Log…** on an item shows what the lookup behind its verdict asked and what came back, as a small chat log: the prompt, the model's messages and, folded away between them, its web searches and page fetches with their results. JSON is set as a code block and spread over lines, with nothing else about it changed. A later lookup that failed follows under its own heading, with the reason. The logs, failure reasons included, are kept on your Mac only (an API endpoint's own words are left out when it refuses the key, because such a message tends to quote part of it), in `~/Library/Application Support/Kanarie/lookups`. A long tool result is shortened. With the API backend a log holds the prompt and the answer or the error: Kanarie does not read the searches an endpoint may report.

The Claude Code CLI is started without your Claude settings, and with its own metrics and error reports switched off (`DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`).

## Privacy

Kanarie has no telemetry. It talks to the network in four cases:

- At launch and then once a day it downloads the findings from this repository (can be switched off in Settings). It fetches every file that changed, not only those for apps you have, so the requests say nothing about your Mac. Files are only used if they match the list the maintainer signed.
- Sparkle checks this repository for updates, after asking you once. The anonymous system profile is disabled.
- AI lookups, when you ask for them.
- Submitting a finding, when you choose to: the app fetches the pages the finding cites, then opens GitHub in your browser.

At launch and when you choose Rescan, the app starts your login shell once to read its variables, which runs your shell startup files, and asks `npm` and `pnpm` for their global folder with their update check switched off. Other rescans reuse that answer, so a change to your shell profile shows up after Rescan.

## macOS "Data Access Blocked"

Some apps keep their settings in a protected folder, for example Docker Desktop. macOS can then stop Kanarie from reading the setting and show a "Data Access Blocked" notice. The item says so instead of guessing. To allow the read, open System Settings > Privacy & Security > Files & Folders, then choose Rescan. Kanarie does not retry a blocked file until you rescan.

## Findings

Every app has its own folder below [findings/](findings), with one file per version from which a finding holds:

```
findings/t3-code/0.json                              from the first version
findings/t3-code/0.1.11-nightly.20261117.4814.json   from that build onward
findings/t3-code/NOTES.md                            optional: why the files differ
```

A file is named after the first version it applies to and stays valid until a file with a higher version exists, so a range of versions needs one file and no end. Add a file only when something changed: the opt-out, the default, or what is collected. Each file is complete on its own; nothing is inherited from the file before it. An item belongs to one folder, and every folder starts with `0.json`, so no installed version is left without a finding.

Versions are compared the way people read them: `1.10` is after `1.9`, a leading `v` is ignored, `3.0.0_1` is after `3.0.0`, and a pre-release such as `0.1.11-nightly.20261117.4814`, `2.0-beta.3` or `1.0-rc.1` is before its release and after the release before it. Sometimes the installed version does not say which file applies: it cannot be read at all, it is a pre-release on another channel than a file's (`0.1.11-rc.1` against `0.1.11-nightly.20261117.4814`: nothing says which was built first), it, or a file's version, ends in a dash and a number (`1.2.0-1` is a pre-release of `1.2.0` for npm and a later build elsewhere), or its numbers are followed by a word that is not a usual pre-release name such as `beta`, `rc` or `nightly` (`9.9p2` is a patch level of `9.9`, and `5.4.0-0ubuntu1` a packager's build of `5.4.0`). For a dash number the app reads the versions both ways, and for such a word it also counts the file for exactly that release. When the answers differ, or in the first two cases, it judges every finding that might hold and shows the strictest result, with a note.

Each file is one finding. It matches one or more item IDs:

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

- `{ "env": "NAME", "equals": "0" }`: a variable in your login shell. Without `equals`, any non-empty value matches. `{ "env": "NAME", "notIn": ["0", "false"] }` matches when the variable is set to anything else, ignoring case and surrounding spaces.
- `{ "defaults": "bundle.id", "key": "name", "equals": "0" }`: a macOS preference. Booleans read as `1` and `0`.
- `{ "json": "~/path/settings.json", "key": "a.b", "equals": "false" }`: a value in a JSON or JSONC file. Booleans read as `true` and `false`.
- `{ "file": "~/path/config", "contains": "text" }`: text in a file. Lines commented out with `#`, `//` or `;` are ignored.

File paths must start with `~/` or a Homebrew prefix. Checks cannot run commands, by design: a finding's `command` only runs when you choose **Run** and confirm it. In an extension rule, a path below `~/Library/Application Support/Code/` is read from each editor that has the extension.

A `command` is one line, and it should make the change permanent: `echo 'export NAME=1' >> ~/.zshrc`, not `export NAME=1`.

Found a wrong or missing finding? Use **Submit a Finding…** (or **Suggest a Correction…**) on the item in the app (removed items stay in the list for this), or select several items (or all of them) and use **Submit Findings…** to send the AI lookups not sent before in one issue, or open a pull request with a source. `swift test` validates every file.

### Submitting from the app

The form starts from the item's AI lookup or current finding, or empty, and can be edited by hand. It only lets you continue with a finding that passes the checks every curated finding passes. Then the app:

1. reads the finding's checks on your Mac and notes whether each one matches, never the value it read. For an extension the note names each editor that has it, so the issue shows which of those editors you use. For checks that came from an AI lookup this is shown in the form only and left out of the issue, because whatever the lookup read chose those checks,
2. fetches the pages you cite and looks for the variable and setting names on them, word for word. A name that no cited page mentions is shown before you continue, because an invented name is the main risk of an AI lookup. A name counts only as a whole, not as part of a longer one. Only links over HTTPS on its standard port, to a name that resolves to public addresses, are fetched: a link to this Mac or to a private or local network address, or one that redirects there, is skipped. A name server that changes its answer between the check and the fetch can still make the app open a connection to a private address, but no request is sent over it, because nothing there holds a certificate for that name,
3. opens a prefilled issue in this repository in your browser. Nothing is sent until you submit it there with your own GitHub account, and the issue is public.

A submission is a proposal. It reaches other users only after the maintainer has reviewed it, added it below `findings/` and signed the index. A workflow turns each such issue into a draft pull request that closes it, with the index unsigned, because the signing key stays off GitHub. For the maintainer, accepting is one command, `scripts/accept-finding.py <issue number>...`: it writes the findings from those issues to their files, runs the tests and shows the change. Only after a yes at the terminal does it sign the index and open a pull request that closes the issues when it is merged (for one issue it takes over the workflow's draft and marks it ready), because a signed index is what the app trusts, wherever it is found. It takes only the JSON block and a file name of the expected form from an issue. It refuses a finding that would silently replace another, a field that no finding has, text with invisible characters, and anything but plain ASCII in identifiers, links, commands and checks. Whether the vendor really stops collecting when the switch is set cannot be checked automatically; that is what the sources and the review are for.

The app only accepts downloaded findings that match `findings/index.json`, the list of every file with its SHA-256, and only when that list is signed with the same key as app updates. The maintainer runs `scripts/sign-findings.sh` after a change, which writes the index and `index.json.sig` (`scripts/accept-finding.py` does it for submitted findings). Until then the app keeps the findings it already has. Every signing gives the index a higher serial number, and the app never goes back to a lower one.

## Build

Requires Xcode 16 or later.

```sh
swift test
scripts/build-app.sh            # ad-hoc signed app in build/
open "build/Kanarie.app"
```

Print the verdicts without the interface:

```sh
"build/Kanarie.app/Contents/MacOS/Kanarie" --list
```

## Release

`scripts/release.sh <version>` tests, builds, signs with a Developer ID, notarizes, staples, creates the GitHub release and updates `appcast.xml` and the Homebrew cask. It needs:

- a Developer ID Application certificate in the keychain,
- notarization credentials: `NOTARY_KEYCHAIN_PROFILE`, or `NOTARY_KEY_FILE` with `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`,
- the Sparkle EdDSA private key in the login keychain (or `SPARKLE_KEY_FILE`). Keep a backup: without it no update and no findings can be signed,
- the `gh` CLI, signed in.

## License

[MIT](LICENSE)
