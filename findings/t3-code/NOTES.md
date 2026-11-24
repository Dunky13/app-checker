# T3 Code

Why there are two files:

- Up to and including 0.1.10 the desktop app decided about relay tracing before it had read the login shell environment. `T3CODE_TELEMETRY_ENABLED=false` in `~/.zshrc` stopped product usage events but not relay traces ([issue 37772](https://github.com/pingdotgg/t3code/issues/37772)). `0.json` therefore has no check that could turn the item green.
- [Pull request 37792](https://github.com/pingdotgg/t3code/pull/37792) fixed it on 2026-11-16. The tag `v0.1.10` does not contain that commit. The first build that does is the nightly `v0.1.11-nightly.20261117.4814`, and `v0.1.11` is the first stable release with it. Checked with GitHub's compare API on 2026-11-24.

The command-line tool and server (`npm:t3`) read the variable from their own environment and were not affected; they have their own folder, `t3-code-cli`.
