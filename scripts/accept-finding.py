#!/usr/bin/env python3
"""Turns finding issues sent from the app into one pull request.

    scripts/accept-finding.py <issue number>...

Writes each finding below findings/, runs the tests and shows the change. After your yes it signs the index
and opens a pull request that closes the issues when it is merged. Review the change it shows, not the issue:
an issue can hide text, and the script and the tests check the form of a finding, not whether it is true.
Needs gh, a clean checkout, a terminal and the signing key (see scripts/sign-findings.sh).
"""
import json
import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# The order the findings in this repository are written in.
ORDER = ["match", "name", "telemetry", "summary", "policyURL", "optOut", "disabledWhen", "enabledWhen", "sources"]
OPT_OUT = ["instructions", "command", "url"]
CHECK = ["env", "defaults", "json", "file", "key", "equals", "contains", "notIn"]
# Not shown in a review, although they are neither control nor format characters.
IGNORABLE = {0x034F, 0x115F, 0x1160, 0x3164, 0xFFA0, *range(0xFE00, 0xFE10), *range(0xE0100, 0xE01F0)}


def findings():
    return {f"{file.parent.name}/{file.name}": json.loads(file.read_text()) for file in (ROOT / "findings").glob("*/*.json")}


def known(values, keys, what):
    # The tests ignore a field they do not know. A later version of the app might read it.
    if not isinstance(values, dict):
        raise ValueError(f"{what} is not an object")
    for key in values:
        if key not in keys:
            raise ValueError(f"{what} has a field that is not part of a finding: {key!r:.40}")


def listed(value, what):
    if value is not None and not isinstance(value, list):
        raise ValueError(f"{what} is not a list")
    return value or []


def plain(value, what, breaks=False):
    """Names, links, commands and checks are compared or run, so they are ASCII: no look-alike letter stands in for another."""
    if not isinstance(value, str):
        raise ValueError(f"{what} is missing or not text")
    if not all(" " <= character <= "~" or (breaks and character == "\n") for character in value):
        raise ValueError(f"{what} is not plain ASCII text")


def prose(value, what):
    """Text for reading can be in any script, but holds nothing a review would not see."""
    if not isinstance(value, str):
        raise ValueError(f"{what} is missing or not text")
    if any(character != " " and (unicodedata.category(character)[0] in "CZ" or ord(character) in IGNORABLE) for character in value):
        raise ValueError(f"{what} holds invisible characters")


def checked(rule):
    """Refuses everything that is not a finding of the known shape."""
    known(rule, ORDER, "the finding")
    if not listed(rule.get("match"), "match"):
        raise ValueError("the finding does not say which items it is for")
    for item in rule["match"]:
        plain(item, "an item in match")
    plain(rule.get("telemetry"), "telemetry")
    prose(rule.get("summary"), "the summary")
    if rule.get("name") is not None:
        prose(rule["name"], "the name")
    if rule.get("policyURL") is not None:
        plain(rule["policyURL"], "the privacy link")
    if rule.get("optOut") is not None:
        known(rule["optOut"], OPT_OUT, "optOut")
        prose(rule["optOut"].get("instructions"), "the steps to switch it off")
        for key in ("command", "url"):
            if rule["optOut"].get(key) is not None:
                plain(rule["optOut"][key], f"optOut.{key}")
    for key in ("disabledWhen", "enabledWhen"):
        for check in listed(rule.get(key), key):
            known(check, CHECK, f"a check in {key}")
            for field, value in check.items():
                for text in listed(value, "notIn") if field == "notIn" else [value]:
                    if text is not None:
                        plain(text, f"{field} in {key}", breaks=field == "contains")
    for source in listed(rule.get("sources"), "sources"):
        plain(source, "a source")


def target(body, findings):
    """Where a submitted finding goes and what is written there: (path below findings/, text).
    An issue is text from anyone, so only its JSON block and a file name of the known form are used."""
    body = body.replace("\r\n", "\n")
    block = re.search(r"^````json\n(.*?)\n````$", body, re.S | re.M)
    if not block:
        raise ValueError("there is no finding in the issue")
    if len(block.group(1)) > 20000:
        raise ValueError("the finding is far longer than a finding is")
    try:
        rule = json.loads(block.group(1))
    except RecursionError:
        raise ValueError("the finding is nested too deeply") from None
    checked(rule)

    new = re.search(r"^\*\*Proposed as:\*\* `findings/([a-z0-9][a-z0-9-]*)/0\.json`$", body, re.M)
    fix = re.search(r"^\*\*Proposed as:\*\* a correction of .* that starts at version `([A-Za-z0-9_-][A-Za-z0-9._-]*)`$", body, re.M)
    if new:
        path = f"{new.group(1)}/0.json"
        if path in findings:
            raise ValueError(f"findings/{path} is there already, so this is a correction or needs a folder of its own")
    elif fix:
        # The file with that first version among the findings for the same items.
        same = [path for path, old in findings.items()
                if path.endswith(f"/{fix.group(1)}.json") and set(old.get("match", [])) & set(map(str, rule["match"]))]
        if len(same) != 1:
            raise ValueError(f"{len(same)} findings match this correction, so it has to be placed by hand")
        path = same[0]
    else:
        raise ValueError("the issue names no file, so this finding has to be placed by hand")

    def ordered(keys, values):
        return {key: values[key] for key in sorted(values, key=lambda key: keys.index(key) if key in keys else len(keys))}

    rule = ordered(ORDER, rule)
    if isinstance(rule.get("optOut"), dict):
        rule["optOut"] = ordered(OPT_OUT, rule["optOut"])
    return path, json.dumps(rule, indent=2, ensure_ascii=False) + "\n"


def run(*command, **options):
    return subprocess.run(command, cwd=ROOT, check=True, text=True, **options)


def accept(issues):
    # Untracked files too, whatever the configuration says: the clean-up below would delete them.
    if run("git", "status", "--porcelain", "--untracked-files=all", capture_output=True).stdout:
        sys.exit("Commit or stash your changes first.")
    if not sys.stdin.isatty():
        sys.exit("Run this in a terminal: the index is signed only after you have seen the change and said yes.")
    branch = "findings-" + "-".join(issues)
    run("git", "fetch", "-q", "origin", "main")
    if (run("git", "for-each-ref", f"refs/heads/{branch}", capture_output=True).stdout
            or run("git", "ls-remote", "--heads", "origin", branch, capture_output=True).stdout):
        sys.exit(f"The branch {branch} is there already, from an earlier run. Finish its pull request, or delete the branch "
                 "here and on GitHub and run this again.")
    run("git", "switch", "-q", "--no-track", "-c", branch, "origin/main")
    try:
        lines, folders, written = [], [], set()
        for number in issues:
            issue = json.loads(run("gh", "issue", "view", number, "--json", "body,author,state", capture_output=True).stdout)
            if issue["state"] != "OPEN":
                sys.exit(f"#{number} is not open.")
            try:
                path, text = target(issue["body"], findings())
            except ValueError as error:
                sys.exit(f"#{number}: {error}.")
            if path in written:
                sys.exit(f"#{number}: another issue of this run already wrote findings/{path}. Take them one at a time.")
            written.add(path)
            file = ROOT / "findings" / path
            # The login is in a code span, so the pull request does not notify the submitter.
            lines.append(f"- Closes #{number}: {'corrects' if file.exists() else 'adds'} `findings/{path}`, sent in by `{issue['author']['login']}`.")
            folders.append(file.parent.name)
            file.parent.mkdir(exist_ok=True)
            file.write_text(text)
        title = "Findings: " + ", ".join(folders)
        # First the tests, with their own switch for an index that is not signed yet: what they reject is never signed.
        run("swift", "test", "--parallel", "--num-workers", "2", capture_output=True, env={**os.environ, "GITHUB_EVENT_NAME": "pull_request"})
        run("git", "add", "findings")
        run("git", "--no-pager", "diff", "--cached", "--", "findings")
        # The signature tells every installed app that the maintainer has accepted this change.
        try:
            answer = input("Sign the index with this change and open the pull request? [y/N] ")
        except EOFError:
            answer = ""
        if answer.strip().lower() != "y":
            sys.exit("Nothing was signed.")
        run("scripts/sign-findings.sh")
        run("swift", "test", "--filter", "indexIsSignedWithTheUpdateKeyAndListsEveryFile", capture_output=True)
        run("git", "add", "findings")
        run("git", "commit", "-q", "-s", "-m", title + "\n\n" + "\n".join(lines))
    except BaseException:
        # Nothing is committed yet: leave the checkout as it was found. It was clean, so only this script's files go.
        run("git", "reset", "-q", "--hard")
        run("git", "clean", "-fdq", "findings")
        run("git", "checkout", "-q", "-")
        run("git", "branch", "-q", "-D", branch)
        raise
    try:
        run("git", "push", "-q", "-u", "origin", branch)
        body = "\n".join(lines) + "\n\nThe findings passed the tests, and the maintainer read this change before signing the index."
        run("gh", "pr", "create", "--base", "main", "--head", branch, "--title", title, "--body", body)
    except subprocess.CalledProcessError:
        print(f"The signed commit is on the branch {branch}. Push it and open the pull request by hand, or delete the "
              "branch here and on GitHub before you run this again.", file=sys.stderr)
        raise
    finally:
        run("git", "checkout", "-q", "-")


if __name__ == "__main__":
    arguments = sys.argv[1:]
    try:
        if len(arguments) == 2 and arguments[0] == "--parse":
            # For the tests: the issue body in a file, the target file and its text out, or why it is refused.
            # Read as bytes, so the line ends arrive as GitHub sends them.
            try:
                print(*target(Path(arguments[1]).read_bytes().decode(), findings()), sep="\n", end="")
            except ValueError as error:
                print(f"Refused: {error}.")
                sys.exit(1)
        elif arguments and all(argument.isascii() and argument.isdigit() for argument in arguments):
            accept(arguments)
        else:
            sys.exit(__doc__)
    except ValueError as error:
        sys.exit(f"{error}.")
    except subprocess.CalledProcessError as error:
        # What a captured command printed says why, as with a finding the tests reject.
        sys.exit(f"{(error.stdout or '')[-3000:]}{error.stderr or ''}\nStopped: {' '.join(error.cmd[:3])} failed.")
