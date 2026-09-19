#!/usr/bin/env python3
"""
tfsort_safe — a content-preserving wrapper around `tfsort`.

`tfsort` (>=0.7.1) alphabetically sorts Terraform `variable`/`output` blocks, but
it DROPS standalone / commented-out blocks and section comments that are not the
doc-comment directly attached to a retained block. That is silent content loss.

This wrapper guarantees the invariant: **a file is only ever written if every
non-blank line of the original is preserved.** It does this by:

  1. Running `tfsort` on a temp copy (the real file is never touched yet).
  2. If tfsort's output preserves all original content -> use it (canonical format).
  3. If tfsort lost content -> reconstruct a sorted file that reuses tfsort's
     ORDER but re-attaches each block's ORIGINAL leading comments (so a lost
     comment travels with the block it preceded — its "owning" block).
  4. Re-verify the reconstruction preserves all content. If yes -> write it.
  5. If content still can't be fully accounted for -> DO NOT write. Report the
     unrecoverable lines and leave the file untouched (revert).

Exit code 0 = every file safely handled. Exit code 1 = at least one file could
not be sorted without loss and was left unchanged. Exit code 2 = usage/tool error.

Usage:
  tfsort_safe.py [--dry-run] [--tfsort-bin PATH] FILE [FILE ...]
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter

BLOCK_START = re.compile(r'^\s*(variable|output)\s+"([^"]+)"\s*\{')


def brace_delta(line):
    """Net '{' minus '}' on a line, ignoring braces inside "..." strings and
    after `#` / `//` comments. Handles the common cases (default = "}", URLs with
    #, etc.) that defeat a naive count. Heredocs are not parsed (rare in vars)."""
    depth = 0
    in_str = False
    escaped = False
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        if in_str:
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
            elif c == "#":
                break
            elif c == "/" and i + 1 < n and line[i + 1] == "/":
                break
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
        i += 1
    return depth


def content_counter(text):
    """Multiset of non-blank, right-trimmed lines — what we refuse to lose."""
    return Counter(
        ln.rstrip() for ln in text.splitlines() if ln.strip() != ""
    )


def missing_lines(original, candidate):
    """Non-blank lines present in `original` but not accounted for in `candidate`."""
    diff = content_counter(original) - content_counter(candidate)
    return list(diff.elements())


def parse_units(text):
    """
    Split a .tf file into ordered units.

    Returns (header, units, trailer) where:
      header  : list[str] trivia (comments/blanks) before the first sortable block
      units   : list of {'kind','name','lead':list[str],'body':list[str]}
                'lead' is the contiguous trivia between the previous block and this one
      trailer : list[str] trivia after the last block

    Brace matching is line-based (count of '{' minus '}'). For `terraform fmt`-ed
    files this is reliable; if it mis-parses, the content-preservation gate below
    catches it and we revert rather than risk loss.
    """
    lines = text.split("\n")
    i = 0
    pending = []
    units = []
    header = None  # trivia before the first sortable block; pinned at top, never re-attached
    while i < len(lines):
        m = BLOCK_START.match(lines[i])
        if m:
            if header is None:
                # the first block's leading trivia is the file header; it stays at top
                header = pending
                lead = []
            else:
                lead = pending
            # capture the block body up to its matching closing brace
            body = []
            depth = 0
            while i < len(lines):
                l = lines[i]
                body.append(l)
                depth += brace_delta(l)
                i += 1
                if depth <= 0:
                    break
            units.append({"kind": m.group(1), "name": m.group(2),
                          "lead": lead, "body": body})
            pending = []
        else:
            pending.append(lines[i])
            i += 1
    if header is None:
        # no sortable blocks at all
        header = pending
        trailer = []
    else:
        trailer = pending
    return header, units, trailer


def _strip_outer_blanks(block):
    start = 0
    end = len(block)
    while start < end and block[start].strip() == "":
        start += 1
    while end > start and block[end - 1].strip() == "":
        end -= 1
    return block[start:end]


def reconstruct(original, tfsort_out):
    """
    Build a sorted file using tfsort's chosen ORDER but the ORIGINAL leading
    comments for each block, so comments tfsort dropped are reattached to the
    block they preceded. Returns the reconstructed text.
    """
    orig_header, orig_units, orig_trailer = parse_units(original)
    _, sorted_units, _ = parse_units(tfsort_out)

    lead_by_key = {(u["kind"], u["name"]): u["lead"] for u in orig_units}

    out = []
    header = _strip_outer_blanks(orig_header)
    if header:
        out.extend(header)

    for su in sorted_units:
        key = (su["kind"], su["name"])
        lead = _strip_outer_blanks(lead_by_key.get(key, su["lead"]))
        if out:
            out.append("")  # single blank line separator
        out.extend(lead)
        out.extend(su["body"])

    trailer = _strip_outer_blanks(orig_trailer)
    if trailer:
        out.append("")
        out.extend(trailer)

    return "\n".join(out) + "\n"


def is_structurally_sound(text):
    """Backstop against a reconstruction that preserves every line but is invalid
    HCL (e.g. a brace-in-string mis-parse). Returns True only if the text is sound.

    Uses `terraform fmt` as the authority when available (it parses HCL and exits
    non-zero on a syntax error); otherwise falls back to a brace-balance check on
    each parsed block plus a guard that trivia regions hold only comments/blanks.
    """
    tf = shutil.which("terraform")
    if tf:
        with tempfile.TemporaryDirectory() as td:
            tmp = os.path.join(td, "check.tf")
            with open(tmp, "w") as fh:
                fh.write(text)
            # `fmt` (no -check) reformats valid files and returns 0; a syntax
            # error returns non-zero. We only care about the parse verdict.
            proc = subprocess.run([tf, "fmt", tmp], capture_output=True, text=True)
            return proc.returncode == 0

    header, units, trailer = parse_units(text)
    for u in units:
        if sum(brace_delta(l) for l in u["body"]) != 0:
            return False
        if not u["body"][-1].rstrip().endswith("}"):
            return False
    for region in (header, trailer):
        for ln in region:
            s = ln.strip()
            if s and not (s.startswith("#") or s.startswith("//")):
                return False
    return True


def run_tfsort(tfsort_bin, src_path):
    """Run tfsort on a temp copy of src_path; return the sorted text."""
    with tempfile.TemporaryDirectory() as td:
        tmp = os.path.join(td, "variables.tf")
        shutil.copyfile(src_path, tmp)
        proc = subprocess.run([tfsort_bin, tmp], capture_output=True, text=True)
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip() or "tfsort failed")
        with open(tmp, "r") as fh:
            return fh.read()


def process_file(path, tfsort_bin, dry_run):
    """Returns (status, detail). status in clean|sorted|restored|reverted|error."""
    try:
        with open(path, "r") as fh:
            original = fh.read()
    except OSError as e:
        return "error", str(e)

    try:
        sorted_out = run_tfsort(tfsort_bin, path)
    except Exception as e:  # noqa: BLE001
        return "error", str(e)

    # Path 1: tfsort was lossless.
    if not missing_lines(original, sorted_out):
        if sorted_out == original:
            return "clean", "already sorted"
        if not dry_run:
            with open(path, "w") as fh:
                fh.write(sorted_out)
        return "sorted", "sorted losslessly"

    # Path 2: tfsort lost content -> attempt content-preserving reconstruction.
    dropped = missing_lines(original, sorted_out)
    try:
        rebuilt = reconstruct(original, sorted_out)
    except Exception as e:  # noqa: BLE001
        return "reverted", f"{len(dropped)} line(s) would be lost; reconstruction failed ({e})"

    still_missing = missing_lines(original, rebuilt)
    if not still_missing and is_structurally_sound(rebuilt):
        if not dry_run:
            with open(path, "w") as fh:
                fh.write(rebuilt)
        return "restored", f"recovered {len(dropped)} comment line(s) tfsort would have dropped"

    # Path 3: cannot guarantee a lossless AND valid sort -> leave file untouched.
    if still_missing:
        return "reverted", still_missing
    return "reverted", "reconstruction was not valid HCL"


def main():
    ap = argparse.ArgumentParser(description="Content-preserving tfsort wrapper.")
    ap.add_argument("files", nargs="+", help="Terraform files to sort")
    ap.add_argument("--dry-run", action="store_true",
                    help="report what would happen without writing")
    ap.add_argument("--tfsort-bin", default=shutil.which("tfsort") or "tfsort",
                    help="path to the tfsort binary")
    args = ap.parse_args()

    if not shutil.which(args.tfsort_bin) and not os.path.exists(args.tfsort_bin):
        print(f"error: tfsort not found ({args.tfsort_bin})", file=sys.stderr)
        return 2

    exit_code = 0
    for path in args.files:
        status, detail = process_file(path, args.tfsort_bin, args.dry_run)
        prefix = "[dry-run] " if args.dry_run else ""
        if status == "clean":
            print(f"  ok       {path} — {detail}")
        elif status == "sorted":
            print(f"  {prefix}sorted   {path} — {detail}")
        elif status == "restored":
            print(f"  {prefix}restored {path} — {detail}")
        elif status == "error":
            print(f"  ERROR    {path} — {detail}")
            exit_code = 1
        else:  # reverted
            exit_code = 1
            if isinstance(detail, list):
                print(f"  REVERTED {path} — would lose {len(detail)} line(s); "
                      f"left UNCHANGED. Unrecoverable content:")
                for ln in detail:
                    print(f"             | {ln}")
            else:
                print(f"  REVERTED {path} — {detail}; left UNCHANGED.")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
