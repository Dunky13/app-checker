#!/usr/bin/env python3
"""Turns finding issues sent from the app into one pull request.

    scripts/accept-finding.py <issue number>...

Writes each finding below findings/, runs the tests and shows the change. After your yes it signs the index
and opens a pull request that closes the issues when it is merged. For one issue whose draft pull request the
workflow opened already, it writes that branch again from main, signed, and marks the pull request ready. Review the change it shows, not the issue:
an issue can hide text, and the script and the tests check the form of a finding, not whether it is true.
Needs gh, a clean checkout, a terminal and the signing key (see scripts/sign-findings.sh).
"""
import json
import os
import re
import subprocess
import sys
import termios
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# The order the findings in this repository are written in.
ORDER = ["match", "name", "telemetry", "summary", "policyURL", "optOut", "disabledWhen", "enabledWhen", "sources"]
OPT_OUT = ["instructions", "command", "url"]
CHECK = ["env", "defaults", "json", "file", "key", "equals", "contains", "notIn"]
# Not shown in a review, although they are neither control nor format characters.
IGNORABLE = {0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x2800, 0x3164, 0xFFA0, 0x16FE4, *range(0x180B, 0x1810),
             *range(0xFE00, 0xFE10), *range(0xFFF0, 0xFFF9), *range(0xE0000, 0xE1000)}
SIGNATURE_TEST = "indexIsSignedWithTheUpdateKeyAndListsEveryFile"
# An issue with several findings has a section per finding, headed like this. Submission.bulkLimit in the app.
HEADING = re.compile(r"^### Finding (\d+)$", re.M)
BULK_LIMIT = 10


def findings():
    return {f"{file.parent.name}/{file.name}": json.loads(file.read_text(encoding="utf-8")) for file in (ROOT / "findings").glob("*/*.json")}


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


def text(value, what, limit):
    # A field far longer than any here pushes what follows it off the screen of whoever reads the change.
    if not isinstance(value, str):
        raise ValueError(f"{what} is missing or not text")
    if len(value) > limit:
        raise ValueError(f"{what} is longer than {limit} characters")


def plain(value, what, breaks=False):
    """Names, links, commands and checks are compared or run, so they are ASCII: no look-alike letter stands in for another."""
    text(value, what, 300)
    if not all(" " <= character <= "~" or (breaks and character == "\n") for character in value):
        raise ValueError(f"{what} is not plain ASCII text")


def prose(value, what, limit=1000):
    """Text for reading can be in any script, but holds nothing a review would not see."""
    text(value, what, limit)
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
        prose(rule["name"], "the name", 100)
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
                for entry in listed(value, "notIn") if field == "notIn" else [value]:
                    if entry is not None:
                        plain(entry, f"{field} in {key}", breaks=field == "contains")
    for source in listed(rule.get("sources"), "sources"):
        plain(source, "a source")


def target(body, findings):
    """Where a submitted finding goes and what is written there: (path below findings/, text).
    An issue is text from anyone, so only its JSON block and a file name of the known form are used."""
    body = body.replace("\r\n", "\n")
    # Exactly one of each: a second one would be left out without a word, and its issue closed.
    blocks = re.findall(r"^````json$", body, re.M)
    if len(blocks) > 1 or len(re.findall(r"^\*\*Proposed as:\*\*", body, re.M)) > 1:
        raise ValueError("there is more than one finding where one is expected, perhaps under a heading that is not exactly \"### Finding <n>\"")
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


def targets(body, findings):
    """Every finding of an issue, in its order: [(path below findings/, text)]. Without headings the issue holds one."""
    body = body.replace("\r\n", "\n")
    parts = HEADING.split(body)
    if len(parts) == 1:
        return [target(body, findings)]
    # What stands before the first heading is the app's introduction. A finding there would be lost, so it is refused.
    if re.search(r"^````json$|^\*\*Proposed as:\*\*", parts[0], re.M):
        raise ValueError("there is a finding before the first heading")
    numbers, sections = parts[1::2], parts[2::2]
    if len(sections) > BULK_LIMIT:
        raise ValueError(f"the issue holds more than {BULK_LIMIT} findings")
    if numbers != [str(number) for number in range(1, len(numbers) + 1)]:
        raise ValueError("the findings are not numbered 1, 2, 3 and so on")
    placed = []
    for number, section in zip(numbers, sections):
        try:
            path, text = target(section, findings)
        except ValueError as error:
            raise ValueError(f"finding {number}: {error}") from None
        if any(path == earlier for earlier, _ in placed):
            raise ValueError(f"finding {number} goes to findings/{path} as an earlier one does")
        placed.append((path, text))
    return placed


def write(number, login, placed):
    """Writes the findings of one issue to their files: [(the pull request's line for it, its folder)]."""
    described = []
    for path, finding in placed:
        file = ROOT / "findings" / path
        # The login is in a code span, so the pull request does not notify the submitter.
        described.append((f"- Closes #{number}: {'corrects' if file.exists() else 'adds'} `findings/{path}`, sent in by `{login}`.", file.parent.name))
        file.parent.mkdir(exist_ok=True)
        file.write_text(finding, encoding="utf-8")
    return described


def titled(folders):
    """A title GitHub takes, which is also the commit's subject: the folders that fit, and how many more."""
    fit = max([count for count in range(1, len(folders) + 1) if len(", ".join(folders[:count])) <= 100] or [1])
    return "Findings: " + ", ".join(folders[:fit]) + (f" and {len(folders) - fit} more" if fit < len(folders) else "")


def run(*command, **options):
    return subprocess.run(command, cwd=ROOT, check=True, text=True, **options)


def signed():
    """Has the test of the signature confirm the index in the checkout. A test that is skipped or not found also ends well, so its output is read."""
    environment = {key: value for key, value in os.environ.items() if key != "GITHUB_EVENT_NAME"}
    # One stream, in the order it was written, so the tail below is the end of what happened.
    done = subprocess.run(["swift", "test", "--filter", SIGNATURE_TEST], cwd=ROOT, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, env=environment)
    passed = f"Test {SIGNATURE_TEST}() passed" in done.stdout
    if not passed:
        # Why: a signature that does not hold reads differently from tests that do not build.
        print(done.stdout[-2000:], file=sys.stderr)
    return passed


def shown():
    """Whether findings/ holds exactly what is staged: nothing edited since the diff, and no file that git leaves out but the index would list."""
    return (subprocess.run(["git", "diff", "--quiet", "--", "findings"], cwd=ROOT).returncode == 0
            and not run("git", "ls-files", "--others", "--", "findings", capture_output=True).stdout)


def accept(issues):
    # Untracked files too, whatever the configuration says: the clean-up below would delete them.
    if run("git", "status", "--porcelain", "--untracked-files=all", capture_output=True).stdout:
        sys.exit("Commit or stash your changes first.")
    if not sys.stdin.isatty():
        sys.exit("Run this in a terminal: the index is signed only after you have seen the change and said yes.")
    issues = [str(int(number)) for number in issues]
    branch = "findings-" + "-".join(issues)
    run("git", "fetch", "-q", "origin", "main")
    remote = run("git", "ls-remote", "--heads", "origin", branch, capture_output=True).stdout.split()
    # The workflow's draft for this one issue: written again here from main, so the yes is about what is shown.
    draft = remote and len(issues) == 1 and json.loads(
        run("gh", "pr", "list", "--head", branch, "--state", "open", "--json", "number", capture_output=True).stdout)
    if run("git", "for-each-ref", f"refs/heads/{branch}", capture_output=True).stdout or (remote and not draft):
        sys.exit(f"The branch {branch} is there already, from an earlier run. Finish its pull request, or delete the branch "
                 "here and on GitHub and run this again.")
    run("git", "switch", "-q", "--no-track", "-c", branch, "origin/main")
    try:
        # The signature covers every finding in the checkout, the diff below only what the issues change.
        # So what is on main must be signed already: then the yes is about the diff and nothing else.
        if not signed():
            sys.exit("The signature test did not pass on main, see above. If the tests do not build, fix that. If the index "
                     "does not cover the findings on main: run scripts/sign-findings.sh there, after reading what changed "
                     "since the last signature, and get that merged first.")
        lines, folders, written = [], [], set()
        for number in issues:
            issue = json.loads(run("gh", "issue", "view", number, "--json", "body,author,state", capture_output=True).stdout)
            if issue["state"] != "OPEN":
                sys.exit(f"#{number} is not open.")
            try:
                placed = targets(issue["body"], findings())
            except ValueError as error:
                sys.exit(f"#{number}: {error}.")
            for path, _ in placed:
                if path in written:
                    sys.exit(f"#{number}: another issue of this run already wrote findings/{path}. Take them one at a time.")
                written.add(path)
            for line, folder in write(number, issue["author"]["login"], placed):
                lines.append(line)
                folders.append(folder)
        title = titled(folders)
        # First the tests, with their own switch for an index that is not signed yet: what they reject is never signed.
        run("swift", "test", "--parallel", "--num-workers", "2", capture_output=True, env={**os.environ, "GITHUB_EVENT_NAME": "pull_request"})
        run("git", "add", "findings")
        # As git itself shows it: a diff tool or filter from the configuration could show something else.
        run("git", "--no-pager", "diff", "--cached", "--no-ext-diff", "--no-textconv", "--", "findings")
        # The signature tells every installed app that the maintainer has accepted this change.
        # A "y" typed while the tests ran was not an answer to this question.
        termios.tcflush(sys.stdin, termios.TCIFLUSH)
        try:
            answer = input(f"Sign the index with this change and {'mark the pull request ready' if draft else 'open the pull request'}? [y/N] ")
        except EOFError:
            answer = ""
        if answer.strip().lower() != "y":
            sys.exit("Nothing was signed.")
        if not shown():
            sys.exit("findings/ changed after the change was shown, or holds a file that git ignores. Nothing was signed.")
        run("scripts/sign-findings.sh")
        if not signed():
            sys.exit("The test of the new signature did not pass. Nothing was committed.")
        run("git", "add", "findings")
        run("git", "commit", "-q", "-s", "-m", title + "\n\n" + "\n".join(lines))
        if not shown():
            sys.exit("What was signed is not what was committed. The commit is dropped.")
    except BaseException:
        # Nothing has left this Mac: put findings/ back and drop the branch. The checkout was clean, so only this
        # script's files go; what was edited elsewhere in the meantime stays.
        run("git", "restore", "-q", "--staged", "--worktree", "--source=HEAD", "--", "findings")
        run("git", "clean", "-fdq", "findings")
        # checkout, not switch: the run may have started from a commit without a branch.
        run("git", "checkout", "-q", "-")
        run("git", "branch", "-q", "-D", branch)
        raise
    try:
        # Over the workflow's draft only as it was when this run looked: an edited issue may have changed it since.
        run("git", "push", "-q", *([f"--force-with-lease={branch}:{remote[0]}"] if draft else []), "-u", "origin", branch)
    except subprocess.CalledProcessError:
        print(f"The signed commit is on the branch {branch}, on this Mac only. Push it and open the pull request by hand, "
              "or delete the branch before you run this again.", file=sys.stderr)
        raise
    finally:
        run("git", "checkout", "-q", "-")
    try:
        body = "\n".join(lines) + "\n\nThe findings passed the tests, and the maintainer read this change before signing the index."
        if draft:
            number = str(draft[0]["number"])
            run("gh", "pr", "edit", number, "--title", title, "--body-file", "-", input=body)
            run("gh", "pr", "ready", number)
        else:
            run("gh", "pr", "create", "--base", "main", "--head", branch, "--title", title, "--body", body)
    except subprocess.CalledProcessError:
        print(f"The branch {branch} is pushed, with the signed index. {'Mark its pull request ready' if draft else 'Open its pull request'} by hand.", file=sys.stderr)
        raise


def drafted(event):
    """For the workflow, on a finding issue: its findings on the branch findings-<number>, in a draft pull request
    that closes it. Nothing is signed. When an edit changes the findings, the branch is written again from main,
    which also drops a signature made for the earlier text."""
    issue = json.loads(Path(event).read_text(encoding="utf-8"))["issue"]
    number = str(int(issue["number"]))
    branch = f"findings-{number}"
    if issue["state"] != "open":
        return
    pull = json.loads(run("gh", "pr", "list", "--head", branch, "--state", "open", "--json", "number,isDraft", capture_output=True).stdout)

    def unready():
        if pull and not pull[0]["isDraft"]:
            run("gh", "pr", "ready", str(pull[0]["number"]), "--undo")

    try:
        placed = targets(issue["body"] or "", findings())
    except ValueError as error:
        # In a code block, so nothing from the issue shows as a link or notifies anyone.
        run("gh", "issue", "comment", number, "--body-file", "-",
            input=f"This issue could not be turned into a pull request:\n\n    {error}.\n\nEdit the issue to try again.")
        # A pull request signed for the earlier text no longer matches the issue.
        unready()
        return
    run("git", "fetch", "-q", "origin", "main")
    if pull and run("git", "ls-remote", "--heads", "origin", branch, capture_output=True).stdout:
        # What the branch changes below findings/, the index aside. The same findings need no new commit.
        ref = f"refs/remotes/origin/{branch}"
        run("git", "fetch", "-q", "origin", f"+refs/heads/{branch}:{ref}")
        base = run("git", "merge-base", "origin/main", ref, capture_output=True).stdout.strip()
        changed = [line.split("\t") for line in run("git", "diff", "--name-status", "--no-renames", base, ref, "--", "findings",
                                                    ":!findings/index.json", ":!findings/index.json.sig", capture_output=True).stdout.splitlines()]
        if all(status in "AM" for status, _ in changed) and dict(placed) == {
                name.removeprefix("findings/"): run("git", "show", f"{ref}:{name}", capture_output=True).stdout for _, name in changed}:
            return
    run("git", "switch", "-q", "--no-track", "-C", branch, "origin/main")
    described = write(number, issue["user"]["login"], placed)
    title = titled([folder for _, folder in described])
    run("git", "add", "findings")
    run("git", "commit", "-q", "-s", "-m", title + "\n\n" + "\n".join(line for line, _ in described))
    run("git", "push", "-q", "--force", "origin", branch)
    body = ("\n".join(line for line, _ in described) + "\n\nWritten from the issue by a workflow. The findings passed the parser's checks; "
            "the tests and the review are still to come. The index is not signed, so the app would not take this change: "
            f"do not merge it as it is. To accept it, run `scripts/accept-finding.py {number}`. It writes the branch again from main, "
            "shows the change, signs the index after your yes and marks this pull request ready. If the issue is edited "
            "after that, this branch is written again unsigned and the pull request goes back to draft.")
    if not pull:
        run("gh", "pr", "create", "--draft", "--base", "main", "--head", branch, "--title", title, "--body-file", "-", input=body)
        return
    run("gh", "pr", "edit", str(pull[0]["number"]), "--title", title, "--body-file", "-", input=body)
    unready()


if __name__ == "__main__":
    arguments = sys.argv[1:]
    try:
        if len(arguments) == 2 and arguments[0] == "--parse":
            # For the tests: the issue body in a file, each target file and its text out, or why it is refused.
            # Read as bytes, so the line ends arrive as GitHub sends them.
            try:
                placed = targets(Path(arguments[1]).read_bytes().decode(), findings())
                print("".join(f"{path}\n{text}" for path, text in placed), end="")
            except ValueError as error:
                print(f"Refused: {error}.")
                sys.exit(1)
        elif len(arguments) == 2 and arguments[0] == "--draft":
            drafted(arguments[1])
        elif arguments and all(argument.isascii() and argument.isdigit() for argument in arguments):
            accept(arguments)
        else:
            sys.exit(__doc__)
    except ValueError as error:
        sys.exit(f"{error}.")
    except subprocess.CalledProcessError as error:
        # What a captured command printed says why, as with a finding the tests reject.
        sys.exit(f"{(error.stdout or '')[-3000:]}{error.stderr or ''}\nStopped: {' '.join(error.cmd[:3])} failed.")
