#!/usr/bin/env python3
"""Trigger-eval harness: measures a skill as actually installed (user-level, real name).

Why this exists instead of skill-creator's run_eval.py, and how to read a mid-task run:
../references/trigger-eval.md. Positive control is mandatory — a run whose control query
fails to trigger is reported as INSTRUMENT FAILURE, never as a description result.

  --eval-set      prompt mode: items are user queries.
  --mid-task-set  mid-task mode: items are a task plus a fixture rigged so the natural
                  first probe returns nothing; one item must carry `detector_control: true`
                  and name the skill outright. `controlled` (a further probe, no Skill
                  call) is a pass.
"""
import argparse, json, os, pathlib, shutil, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

SKILLS = pathlib.Path(os.path.expanduser("~/.claude/skills"))
PLUGINS = pathlib.Path(os.path.expanduser("~/.claude/plugins"))


def resolve_live(skill: str) -> pathlib.Path:
    """The directory the session actually loads <skill> from.

    A bare name is a user-level skill in ~/.claude/skills/<name>. `plugin:name` is a
    plugin skill: from a directory marketplace the session reads the source tree in
    place, so that is where it lives; otherwise the installed copy. Scoring a copy the
    session does not read would measure nothing.
    """
    if ":" not in skill:
        return SKILLS / skill
    plugin, name = skill.split(":", 1)
    installed = json.loads((PLUGINS / "installed_plugins.json").read_text())["plugins"]
    key = next((k for k in installed if k.startswith(plugin + "@")), None)
    if key is None:
        sys.exit(f"trigger_eval: plugin '{plugin}' is not installed")
    market = key.split("@", 1)[1]
    known = json.loads((PLUGINS / "known_marketplaces.json").read_text()).get(market, {})
    src = known.get("source", {})
    if src.get("source") == "directory":
        root = pathlib.Path(src["path"])
        manifest = json.loads((root / ".claude-plugin" / "marketplace.json").read_text())
        entry = next(e for e in manifest["plugins"] if e["name"] == plugin)
        return (root / entry["source"]).resolve() / "skills" / name
    return pathlib.Path(installed[key][0]["installPath"]) / "skills" / name

# Tools a mid-task fixture needs. Deliberately an allowlist and NOT a permission
# bypass: `--permission-mode bypassPermissions` from a spawned claude is refused by
# the auto-mode classifier, and working around that refusal is not the job.
MID_TASK_TOOLS = ["Bash", "Grep", "Glob", "Read", "Skill"]


def run_query(query: str, skill_name: str, model: str, timeout: int, cwd: str) -> bool | None:
    """True/False = triggered or not. None = the run itself failed (not a result)."""
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    try:
        p = subprocess.run(
            ["claude", "-p", query, "--output-format", "stream-json",
             "--verbose", "--model", model],
            capture_output=True, timeout=timeout, cwd=cwd, env=env,
            stdin=subprocess.DEVNULL,
        )
    except subprocess.TimeoutExpired:
        return None
    ok = False
    saw_result = False
    for line in p.stdout.decode("utf-8", "replace").splitlines():
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if e.get("type") == "assistant":
            for c in e.get("message", {}).get("content", []):
                if c.get("type") == "tool_use" and c.get("name") == "Skill":
                    if c.get("input", {}).get("skill") == skill_name:
                        ok = True
        elif e.get("type") == "result":
            saw_result = True
    return ok if saw_result else None


def run_mid_task(item, skill_name, model, timeout):
    """Measure a description against MID-TASK context instead of a user query.

    The gap this closes: every ordinary eval item is phrased in the operator's
    voice ("the query came back empty, is that real"), so it measures whether a
    description matches someone ELSE'S doubt. The failure that actually happens is
    the model taking a measurement itself, mid-task, and stating its verdict as a
    finding with no prompt in between. No query-shaped item can reach that.

    So the item here is a TASK plus a FIXTURE rigged so the natural first probe
    returns nothing. What gets measured is what the model does AFTER that empty
    result and BEFORE it answers.

    Four outcomes, and the middle two are the reason this is not a boolean:

      routed        a Skill call naming the skill, after the producing probe
      routed-early  a Skill call naming the skill with NO empty probe before it —
                    the act-then-verify shape, where the skill fires at the start of
                    the work rather than in reaction to a failed measurement
      controlled    no Skill call, but a further probe was actually RUN afterwards
      bare          the absence is answered with no further probe and no Skill call
      unmeasured    no producing probe ran at all, or the run failed / timed out

    `controlled` exists because detection-by-Skill-call measures the wrong thing
    here. Measured while building this: given an empty grep, the model ran two more
    probes and answered "the empty grep result is a real negative, not a broken
    search" — the exact behaviour the skill exists to produce, with no Skill call
    anywhere. A Skill-only detector scores that a non-trigger and would report a
    working description as broken. So a should_trigger item passes on routed OR
    controlled: the behaviour is the target, the routing is one way to reach it.

    `controlled` is a PROXY and is reported with its evidence, never alone. A
    further tool call is not proof the control was relevant, so the tool sequence
    and the answer text ride along in the result for a human to read. What it does
    buy is resistance to narration: a run that CLAIMS it verified while making no
    further call scores bare, which a prose match would have scored a pass.
    """
    fixture = tempfile.mkdtemp(prefix="trigger-eval-midtask-")
    try:
        for rel, content in (item.get("fixture") or {}).items():
            p = pathlib.Path(fixture) / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content)
        env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
        try:
            p = subprocess.run(
                ["claude", "-p", item["task"], "--output-format", "stream-json",
                 "--verbose", "--model", model, "--allowedTools", *MID_TASK_TOOLS],
                capture_output=True, timeout=timeout, cwd=fixture, env=env,
                stdin=subprocess.DEVNULL,
            )
        except subprocess.TimeoutExpired:
            return {"outcome": "unmeasured", "why": "timeout", "tools": [], "answer": ""}

        tools, skill_at, answer, saw_result = [], None, "", False
        results_by_id, id_of = {}, {}
        for line in p.stdout.decode("utf-8", "replace").splitlines():
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            if e.get("type") == "assistant":
                for c in e.get("message", {}).get("content", []):
                    if c.get("type") == "tool_use":
                        id_of[c.get("id")] = len(tools)
                        tools.append(c["name"])
                        if (c["name"] == "Skill"
                                and c.get("input", {}).get("skill") == skill_name
                                and skill_at is None):
                            skill_at = len(tools) - 1
                    elif c.get("type") == "text" and c.get("text", "").strip():
                        answer = c["text"]
            elif e.get("type") == "user":
                for c in e.get("message", {}).get("content", []):
                    if c.get("type") == "tool_result":
                        payload = c.get("content")
                        if isinstance(payload, list):
                            payload = " ".join(b.get("text", "") for b in payload
                                               if isinstance(b, dict))
                        results_by_id[c.get("tool_use_id")] = str(payload or "")
            elif e.get("type") == "result":
                saw_result = True

        if not saw_result:
            return {"outcome": "unmeasured", "why": "no result event",
                    "tools": tools, "answer": answer[:400], "empty_at": None}

        # THE MID-TASK CONDITION IS AN EMPTY RESULT, not merely a tool call.
        # Without this test the negative-control items are meaningless: any
        # multi-step task runs a second tool, so every item scores as though it had
        # audited something. Found by exactly that — two should-NOT items came back
        # `controlled` on ['Write','Bash'] and ['Bash','Read','Edit'], which is
        # ordinary task work in fixtures where nothing ever came back empty.
        sig = item.get("empty_signature")
        empty_at = None
        for tid, idx in id_of.items():
            if tools[idx] == "Skill":
                continue
            body = results_by_id.get(tid)
            if body is None:
                continue
            s = body.strip()
            # A declared signature WIDENS the test; it never narrows it. Declaring
            # empty_signature:"" used to swap the generic check for an exact-empty
            # one, so being more explicit made detection stricter and the detector
            # control failed on a run where the skill had plainly been invoked —
            # Grep returns the string 'No matches found', not "".
            hit = s == "" or any(m in s.lower() for m in (
                "no matches", "no files found", "collected 0 items",
                "0 items", "not found", "no such file", "found 0"))
            if sig:
                hit = hit or sig.lower() in s.lower()
            if hit:
                empty_at = idx if empty_at is None else min(empty_at, idx)
        if empty_at is None:
            # ACT-THEN-VERIFY skills fire BEFORE probing, not in reaction to an empty
            # result, so `routed` (a Skill call after the empty) is unreachable for
            # them however the fixture is built. Measured 2026-08-17 on
            # scope-a-grant-from-observed-use: `Skill` was the FIRST tool on both
            # detector-control runs, the answers were the target behaviour, and the
            # run was refused as unscorable. An explicit Skill call naming the skill
            # is the strongest signal this harness has — stronger than `controlled`,
            # which is only a proxy — so it counts even with no empty probe.
            if skill_at is not None:
                return {"outcome": "routed-early",
                        "why": "skill invoked before any probe returned empty (act-then-verify shape)",
                        "tools": tools, "answer": answer[:400], "empty_at": None,
                        "skill_called": True}
            # Nothing came back empty AND the skill never fired, so there was no
            # verdict to audit. For a should_trigger item that is a FIXTURE bug and
            # must not be scored as a non-trigger; for a should-NOT item it is normal.
            return {"outcome": "no-empty-result", "why": "no probe returned an empty or clean result",
                    "tools": tools, "answer": answer[:400], "empty_at": None,
                    "skill_called": False}

        if skill_at is not None and skill_at > empty_at:
            outcome = "routed"
        elif any(t != "Skill" for t in tools[empty_at + 1:]):
            outcome = "controlled"
        else:
            outcome = "bare"
        return {"outcome": outcome, "why": "", "tools": tools, "answer": answer[:400],
                "empty_at": empty_at, "skill_called": skill_at is not None}
    finally:
        shutil.rmtree(fixture, ignore_errors=True)


def evaluate_mid_task(skill_name, items, model, runs, workers, timeout):
    jobs = [(i, it) for i, it in enumerate(items) for _ in range(runs)]
    with ThreadPoolExecutor(max_workers=workers) as ex:
        outs = list(ex.map(lambda j: (j[0], run_mid_task(j[1], skill_name, model, timeout)), jobs))
    per = {}
    for idx, res in outs:
        per.setdefault(idx, []).append(res)
    results = []
    for idx, item in enumerate(items):
        rs = per.get(idx, [])
        rec = {"task": item["task"][:160], "should_trigger": item["should_trigger"],
               "outcomes": [r["outcome"] for r in rs], "pass": None, "note": "",
               "evidence": [{"tools": r["tools"], "empty_at": r.get("empty_at"),
                             "answer": r["answer"]} for r in rs]}
        # The two directions are scored on DIFFERENT criteria, deliberately.
        if item["should_trigger"]:
            # Only runs where an empty result actually occurred can be scored; a run
            # with none is a fixture that failed to rig its probe, and calling that a
            # non-trigger would blame the description for the harness's mistake.
            got = [r for r in rs if r["outcome"] in ("routed", "routed-early", "controlled", "bare")]
            rec["unscorable"] = len(rs) - len(got)
            if got:
                rate = sum(1 for r in got if r["outcome"] != "bare") / len(got)
                rec["audited_rate"] = rate
                rec["pass"] = rate >= 0.5
            else:
                rec["note"] = ("no run produced an empty result — the fixture did not rig its probe, "
                               "so this item measured nothing about the description")
        else:
            # Over-triggering is the only thing a negative item can show here, and it
            # is a Skill call, never a tool count: ordinary multi-step work runs more
            # tools and must not read as an audit.
            got = [r for r in rs if r["outcome"] != "unmeasured"]
            rec["unscorable"] = len(rs) - len(got)
            if got:
                called = sum(1 for r in got if r.get("skill_called"))
                rec["skill_called_rate"] = called / len(got)
                rec["pass"] = called == 0
                rec["note"] = "scored on whether the skill was invoked at all, not on tool count"
            else:
                rec["note"] = "every run failed"
        results.append(rec)
    return results


def evaluate(skill_name, eval_set, model, runs, workers, timeout, cwd):
    jobs = [(i, item) for i, item in enumerate(eval_set) for _ in range(runs)]
    with ThreadPoolExecutor(max_workers=workers) as ex:
        outs = list(ex.map(lambda j: (j[0], run_query(j[1]["query"], skill_name, model, timeout, cwd)), jobs))
    per = {}
    for idx, res in outs:
        per.setdefault(idx, []).append(res)
    results = []
    for idx, item in enumerate(eval_set):
        rs = per.get(idx, [])
        failed = sum(1 for r in rs if r is None)
        got = [r for r in rs if r is not None]
        rate = (sum(got) / len(got)) if got else None
        passed = None if rate is None else ((rate >= 0.5) == item["should_trigger"])
        results.append({"query": item["query"], "should_trigger": item["should_trigger"],
                        "trigger_rate": rate, "runs_failed": failed, "pass": passed})
    return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skill", required=True, help="<plugin>:<name> for a plugin skill, or a bare user-level name")
    ap.add_argument("--eval-set")
    ap.add_argument("--mid-task-set", help="measure against mid-task context instead of user queries")
    ap.add_argument("--description", help="candidate description to score instead of the installed one")
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--runs", type=int, default=2)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--timeout", type=int, default=180)
    ap.add_argument("--control", default="__auto__", help="positive-control query; __auto__ picks the first should_trigger item")
    a = ap.parse_args()

    if not (a.eval_set or a.mid_task_set):
        ap.error("pass --eval-set, --mid-task-set, or both")

    eval_set = json.loads(pathlib.Path(a.eval_set).read_text()) if a.eval_set else []
    mid_set = json.loads(pathlib.Path(a.mid_task_set).read_text()) if a.mid_task_set else []
    control = a.control
    if control == "__auto__" and eval_set:
        control = next(i["query"] for i in eval_set if i["should_trigger"])

    live = resolve_live(a.skill)
    if not (live / "SKILL.md").is_file():
        sys.exit(f"trigger_eval: no SKILL.md at {live}")
    parked = None
    tmpdir = tempfile.mkdtemp(prefix="trigger-eval-")
    try:
        if a.description:
            body = (live / "SKILL.md").read_text().split("---", 2)[2]
            parked = pathlib.Path(tmpdir) / "parked"
            shutil.move(str(live), str(parked))
            live.mkdir(parents=True)
            (live / "SKILL.md").write_text(
                f"---\nname: {a.skill.split(':')[-1]}\ndescription: {a.description}\n---{body}")

        cwd = tempfile.mkdtemp(prefix="trigger-eval-cwd-")
        out = {"skill": a.skill,
               "description_source": "candidate" if a.description else "installed"}

        if mid_set:
            # MANDATORY detector control, and the whole reason an all-negative
            # mid-task result can be believed. The expected finding in this mode is
            # "the description never fires", which is indistinguishable from "the
            # harness cannot see a mid-task invocation" — so one item must force the
            # invocation explicitly. It tests the DETECTOR, not the description:
            # its task names the skill outright, so a correct description is not
            # required to pass it and a broken detector cannot.
            det = next((i for i in mid_set if i.get("detector_control")), None)
            if det is None:
                print(json.dumps({"instrument": "FAILURE",
                                  "note": "mid-task set has no item marked detector_control:true — "
                                          "without it an all-negative result cannot be told from a blind harness"}, indent=1))
                return 2
            dres = [run_mid_task(det, a.skill, a.model, a.timeout) for _ in range(2)]
            if not any(r["outcome"] in ("routed", "routed-early") for r in dres):
                print(json.dumps({"instrument": "FAILURE", "mode": "mid-task",
                                  "detector_control": det["task"][:200],
                                  "detector_runs": dres,
                                  "note": "the detector control did not produce a routed outcome, so this run "
                                          "cannot distinguish a description that never fires from a harness that "
                                          "cannot see it firing — no results reported"}, indent=1))
                return 2
            out["mid_task_instrument"] = "OK (detector control routed)"
            scoreable = [i for i in mid_set if not i.get("detector_control")]
            mres = evaluate_mid_task(a.skill, scoreable, a.model, a.runs, a.workers, a.timeout)
            ms = [r for r in mres if r["pass"] is not None]
            out["mid_task"] = {
                "summary": {"total": len(mres), "scored": len(ms),
                            "passed": sum(1 for r in ms if r["pass"]),
                            "failed": sum(1 for r in ms if not r["pass"]),
                            "unscorable": len(mres) - len(ms)},
                "results": mres,
                "reading": "passed = the model routed to the skill OR ran a further probe after the empty "
                           "result. `controlled` is a proxy reported with its tool sequence and answer — "
                           "read them; a run that merely CLAIMS it verified scores bare.",
            }

        if eval_set:
            ctrl = [run_query(control, a.skill, a.model, a.timeout, cwd) for _ in range(2)]
            if not any(c is True for c in ctrl):
                print(json.dumps({"instrument": "FAILURE", "control_query": control,
                                  "control_runs": ctrl,
                                  "note": "control did not trigger — results would be meaningless"}, indent=1))
                return 2
            results = evaluate(a.skill, eval_set, a.model, a.runs, a.workers, a.timeout, cwd)
            scored = [r for r in results if r["pass"] is not None]
            out["instrument"] = "OK (positive control triggered)"
            out["prompt_mode"] = {
                "summary": {"total": len(results), "scored": len(scored),
                            "passed": sum(1 for r in scored if r["pass"]),
                            "failed": sum(1 for r in scored if not r["pass"]),
                            "unscorable": len(results) - len(scored)},
                "results": results}

        print(json.dumps(out, indent=1))
        return 0
    finally:
        if parked:
            shutil.rmtree(live, ignore_errors=True)
            shutil.move(str(parked), str(live))
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
