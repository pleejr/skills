#!/usr/bin/env python3
"""Release gate for pr-merge.sh: refuse a merge while a release channel names the repo today.

Some repos must not take a merge while their release is about to run or is running. The
rule this enforces is deliberately simple, so no model has to judge it: if any top-level
post in the release channel since local midnight names the repo, the merge is held. It
never tries to work out whether that release has finished. The hold lasts until the next
business day, and the check runs again then.

A match can be cleared for one run by citing its permalink with --cleared, after a person
has read that release thread and confirmed it is finished. Every match must be cited.

Configuration (environment first, then ~/.claude/skill-config.env; values are read literally):
  PR_MERGE_RELEASE_GATE_REPOS  owner/name or bare repo names, comma or space separated
  PR_MERGE_RELEASE_CHANNEL     the release channel's ID (the bot must be a member)
A repo not listed is not gated. The code carries no repo or channel names.

Token: SLACK_BOT_TOKEN, then the macOS keychain item claude-slack-bot-token, then
~/.claude/.slack-bot-token. It needs channels:history (groups:history for a private channel).
The token is never printed.

Fails closed: a gated repo with no channel configured, no token, or a Slack API error
exits 2, and pr-merge.sh refuses the merge. A failed read is not treated as "no posts".

Exit: 0 clear or not gated · 1 held (matches not cleared) · 2 could not check.
Usage: pr-merge-release-gate.py --repo owner/name [--cleared PERMALINK]... [--since EPOCH]
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request

CONFIG = os.path.expanduser(os.environ.get("SKILL_CONFIG") or "~/.claude/skill-config.env")
KEYCHAIN_SERVICE = "claude-slack-bot-token"
LEGACY_TOKEN_FILE = os.path.expanduser("~/.claude/.slack-bot-token")
PERMALINK_TS = re.compile(r"/p(\d{10})(\d{6})")


def out(msg):
    print(f"release-gate: {msg}")


def cannot_check(msg):
    print(f"release-gate: cannot check — {msg}", file=sys.stderr)
    sys.exit(2)


def unquote(value):
    value = value.strip()
    # An unquoted trailing comment, as `source` would drop it: KEY="a b"  # note
    if value[:1] in "\"'":
        end = value.find(value[0], 1)
        if end > 0:
            value = value[: end + 1]
    else:
        value = re.split(r"\s+#", value, maxsplit=1)[0]
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1].strip()
    return value


def config(key):
    """Env var, else the LAST assignment in the config file (as sourcing would take it).

    Tolerates `export KEY=` and one layer of matching quotes, so a quoted value cannot
    turn "o/a o/b" into entries that silently match nothing.
    """
    if os.environ.get(key, "").strip():
        return unquote(os.environ[key])
    value = ""
    try:
        with open(CONFIG) as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("export "):
                    line = line[len("export "):].lstrip()
                if line.startswith(f"{key}="):
                    value = unquote(line.split("=", 1)[1])
    except FileNotFoundError:
        pass
    return value


def token():
    if os.environ.get("SLACK_BOT_TOKEN"):
        return os.environ["SLACK_BOT_TOKEN"]
    try:
        r = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    try:
        with open(LEGACY_TOKEN_FILE) as fh:
            return fh.read().strip()
    except FileNotFoundError:
        return ""


def slack(method, tok, **params):
    url = f"https://slack.com/api/{method}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = json.load(resp)
    except Exception as exc:  # network, HTTP, JSON: all mean the read did not happen
        cannot_check(f"{method} failed: {type(exc).__name__}: {exc}")
    if not body.get("ok"):
        cannot_check(f"{method} returned error: {body.get('error')}")
    return body


def message_text(msg):
    """The text-bearing strings anywhere in the message: text, blocks, attachments
    (titles, fields), files' titles and previews."""
    parts = []

    def walk(node):
        if isinstance(node, dict):
            for k, v in node.items():
                if isinstance(v, str):
                    if k in TEXT_KEYS:
                        parts.append(v)
                else:
                    walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(msg)
    return "\n".join(parts)


# Only keys that carry what a person or integration wrote. Reading the whole payload also
# matched file URLs, user profiles and reaction names, which would hold on metadata.
TEXT_KEYS = {"text", "fallback", "pretext", "title", "value", "footer", "preview", "alt_text"}


def gated(repo, listed):
    repo = repo.lower()
    name = repo.split("/")[-1]
    for entry in re.split(r"[,\s]+", listed.lower()):
        if entry and (entry == repo or ("/" not in entry and entry == name)):
            return True
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", required=True, help="owner/name of the PR's repo")
    ap.add_argument("--cleared", action="append", default=[], help="permalink of a matching post read as finished")
    ap.add_argument("--since", type=float, help="epoch to scan from (default: local midnight today)")
    args = ap.parse_args()

    if "/" not in args.repo:
        cannot_check(f"--repo must be owner/name, got {args.repo!r}")
    listed = config("PR_MERGE_RELEASE_GATE_REPOS")
    channel = config("PR_MERGE_RELEASE_CHANNEL")
    entries = [e for e in re.split(r"[,\s]+", listed) if e]
    bad = [e for e in entries if not re.fullmatch(r"[A-Za-z0-9._/-]+", e)]
    if bad:
        cannot_check(f"PR_MERGE_RELEASE_GATE_REPOS has unparseable entries: {bad}")
    if channel and not entries:
        cannot_check("PR_MERGE_RELEASE_CHANNEL is set but PR_MERGE_RELEASE_GATE_REPOS lists no repos")
    if not gated(args.repo, listed):
        out(f"{args.repo} is not release-gated (gated: {', '.join(entries) or 'none'})")
        return 0

    if not channel:
        cannot_check(f"{args.repo} is release-gated but PR_MERGE_RELEASE_CHANNEL is not set")
    tok = token()
    if not tok:
        cannot_check(f"no Slack token (SLACK_BOT_TOKEN, keychain {KEYCHAIN_SERVICE}, or {LEGACY_TOKEN_FILE})")

    if args.since is not None:
        since = args.since
    else:
        # Midnight built from the date, not by zeroing the clock: replace() keeps the
        # current UTC offset, which is wrong for midnight on a DST-change day.
        tz = None
        tzname = config("USER_TIMEZONE")
        if tzname:
            try:
                from zoneinfo import ZoneInfo
                tz = ZoneInfo(tzname)
            except Exception:
                cannot_check(f"USER_TIMEZONE={tzname!r} is not a known time zone")
        today = datetime.datetime.now(tz).date()
        midnight = datetime.datetime.combine(today, datetime.time(), tzinfo=tz)
        since = (midnight if tz else midnight.astimezone()).timestamp()

    name = args.repo.split("/")[-1]
    # Whole token: "api" must not match inside "api-v2", and the reverse. A separator in
    # the name also matches its spelling variants: "my-app" matches "my_app" and "my app".
    body_re = r"[-_ ]".join(re.escape(part) for part in re.split(r"[-_]", name))
    # A trailing "-v1.2" or "-2026..." is a version on the same repo, so it still matches.
    pattern = re.compile(rf"(?<![A-Za-z0-9_-]){body_re}(?![A-Za-z0-9_]|-(?!v?\d))", re.IGNORECASE)

    scanned, matches, cursor = 0, [], None
    while True:
        params = {"channel": channel, "oldest": f"{since:.6f}", "limit": 200}
        if cursor:
            params["cursor"] = cursor
        body = slack("conversations.history", tok, **params)
        for msg in body.get("messages") or []:
            scanned += 1
            if pattern.search(message_text(msg)):
                matches.append(msg)
        cursor = (body.get("response_metadata") or {}).get("next_cursor")
        if not cursor:
            break

    since_iso = datetime.datetime.fromtimestamp(since).astimezone().isoformat(timespec="minutes")
    out(f"scanned {scanned} post(s) in {channel} since {since_iso} for {name!r}: {len(matches)} match(es)")
    if not matches:
        return 0

    cleared = set()
    for link in args.cleared:
        m = PERMALINK_TS.search(link)
        if not m or f"/archives/{channel}/" not in link:
            cannot_check(f"--cleared {link!r} is not a permalink to a post in {channel}")
        cleared.add(f"{m.group(1)}.{m.group(2)}")
    unused = cleared - {msg["ts"] for msg in matches}
    for ts in sorted(unused):
        out(f"  warning: --cleared {ts} matches no post naming {name} today; it clears nothing")

    held = []
    for msg in sorted(matches, key=lambda m: float(m["ts"])):
        link = slack("chat.getPermalink", tok, channel=channel, message_ts=msg["ts"])["permalink"]
        when = datetime.datetime.fromtimestamp(float(msg["ts"])).astimezone().strftime("%H:%M %Z")
        first = (msg.get("text") or "").strip().splitlines()[0][:100] if (msg.get("text") or "").strip() else ""
        state = "cleared" if msg["ts"] in cleared else "HOLDS"
        out(f"  {state}  {when}  {link}  {first}")
        if msg["ts"] not in cleared:
            held.append(link)

    if held:
        out(f"held: {len(held)} post(s) today name {name}; hold the merge to the next business day,"
            " or read each thread and pass --release-cleared <permalink> once it is finished")
        return 1
    out("every match cited as finished — clear")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as exc:  # a crash is "could not check", never "held" or "clear"
        cannot_check(f"unexpected {type(exc).__name__}: {exc}")
