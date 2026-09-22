#!/usr/bin/env python3
"""check.py — which installed Claude Code plugins are behind their marketplace's latest release.

Reads what Claude Code itself records (plugins/installed_plugins.json, known_marketplaces.json),
looks each marketplace up with git, and reports every installed plugin whose latest release
differs from the one installed, with the commands that update it.

TWO RAILS, deliberately separate. The NETWORK lookup (a git fetch into a private mirror, or an
ls-remote for a directory marketplace's upstream) is rate-limited per marketplace to once per
PLUGIN_UPDATES_INTERVAL (default 86400s). The COMPARISON runs every session against what the
mirror holds, so the report clears the moment a plugin is updated, with no network at all.
A plugin updated after its marketplace was last looked up means the lookup predates at least
one release, so that marketplace is looked up again at once rather than at the interval.

Deterministic: never runs `claude` (a hook that spawns claude is the fork-bomb trap), never
prompts for credentials, always exits 0. The update commands it names are for the assistant to
run after the user agrees.

Usage: check.py --hook     SessionStart hook JSON (systemMessage + additionalContext)
       check.py            the same report as plain text
       check.py --refresh  look every marketplace up now, ignoring the interval
Env:   PLUGIN_UPDATES_CHECK=0     disable (silent, no lookup)
       PLUGIN_UPDATES_INTERVAL    seconds between lookups of one marketplace
       PLUGIN_UPDATES_GITHUB_BASE where GitHub repos resolve (tests point it at local repos)
"""
import datetime
import json
import os
import re
import subprocess
import sys
import time

CFG = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
DATA = os.environ.get("CLAUDE_PLUGIN_DATA") or os.path.join(CFG, "plugin-updates")
BUDGET = 20.0  # seconds of network per session; the hook's own timeout is 30
GIT_ENV = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_ASKPASS="/bin/echo", SSH_ASKPASS="/bin/echo",
               GIT_SSH_COMMAND="ssh -o BatchMode=yes")
START = time.monotonic()


def git(*args, cwd=None, timeout=10.0):
    """Run git; return stdout or None. Credential helpers are off so a private repo fails
    instead of opening a keychain prompt in the middle of session start."""
    try:
        r = subprocess.run(["git", "-c", "credential.helper=", *args], cwd=cwd, env=GIT_ENV,
                           capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout if r.returncode == 0 else None


def remaining():
    return BUDGET - (time.monotonic() - START)


def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def epoch(iso):
    try:
        return datetime.datetime.fromisoformat(str(iso).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def remote_url(src):
    kind = src.get("source")
    if kind == "github" and src.get("repo"):
        base = os.environ.get("PLUGIN_UPDATES_GITHUB_BASE")
        if base:
            return f"{base}/{src['repo'].split('/')[-1]}.git"
        return f"https://github.com/{src['repo']}.git"
    if kind == "git" and src.get("url"):
        return src["url"]
    return None


def safe(name):
    return re.sub(r"[^A-Za-z0-9._-]", "_", name)


def lookup(name, src, state):
    """Refresh one marketplace from the network. Returns an error string, or None on success.
    A failed attempt still stamps the state: an offline machine pays the timeout once per
    interval, not every session, and keeps whatever the mirror already held."""
    t = min(8.0, remaining())
    if t <= 1:
        return "out of time"
    st = state.setdefault(name, {})
    st["stamp"] = time.time()
    if src.get("source") == "directory":
        clone = src.get("path", "")
        up = git("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}", cwd=clone)
        if not up:
            st.pop("upstream", None)
            return None  # no upstream to be behind
        remote, _, branch = up.strip().partition("/")
        url = (git("remote", "get-url", remote, cwd=clone) or "").strip()
        out = git("ls-remote", url, f"refs/heads/{branch}", timeout=t) if url else None
        if not out:
            return "upstream lookup failed"
        st["upstream"] = out.split()[0]
        st["upstream_name"] = up.strip()
        return None
    url = remote_url(src)
    if not url:
        return f"source type {src.get('source')!r} is not checked"
    mirror = os.path.join(DATA, "mirrors", safe(name) + ".git")
    if not os.path.isdir(mirror):
        os.makedirs(os.path.dirname(mirror), exist_ok=True)
        if git("init", "-q", "--bare", mirror) is None:
            return "could not create a mirror"
    ref = src.get("ref") or "HEAD"
    if git("-C", mirror, "fetch", "-q", "--no-tags", url, f"+{ref}:refs/pu/latest", timeout=t) is None:
        return "lookup failed"
    return None


def external(ident, src, state, due):
    """Latest release of a plugin whose catalog entry points at ANOTHER repo. The version lives
    in that repo's plugin.json, not in the marketplace, so the marketplace lookup cannot answer
    it — found live as `not checked: credential-guard@pleejr`. Mirrored and rate-limited exactly
    like a marketplace. Returns (version_or_commit, None) or (None, reason)."""
    url = remote_url(src)
    if not url:
        return None, f"source type {src.get('source')!r} is not checked"
    mirror = os.path.join(DATA, "mirrors", "ext_" + safe(ident) + ".git")
    if due:
        st = state.setdefault("ext:" + ident, {})
        st["stamp"] = time.time()
        t = min(8.0, remaining())
        if t <= 1:
            return None, "out of time"
        if not os.path.isdir(mirror):
            os.makedirs(os.path.dirname(mirror), exist_ok=True)
            if git("init", "-q", "--bare", mirror) is None:
                return None, "could not create a mirror"
        ref = src.get("ref") or "HEAD"
        if git("-C", mirror, "fetch", "-q", "--no-tags", url, f"+{ref}:refs/pu/latest", timeout=t) is None:
            return None, "lookup failed"
    if not os.path.isdir(mirror):
        return None, "never looked up"
    head = (git("-C", mirror, "rev-parse", "-q", "--verify", "refs/pu/latest") or "").strip()
    if not head:
        return None, "never looked up"
    manifest = show_json(mirror, head, ".claude-plugin/plugin.json") or {}
    return str(manifest.get("version") or head[:12]), None


def show_json(repo, rev, path):
    out = git("-C", repo, "show", f"{rev}:{path}")
    try:
        return json.loads(out) if out else None
    except ValueError:
        return None


def main():
    hook = "--hook" in sys.argv
    if os.environ.get("PLUGIN_UPDATES_CHECK", "1") == "0":
        return
    installed = load(os.path.join(CFG, "plugins", "installed_plugins.json"), {}).get("plugins", {})
    known = load(os.path.join(CFG, "plugins", "known_marketplaces.json"), {})
    if not isinstance(installed, dict) or not isinstance(known, dict) or not installed:
        return
    state_path = os.path.join(DATA, "state.json")
    state = load(state_path, {})
    try:
        interval = int(os.environ.get("PLUGIN_UPDATES_INTERVAL", "86400"))
    except ValueError:
        interval = 86400
    now = time.time()

    by_mkt = {}
    for key, recs in installed.items():
        if "@" in key and isinstance(recs, list):
            for rec in recs:
                if isinstance(rec, dict):
                    by_mkt.setdefault(key.rsplit("@", 1)[1], []).append((key.rsplit("@", 1)[0], rec))

    failed = {}
    for mkt in by_mkt:
        src = (known.get(mkt) or {}).get("source") or {}
        st = state.get(mkt, {})
        stamp = float(st.get("stamp", 0))
        moved = any(epoch(rec.get("lastUpdated", "")) > stamp for _, rec in by_mkt[mkt])
        # A marketplace whose source changed since its last lookup (a directory clone restored
        # as its GitHub remote) has nothing cached under the new source; its stamp is the old
        # source's, so waiting out the interval reported it "never looked up" for a day.
        resourced = st.get("source") != src
        if "--refresh" in sys.argv or now >= stamp + interval or moved or resourced:
            err = lookup(mkt, src, state)
            state[mkt]["source"] = src
            if err:
                failed[mkt] = err
                state[mkt]["error"] = err  # sessions inside the interval repeat the real reason
            else:
                state[mkt].pop("error", None)
    current, outdated, notes, cmds, unchecked = 0, [], [], [], {}
    for mkt, plugins in sorted(by_mkt.items()):
        src = (known.get(mkt) or {}).get("source") or {}
        if src.get("source") == "directory":
            repo = src.get("path", "")
            latest = (git("-C", repo, "rev-parse", "HEAD") or "").strip()
        else:
            repo = os.path.join(DATA, "mirrors", safe(mkt) + ".git")
            latest = (git("-C", repo, "rev-parse", "-q", "--verify", "refs/pu/latest") or "").strip() \
                if os.path.isdir(repo) else ""
        if not latest:
            unchecked[mkt] = failed.get(mkt) or state.get(mkt, {}).get("error") or "never looked up"
            continue
        catalog = show_json(repo, latest, ".claude-plugin/marketplace.json") or {}
        entries = {p.get("name"): p for p in catalog.get("plugins", []) if isinstance(p, dict)}
        mkt_cmds = []
        for name, rec in plugins:
            ident = f"{name}@{mkt}"
            scope = rec.get("scope", "user")
            upd = f"claude plugin update {ident}" + ("" if scope == "user" else f" --scope {scope}")
            if scope != "user" and rec.get("projectPath"):
                upd = f"(cd {rec['projectPath']} && {upd})"
            inst = str(rec.get("version", ""))
            entry = entries.get(name)
            if entry is None:
                notes.append(f"{ident} is no longer in the {mkt} marketplace (claude plugin uninstall {ident} if unwanted)")
                continue
            psrc = entry.get("source")
            new = None
            if isinstance(psrc, str):
                path = psrc[2:] if psrc.startswith("./") else psrc
                manifest = show_json(repo, latest, f"{path.rstrip('/')}/.claude-plugin/plugin.json") or {}
                ver = manifest.get("version") or entry.get("version")
                if ver:
                    new = None if str(ver) == inst else str(ver)
                else:
                    # Unversioned: installed as a marketplace commit. Outdated only when the
                    # plugin's own files changed since — a commit elsewhere changes nothing it runs.
                    sha = str(rec.get("gitCommitSha") or inst)
                    same = latest.startswith(sha) or (
                        git("-C", repo, "cat-file", "-e", f"{sha}^{{commit}}") is not None
                        and git("-C", repo, "diff", "--quiet", sha, latest, "--", path) is not None)
                    new = None if same else latest[:12]
                    inst = sha[:12]
            elif isinstance(psrc, dict):
                ver = entry.get("version")
                ref = str(psrc.get("ref", ""))
                if not ver and re.fullmatch(r"v?\d+(\.\d+)*([-+].*)?", ref):
                    ver = ref
                if not ver:
                    # The catalog names the repo and nothing else: ask that repo.
                    st = state.get("ext:" + ident, {})
                    stamp = float(st.get("stamp", 0))
                    due = ("--refresh" in sys.argv or now >= stamp + interval
                           or epoch(rec.get("lastUpdated", "")) > stamp)
                    ver, why = external(ident, psrc, state, due)
                    if not ver:
                        unchecked[ident] = why
                        continue
                    inst = str(rec.get("version", ""))
                ver = str(ver).lstrip("v")
                new = None if ver == inst.lstrip("v") else ver
            else:
                unchecked[ident] = "unrecognised source"
                continue
            if new:
                outdated.append(f"{ident} {inst} → {new}")
                mkt_cmds.append(upd)
            else:
                current += 1
        st = state.get(mkt, {})
        if src.get("source") == "directory" and st.get("upstream"):
            up = st["upstream"]
            if not latest.startswith(up) and git("-C", repo, "merge-base", "--is-ancestor", up, "HEAD") is None:
                notes.append(f"the {mkt} marketplace clone is behind {st.get('upstream_name', 'its upstream')}")
                mkt_cmds = [f"git -C {repo} pull --ff-only"] + [
                    f"claude plugin update {n}@{mkt}" for n, _ in plugins]
        if mkt_cmds:
            if src.get("source") != "directory":
                mkt_cmds.insert(0, f"claude plugin marketplace update {mkt}")
            cmds += list(dict.fromkeys(mkt_cmds))

    stamps = [float(state.get(m, {}).get("stamp", 0)) for m in by_mkt if state.get(m, {}).get("stamp")]
    ago = ""
    if stamps:
        age = int(now - min(stamps))
        ago = ("just now" if age < 60 else f"{age // 60}m ago" if age < 3600
               else f"{age // 3600}h ago" if age < 86400 else f"{age // 86400}d ago")
    skipped = f" · not checked: {', '.join(f'{k} ({v})' for k, v in unchecked.items())}" if unchecked else ""

    if outdated or notes:
        head = f"plugins: {len(outdated)} outdated, {current} current{skipped}"
        banner = "\n".join([head] + [f"  {o}" for o in outdated] + [f"  {n}" for n in notes])
        context = banner
        if cmds:
            context += ("\n\nACTION: ask the user whether to update these plugins now (the `plugin-updates` "
                        "skill covers it). On yes, run in order:\n" + "\n".join(f"  {c}" for c in cmds) +
                        "\nThen tell the user to run /reload-plugins, or start a new session, so this "
                        "session loads the updated plugins.")
    else:
        banner = f"plugins: {current} current" + (f" (looked up {ago})" if ago else "") + skipped
        context = ""

    try:
        os.makedirs(DATA, exist_ok=True)
        with open(state_path, "w") as f:
            json.dump(state, f)
    except OSError:
        pass

    if hook:
        out = {"systemMessage": banner}
        if context:
            out["hookSpecificOutput"] = {"hookEventName": "SessionStart", "additionalContext": context}
        print(json.dumps(out))
    else:
        print(context or banner)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # never break session start; say so rather than go quiet
        if "--hook" in sys.argv:
            print(json.dumps({"systemMessage": f"plugin-updates: check failed ({type(e).__name__}: {e})"}))
        else:
            print(f"plugin-updates: check failed ({type(e).__name__}: {e})", file=sys.stderr)
    sys.exit(0)
