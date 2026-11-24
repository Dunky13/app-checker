#!/usr/bin/env python3
"""Turns finding issues sent from the app into one pull request.

    scripts/accept-finding.py <issue number>...

Writes each finding below findings/, signs the index, runs the tests and opens a pull request that closes
the issues when it is merged. Read the issue first: the script and the tests check the form of a finding,
not whether it is true. Needs gh, a clean checkout and the signing key (see scripts/sign-findings.sh).
"""
import json
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# The order the findings in this repository are written in.
ORDER = ["match", "name", "telemetry", "summary", "policyURL", "optOut", "disabledWhen", "enabledWhen", "sources"]
OPT_OUT = ["instructions", "command", "url"]


def findings():
    return {f"{file.parent.name}/{file.name}": json.loads(file.read_text()) for file in (ROOT / "findings").glob("*/*.json")}


def target(body, findings):
    """Where a submitted finding goes and what is written there: (path below findings/, text).
    An issue is text from anyone, so only its JSON block and a file name of the known form are used."""
    body = body.replace("\r\n", "\n")
    block = re.search(r"^````json\n(.*?)\n````$", body, re.S | re.M)
    if not block:
        raise ValueError("there is no finding in the issue")
    rule = json.loads(block.group(1))
    if not isinstance(rule, dict) or not isinstance(rule.get("match"), list):
        raise ValueError("the finding does not say which items it is for")

    new = re.search(r"^\*\*Proposed as:\*\* `findings/([a-z0-9-]+)/0\.json`$", body, re.M)
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
    text = json.dumps(rule, indent=2, ensure_ascii=False) + "\n"
    # Line breaks and tabs inside a value are written as escapes; anything else invisible would pass a review unseen.
    if any(unicodedata.category(character) in ("Cc", "Cf") for character in text.replace("\n", "")):
        raise ValueError("the finding holds invisible characters")
    return path, text


def run(*command, **options):
    return subprocess.run(command, cwd=ROOT, check=True, text=True, **options)


def accept(issues):
    if run("git", "status", "--porcelain", capture_output=True).stdout:
        sys.exit("Commit or stash your changes first.")
    branch = "findings-" + "-".join(issues)
    run("git", "fetch", "-q", "origin", "main")
    run("git", "switch", "-q", "--no-track", "-c", branch, "origin/main")
    try:
        lines, folders = [], []
        for number in issues:
            issue = json.loads(run("gh", "issue", "view", number, "--json", "body,author", capture_output=True).stdout)
            try:
                path, text = target(issue["body"], findings())
            except ValueError as error:
                sys.exit(f"#{number}: {error}.")
            file = ROOT / "findings" / path
            # The login is in a code span, so the pull request does not notify the submitter.
            lines.append(f"- Closes #{number}: {'corrects' if file.exists() else 'adds'} `findings/{path}`, sent in by `{issue['author']['login']}`.")
            folders.append(file.parent.name)
            file.parent.mkdir(exist_ok=True)
            file.write_text(text)
        title = "Findings: " + ", ".join(folders)
        run("scripts/sign-findings.sh")
        run("swift", "test", capture_output=True)
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
        body = "\n".join(lines) + "\n\nThe findings passed the tests and the index is signed. Whether they are true is for this review."
        run("gh", "pr", "create", "--base", "main", "--head", branch, "--title", title, "--body", body)
    finally:
        run("git", "checkout", "-q", "-")


if __name__ == "__main__":
    arguments = sys.argv[1:]
    try:
        if len(arguments) == 2 and arguments[0] == "--parse":
            # For the tests: the issue body in a file, the target file and its text out.
            print(*target(Path(arguments[1]).read_text(), findings()), sep="\n", end="")
        elif arguments and all(argument.isascii() and argument.isdigit() for argument in arguments):
            accept(arguments)
        else:
            sys.exit(__doc__)
    except ValueError as error:
        sys.exit(f"{error}.")
    except subprocess.CalledProcessError as error:
        # What a captured command printed says why, as with a finding the tests reject.
        sys.exit(f"{(error.stdout or '')[-3000:]}{error.stderr or ''}\nStopped: {' '.join(error.cmd)} failed.")
