#!/usr/bin/env python3
"""Launch named Claude Code sessions in herdr panes and verify their peer addresses.

herdr only. Placement maps onto herdr's own three levels:

    split      new panes beside the caller's pane
    tab        new tabs in the caller's workspace
    workspace  new workspaces

Readiness is the live messaging socket, not herdr's own agent state. herdr
knowing a pane hosts a claude agent does not mean that claude registered a
peer-messaging socket, and the socket is the thing SendMessage needs. The two
worlds are joined through `agent_session.value`, which herdr reports as the
claude session id: session id -> ~/.claude/sessions/*.json -> pid and socket.

`interactive_ready` is deliberately not the gate. It is a real AgentInfo field
in the herdr schema, but herdr omits it for an agent it did not start, so a
truthiness test on it can never pass in those cases. It is reported when
present and never required.

Derived from ray-amjad/peer-sessions (MIT). See ../LICENSE.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

from peer_registry import find_record, socket_status


# herdr rejects any agent name outside this shape, and demands that the name is
# unique among live agents. The same string becomes `claude --name`, so a name
# that herdr rejects also costs you the peer address.
AGENT_NAME = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")

# herdr's settled states. `done` is `idle` after unseen background work; both
# mean the agent is up. `working` means it is up and busy. `blocked` means a
# human has to answer something, and is reported on its own line.
LIVE_STATES = {"idle", "done", "working"}
BLOCKED_STATES = {"blocked"}

DIRECTIONS = ("right", "down")
OTHER_DIRECTION = {"right": "down", "down": "right"}

# Resolved from this file, never spelled: the checkout path differs per machine and a plugin
# install does not live under ~/.claude/skills at all.
SKILL_SCRIPTS = os.path.dirname(os.path.realpath(__file__))

CLAUDE_CONFIG = os.path.expanduser("~/.claude.json")

# What a blocked pane is blocked on. The detection buffer holds the prompt text,
# so name the prompt instead of reporting a bare "blocked".
BLOCK_MARKERS = (
    ("I trust this folder", "the folder-trust prompt"),
    ("Do you want to proceed", "a tool permission prompt"),
    ("Do you trust", "the folder-trust prompt"),
)


# ---------------------------------------------------------------------------
# herdr plumbing
# ---------------------------------------------------------------------------


def herdr(*args):
    """Run herdr and return its parsed JSON `result` payload.

    herdr answers with JSON either way: a `result` key on success, an `error`
    key on failure. A server error goes to stderr with exit 1, and a syntax
    error exits 2, so read both streams and check the `error` key rather than
    trusting the exit code alone.
    """
    completed = subprocess.run(["herdr", *args], capture_output=True, text=True)
    streams = [
        text.strip() for text in (completed.stdout, completed.stderr) if text.strip()
    ]
    for text in streams:
        try:
            payload = json.loads(text)
        except ValueError:
            continue
        if not isinstance(payload, dict):
            continue
        if "error" in payload:
            error = payload["error"]
            detail = error if isinstance(error, str) else json.dumps(error)
            raise RuntimeError(f"herdr {' '.join(args)}\n  → {detail}")
        if "result" in payload:
            return payload["result"]
    joined = "\n".join(streams) or f"exit {completed.returncode}, no output"
    raise RuntimeError(f"herdr {' '.join(args)}\n  → {joined}")


def require_herdr():
    """Fail early and plainly rather than halfway through building a fleet."""
    if os.environ.get("HERDR_ENV") != "1":
        sys.exit(
            "error: this script needs to run inside a herdr pane (HERDR_ENV is "
            "not 1). Start herdr, run claude inside a herdr pane, and try again."
        )
    if not shutil.which("herdr"):
        sys.exit("error: 'herdr' is not on PATH.")


def live_agent_names():
    """Every name herdr would resolve as an agent target, for the collision check.

    Two fields carry a name. `name` holds the name an `agent start` assigned.
    `agent` holds the kind label, which is how herdr addresses an agent it merely
    detected — so a plain interactive claude session occupies the name `claude`.
    Both are taken, so both belong in the set.
    """
    try:
        result = herdr("agent", "list")
    except RuntimeError:
        return set()
    names = set()
    for agent in result.get("agents", []):
        for field in ("name", "agent"):
            value = agent.get(field)
            if value:
                names.add(value)
    return names


def agent_info(name):
    """`herdr agent get <name>` unwrapped, or None when herdr has no such agent."""
    try:
        result = herdr("agent", "get", name)
    except RuntimeError:
        return None
    return result.get("agent", result)


def agent_screen(name):
    """The detection buffer as plain text. `agent read` prints text, not JSON."""
    completed = subprocess.run(
        ["herdr", "agent", "read", name, "--source", "detection", "--lines", "40"],
        capture_output=True,
        text=True,
    )
    return completed.stdout or ""


def block_reason(name):
    screen = agent_screen(name)
    for marker, label in BLOCK_MARKERS:
        if marker in screen:
            return label
    return None


def pane_pid(pane_id, name):
    """Read the claude pid straight off the pane.

    The session registry has no record until claude finishes starting, so a peer
    still parked on the folder-trust prompt is invisible there. herdr knows the
    foreground process either way, and its argv carries `--name`, which confirms
    the pid belongs to this peer and not to something else in the pane.
    """
    try:
        result = herdr("pane", "process-info", "--pane", pane_id)
    except RuntimeError:
        return None
    info = result.get("process_info", {})
    for process in info.get("foreground_processes", []):
        argv = process.get("argv") or []
        pid = process.get("pid")
        if not isinstance(pid, int):
            continue
        if process.get("argv0") == "claude" and name in argv:
            return pid
    return None


def trusted_directories():
    """Directories claude already trusts, from its own config.

    Trust is per exact path and is not inherited by a subdirectory, so a peer
    started anywhere else stops on the folder-trust prompt before it registers a
    messaging socket. Read the list rather than find out one stalled pane later.
    """
    try:
        with open(CLAUDE_CONFIG) as handle:
            config = json.load(handle)
    except (OSError, ValueError):
        return None
    projects = config.get("projects")
    if not isinstance(projects, dict):
        return None
    return {
        path
        for path, entry in projects.items()
        if isinstance(entry, dict) and entry.get("hasTrustDialogAccepted") is True
    }


def warn_untrusted(specs):
    trusted = trusted_directories()
    if trusted is None:
        return
    untrusted = sorted({directory for _, directory in specs if directory not in trusted})
    if not untrusted:
        return
    print(
        "note: claude does not yet trust "
        f"{len(untrusted)} of these directories, and trust is per exact path, "
        "never inherited from a parent. Each peer there stops on the "
        "folder-trust prompt and registers no messaging socket until a human "
        "answers it:",
        file=sys.stderr,
    )
    for directory in untrusted:
        print(f"  {directory}", file=sys.stderr)
    print(
        "Spawn in a directory the user already works in, or expect to hand them "
        "the prompts.",
        file=sys.stderr,
    )


def focus_flag(focus):
    return "--focus" if focus else "--no-focus"


# ---------------------------------------------------------------------------
# building the layout
# ---------------------------------------------------------------------------


def split_pane(anchor, direction, cwd, focus):
    result = herdr(
        "pane", "split",
        "--pane", anchor,
        "--direction", direction,
        "--cwd", cwd,
        focus_flag(focus),
    )
    return result["pane"]["pane_id"]


def start_agent(name, pane_id, argv, retry_seconds=8.0):
    """Start claude in a pane herdr just made, retrying the settle race.

    `agent start` needs an available shell: a pane at an interactive prompt with
    the shell in the foreground. A pane that `pane split` returned a moment ago
    is not always that yet, because herdr is still settling the new pty, and it
    answers `agent_pane_busy`. Retry that one error, and only that one.
    """
    deadline = time.time() + retry_seconds
    while True:
        try:
            herdr(
                "agent", "start", name,
                "--kind", "claude",
                "--pane", pane_id,
                "--", *argv,
            )
            return
        except RuntimeError as error:
            if "agent_pane_busy" not in str(error) or time.time() >= deadline:
                raise
            time.sleep(0.3)


def direction_for(requested, explicit, index):
    """Alternate the split direction for a third and later pane, unless told not to.

    herdr's own guidance is to split a wide pane right, a tall pane down, and to
    avoid repeated splits in one direction — three panes chained one way end up
    unreadably thin. A direction the caller typed is obeyed exactly; only the
    default alternates.
    """
    if explicit or index < 2:
        return requested
    return requested if index % 2 == 0 else OTHER_DIRECTION[requested]


def new_layout(placement):
    """The record of what this run created, so a failure can undo exactly that."""
    return {
        "placement": placement,
        "workspaces": [],
        "tabs": [],
        "panes": {},
        "home": os.environ.get("HERDR_WORKSPACE_ID"),
    }


def roll_back(layout):
    """Close what this run created, after it failed part way through.

    A half-built fleet is worse than none: the panes are there, no peer answers,
    and the identifiers are only in a traceback. Stop each claude that did start,
    then close the surfaces from the inside out. Every step is best effort — the
    original failure is the one worth reporting.
    """
    for name, pane in layout["panes"].items():
        pid = pane_pid(pane, name)
        if pid:
            try:
                os.kill(pid, 15)
            except OSError:
                pass
    surfaces = [("pane", pane) for pane in layout["panes"].values()]
    surfaces += [("tab", tab) for tab in layout["tabs"]]
    surfaces += [("workspace", ws) for ws in layout["workspaces"]]
    closed = []
    for kind, identifier in surfaces:
        # A pane inside a tab this run made is already gone with the tab.
        try:
            herdr(kind, "close", identifier)
            closed.append(f"{kind} {identifier}")
        except RuntimeError:
            continue
    return closed


def build_splits(specs, argv_for, direction, explicit_direction, focus, layout):
    anchor = os.environ.get("HERDR_PANE_ID")
    if not anchor:
        sys.exit(
            "error: --placement split needs HERDR_PANE_ID, which herdr sets in "
            "each pane. Use --placement tab or --placement workspace instead."
        )
    if len(specs) > 3:
        print(
            f"note: {len(specs)} panes beside one pane get thin. "
            "Use --placement tab or --placement workspace.",
            file=sys.stderr,
        )
    for index, (name, directory) in enumerate(specs):
        pane_id = split_pane(
            anchor,
            direction_for(direction, explicit_direction, index),
            directory,
            focus,
        )
        layout["panes"][name] = pane_id
        start_agent(name, pane_id, argv_for(name))
        anchor = pane_id  # chain, so the panes line up in spec order
    return layout


def build_groups(specs, argv_for, placement, prefix, per_group, direction,
                 explicit_direction, focus, layout):
    """One tab or one workspace per group of sessions."""
    workspace = os.environ.get("HERDR_WORKSPACE_ID")
    if placement == "tab" and not workspace:
        sys.exit(
            "error: --placement tab needs HERDR_WORKSPACE_ID, which herdr sets "
            "in each pane. Use --placement workspace instead."
        )
    groups = [
        specs[start : start + per_group]
        for start in range(0, len(specs), per_group)
    ]
    workspaces = layout["workspaces"]
    tabs = layout["tabs"]
    panes = layout["panes"]
    for group_index, group in enumerate(groups, 1):
        first_name, first_dir = group[0]
        label = f"{prefix}-{group_index}"
        # Focus the first group only, so the UI does not walk the whole fleet.
        group_focus = focus and group_index == 1
        if placement == "workspace":
            result = herdr(
                "workspace", "create",
                "--cwd", first_dir,
                "--label", label,
                focus_flag(group_focus),
            )
            workspaces.append(result["workspace"]["workspace_id"])
        else:
            result = herdr(
                "tab", "create",
                "--workspace", workspace,
                "--cwd", first_dir,
                "--label", label,
                focus_flag(group_focus),
            )
        tabs.append(result["tab"]["tab_id"])
        anchor = result["root_pane"]["pane_id"]
        panes[first_name] = anchor
        start_agent(first_name, anchor, argv_for(first_name))

        for index, (name, directory) in enumerate(group[1:], 1):
            pane_id = split_pane(
                anchor,
                direction_for(direction, explicit_direction, index),
                directory,
                False,
            )
            panes[name] = pane_id
            start_agent(name, pane_id, argv_for(name))
            anchor = pane_id
    return layout


# ---------------------------------------------------------------------------
# readiness
# ---------------------------------------------------------------------------


def probe(name):
    """Report one peer as ready, blocked, or still coming up.

    Ready means a live messaging socket, because that is what SendMessage needs.
    Reach it through herdr's `agent_session`, which carries the claude session
    id, and then through the session registry for the pid and the socket path.
    """
    agent = agent_info(name)
    if agent is None:
        return {"state": "missing", "reason": "herdr has no agent by this name"}

    status = agent.get("agent_status")
    report = {
        "pane": agent.get("pane_id"),
        "status": status,
        "interactiveReady": agent.get("interactive_ready"),
    }

    session = agent.get("agent_session") or {}
    session_id = session.get("value") if session.get("kind") == "id" else None
    record = find_record(session_id=session_id) if session_id else None
    if record:
        report["pid"] = record.get("pid")
        report["sessionId"] = record.get("sessionId")
        socket_path = record.get("messagingSocketPath")
        report["socketPath"] = socket_path
        state = socket_status(socket_path)
        if state == "live":
            report["state"] = "ready"
            report["address"] = f"uds:{socket_path}"
            return report
        if state == "denied":
            # A sandbox may forbid the connect on a socket that is perfectly
            # healthy. Treat the peer as up and say the check was refused.
            report["state"] = "unverified"
            report["reason"] = "socket check denied by sandbox"
            report["address"] = f"uds:{socket_path}"
            return report

    if report.get("pid") is None and report.get("pane"):
        report["pid"] = pane_pid(report["pane"], name)

    if status in BLOCKED_STATES:
        report["state"] = "blocked"
        prompt = block_reason(name)
        report["reason"] = (
            f"stopped on {prompt} — a human has to answer it"
            if prompt
            else "waits for a human — read the pane"
        )
        return report

    if record is None:
        report["reason"] = (
            "no session registry record yet"
            if session_id
            else "herdr reports no claude session id yet"
        )
    else:
        report["reason"] = "registered, but no live messaging socket yet"
    report["state"] = "starting" if status in LIVE_STATES or status is None else status
    return report


def settled(reports):
    return all(
        report.get("state") in ("ready", "unverified", "blocked")
        for report in reports.values()
    )


# ---------------------------------------------------------------------------
# input and output
# ---------------------------------------------------------------------------


def parse_specs(raw, mkdir):
    specs = []
    for item in raw:
        if ":" not in item:
            sys.exit(f"error: '{item}' is not NAME:DIR")
        name, _, directory = item.partition(":")
        name = name.strip()
        directory = os.path.abspath(os.path.expanduser(directory.strip()))
        if not AGENT_NAME.match(name):
            sys.exit(
                f"error: '{name}' is not a usable agent name. herdr wants a "
                "lowercase letter, then up to 31 more of a-z, 0-9, '_' or '-'."
            )
        if not os.path.isdir(directory):
            if not mkdir:
                sys.exit(
                    f"error: '{directory}' is not a directory. Check the path, "
                    "or pass --mkdir to create it."
                )
            os.makedirs(directory, exist_ok=True)
        specs.append((name, directory))

    names = [name for name, _ in specs]
    repeated = sorted({name for name in names if names.count(name) > 1})
    if repeated:
        sys.exit(f"error: duplicate session names: {', '.join(repeated)}")
    taken = sorted(set(names) & live_agent_names())
    if taken:
        sys.exit(
            f"error: herdr already has a live agent named: {', '.join(taken)}. "
            "Agent names must be unique. Pick another, or run "
            "`herdr agent list` to see what holds it."
        )
    return specs


def print_reports(specs, reports):
    marks = {"ready": "+", "unverified": "?", "blocked": "!"}
    width = max(len(name) for name, _ in specs)
    for name, _ in specs:
        report = reports.get(name, {"state": "missing", "reason": "never probed"})
        state = report.get("state")
        mark = marks.get(state, "-")
        pane = report.get("pane") or "?"
        detail = report.get("address") or report.get("reason") or state
        pid = report.get("pid")
        pid_text = f"pid {pid:<7} " if isinstance(pid, int) else ""
        print(f"{mark} {name:<{width}}  pane {pane:<8} {pid_text}{detail}")


def print_teardown(layout, reports):
    pids = sorted(
        {
            report["pid"]
            for report in reports.values()
            if isinstance(report.get("pid"), int)
        }
    )
    print("\nTeardown is off by default. Hand this block to the user, and run it")
    print("only when they ask. Stop the processes before closing any herdr")
    print("surface — closing a pane does not stop the claude inside it:")
    if pids:
        print("  kill " + " ".join(str(pid) for pid in pids))
    else:
        print(
            "  # No pid resolved. Read each pane with "
            "`herdr pane process-info --pane <id>` before you close it."
        )
    if layout["placement"] == "workspace":
        for workspace in layout["workspaces"]:
            print(f"  herdr workspace close {workspace}")
    elif layout["placement"] == "tab":
        for tab in layout["tabs"]:
            print(f"  herdr tab close {tab}")
    else:
        for pane in layout["panes"].values():
            print(f"  herdr pane close {pane}")
    print(f"  python3 {SKILL_SCRIPTS}/peer-addr.py")
    if layout["placement"] == "split":
        print(
            "\nClose only the panes listed above. The workspace "
            f"({layout['home'] or 'this one'}) is the user's own."
        )


def print_next_steps(reports):
    blocked = [name for name, report in reports.items() if report["state"] == "blocked"]
    if blocked:
        print(
            "\nBlocked: " + ", ".join(sorted(blocked)) + ". Each one waits for a "
            "human. `herdr agent focus <name>` puts the user in front of it."
        )
    addressable = [
        name for name, report in reports.items() if report.get("address")
    ]
    if addressable:
        print(
            "\nSend with the bare name from ListAgents, or with the uds: address "
            "above. Then end your turn — replies arrive as new user turns."
        )


def main():
    parser = argparse.ArgumentParser(
        description="Launch named Claude Code sessions in herdr panes."
    )
    parser.add_argument("specs", nargs="+", metavar="NAME:DIR")
    parser.add_argument(
        "--placement",
        choices=("split", "tab", "workspace"),
        default="workspace",
        help="split: panes beside this one. tab: new tabs in this workspace. "
        "workspace: new workspaces (default)",
    )
    parser.add_argument(
        "--direction",
        choices=DIRECTIONS,
        default=None,
        help="direction of each new pane (default: right, and a third or later "
        "pane alternates so the panes stay readable). Naming it turns the "
        "alternation off.",
    )
    parser.add_argument("--focus", dest="focus", action="store_true", default=None,
                        help="move the UI to the fleet")
    parser.add_argument("--no-focus", dest="focus", action="store_false",
                        help="leave the UI where it is (the default for split)")
    parser.add_argument("--per-group", type=int, default=2, choices=(1, 2),
                        help="sessions per tab or workspace (default 2)")
    parser.add_argument("--prefix", default="fleet",
                        help="label prefix for each new tab or workspace")
    parser.add_argument("--mkdir", action="store_true",
                        help="create a working directory that does not exist")
    parser.add_argument("--model")
    parser.add_argument("--claude-arg", action="append", default=[],
                        help="repeatable; passed to claude verbatim")
    parser.add_argument("--timeout", type=int, default=120,
                        help="seconds to wait for live messaging sockets")
    parser.add_argument("--permission-mode", default="auto")
    args = parser.parse_args()

    require_herdr()

    explicit_direction = args.direction is not None
    direction = args.direction or "right"
    focus = args.focus
    if focus is None:
        focus = args.placement != "split"

    specs = parse_specs(args.specs, args.mkdir)
    warn_untrusted(specs)

    extra = list(args.claude_arg)
    if args.model:
        extra += ["--model", args.model]

    def argv_for(name):
        return ["--name", name, "--permission-mode", args.permission_mode, *extra]

    layout = new_layout(args.placement)
    try:
        if args.placement == "split":
            build_splits(specs, argv_for, direction, explicit_direction, focus, layout)
        else:
            build_groups(
                specs, argv_for, args.placement, args.prefix, args.per_group,
                direction, explicit_direction, focus, layout,
            )
    except RuntimeError as error:
        # Half a fleet is worse than none. Undo this run's own surfaces, and
        # report the herdr error rather than a traceback.
        closed = roll_back(layout)
        print(f"error: {error}", file=sys.stderr)
        if closed:
            print("rolled back: " + ", ".join(closed), file=sys.stderr)
        return 1

    if args.placement == "split":
        print(f"workspace {layout['home'] or '?'} (this one)")
    else:
        if layout["workspaces"]:
            print("workspaces " + ", ".join(layout["workspaces"]))
        else:
            print("tabs " + ", ".join(layout["tabs"]))
    print("panes " + ", ".join(f"{name}={pane}" for name, pane in layout["panes"].items()))

    started = time.time()
    reports = {}
    while True:
        reports = {name: probe(name) for name, _ in specs}
        if settled(reports) or time.time() - started >= args.timeout:
            break
        time.sleep(2)
    elapsed = int(time.time() - started)

    print()
    print_reports(specs, reports)

    ready = [
        name
        for name, report in reports.items()
        if report["state"] in ("ready", "unverified")
    ]
    if len(ready) == len(specs):
        print(f"\n{len(ready)} ready in {elapsed}s.")
    else:
        print(
            f"\n{len(ready)}/{len(specs)} reachable after {elapsed}s. A peer that "
            "herdr shows as up but that has no socket is the usual sign of a "
            "narrower SendMessage: read references/troubleshooting.md.",
            file=sys.stderr,
        )
    print_next_steps(reports)
    print_teardown(layout, reports)
    return 0 if len(ready) == len(specs) else 1


if __name__ == "__main__":
    sys.exit(main())
