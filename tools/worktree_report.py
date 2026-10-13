#!/usr/bin/env python3
"""Report on every git worktree of a repository: size, age, dirtiness, and
whether removing it would lose anything.

Stdlib only; works on any repo (Windows, macOS, Linux, WSL). Worktrees are
discovered through `git worktree list`, so Claude (.claude/worktrees), Codex,
manual (.worktrees) and any other layout are all handled. The "source" column
is a best-effort label derived from the path / branch name.

Classification (first match wins):
  ACTIVE    locked by a live session, or a file was edited within --active-hours
  DIRTY     uncommitted changes (modified or untracked files) or an op in progress
  UNPUSHED  clean, but has commits that exist on no remote and no merged PR
  SAFE      clean, nothing unique to lose -> candidate for deletion
  MAIN      the primary checkout (never a deletion candidate)

Examples:
  python tools/worktree_report.py                 # table + summary
  python tools/worktree_report.py -v              # also list what you'd lose
  python tools/worktree_report.py --fetch         # refresh remotes first
  python tools/worktree_report.py --json          # machine-readable
  python tools/worktree_report.py --print-cleanup # `git worktree remove` for SAFE
Nothing is ever deleted by this script.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass, field
from pathlib import Path

STATES = ["ACTIVE", "DIRTY", "UNPUSHED", "SAFE", "MAIN"]
SKIP_DIRS = {".git"}  # a worktree's .git is a file; nested .git dirs are noise


# ---------------------------------------------------------------- git helpers
def git(path: str | Path, *args: str, check: bool = False, timeout: int = 120) -> str:
    """Run git in `path`; return stdout ('' on failure unless check)."""
    try:
        r = subprocess.run(
            ["git", "-C", str(path), *args],
            capture_output=True, text=True, timeout=timeout,
            encoding="utf-8", errors="replace",
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        if check:
            raise RuntimeError(f"git {' '.join(args)}: {e}")
        return ""
    if r.returncode != 0:
        if check:
            raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip()}")
        return ""
    return r.stdout


def translate_path(p: str) -> str:
    """Map a Windows-style path (C:/x) to /mnt/c/x when running under WSL/posix,
    so a repo created by Windows git can still be inspected from WSL."""
    if os.name != "nt" and re.match(r"^[A-Za-z]:[/\\]", p):
        return f"/mnt/{p[0].lower()}/" + p[3:].replace("\\", "/")
    return p


@dataclass
class Worktree:
    path: str
    head: str = ""
    branch: str = ""          # short name, '' when detached
    is_main: bool = False
    locked: bool = False
    lock_reason: str = ""
    prunable: bool = False
    exists: bool = True
    source: str = "other"
    # filled by inspect()
    size_bytes: int = 0
    files: int = 0
    last_edit: float = 0.0    # epoch seconds, 0 = unknown
    modified: int = 0
    untracked: int = 0
    in_progress: str = ""     # rebase/merge/cherry-pick/bisect
    local_only_commits: int = 0
    remote: str = ""          # pushed / ahead N / unpushed N / merged / detached
    pr_state: str = ""        # OPEN / MERGED / CLOSED / ''
    state: str = ""
    reason: str = ""
    ignored_changes: int = 0  # untracked files matching --ignore (not counted dirty)
    changes: list[str] = field(default_factory=list)
    unique_commits: list[str] = field(default_factory=list)


def list_worktrees(repo: Path) -> list[Worktree]:
    out = git(repo, "worktree", "list", "--porcelain", check=True)
    wts: list[Worktree] = []
    cur: Worktree | None = None
    for line in out.splitlines() + [""]:
        if not line.strip():
            if cur:
                wts.append(cur)
            cur = None
            continue
        key, _, val = line.partition(" ")
        if key == "worktree":
            cur = Worktree(path=val)
        elif cur is None:
            continue
        elif key == "HEAD":
            cur.head = val
        elif key == "branch":
            cur.branch = val.removeprefix("refs/heads/")
        elif key == "locked":
            cur.locked, cur.lock_reason = True, val
        elif key == "prunable":
            cur.prunable = True
    if wts:
        wts[0].is_main = True  # git always lists the main worktree first
    for w in wts:
        w.path = translate_path(w.path)
        w.exists = os.path.isdir(w.path)
        w.source = classify_source(w)
    return wts


def classify_source(w: Worktree) -> str:
    p = w.path.replace("\\", "/").lower()
    if w.is_main:
        return "main"
    if "/.claude/worktrees/" in p:
        return "claude"
    if "/.codex/" in p or "/codex/worktrees/" in p or w.branch.startswith("codex/"):
        return "codex"
    if "/.worktrees/" in p or "/worktrees/" in p:
        return "manual"
    return "other"


# ------------------------------------------------------------ per-worktree work
def scan_tree(root: str, exclude: set[str]) -> tuple[int, int, float]:
    """(total bytes, file count, newest mtime) without following symlinks.
    `exclude` holds normalized paths of other worktrees nested inside `root`
    (e.g. .claude/worktrees/* inside the main checkout) so they aren't
    double-counted."""
    total = files = 0
    newest = 0.0
    stack = [root]
    while stack:
        d = stack.pop()
        try:
            with os.scandir(d) as it:
                for e in it:
                    try:
                        if e.is_dir(follow_symlinks=False):
                            if e.name not in SKIP_DIRS and norm(e.path) not in exclude:
                                stack.append(e.path)
                        else:
                            st = e.stat(follow_symlinks=False)
                            total += st.st_size
                            files += 1
                            if st.st_mtime > newest:
                                newest = st.st_mtime
                    except OSError:
                        continue
        except OSError:
            continue
    return total, files, newest


def norm(p: str) -> str:
    return os.path.normcase(os.path.normpath(p))


def op_in_progress(path: str) -> str:
    gd = git(path, "rev-parse", "--absolute-git-dir").strip()
    if not gd:
        return ""
    for name, label in [("rebase-merge", "rebase"), ("rebase-apply", "rebase"),
                        ("MERGE_HEAD", "merge"), ("CHERRY_PICK_HEAD", "cherry-pick"),
                        ("REVERT_HEAD", "revert"), ("BISECT_LOG", "bisect")]:
        if os.path.exists(os.path.join(gd, name)):
            return label
    return ""


def inspect(w: Worktree, remote_branches: set[str], pr_by_branch: dict[str, str],
            active_secs: float, now: float, nested: set[str],
            ignore_globs: list[str]) -> Worktree:
    if not w.exists:
        w.state, w.reason = "SAFE", "directory missing (prunable)"
        w.remote = "n/a"
        return w

    me = norm(w.path)
    exclude = {n for n in nested if n != me and n.startswith(me + os.sep)}
    w.size_bytes, w.files, w.last_edit = scan_tree(w.path, exclude)

    ignorable = 0
    for line in git(w.path, "status", "--porcelain=v1", "--untracked-files=normal").splitlines():
        fname = line[3:].strip().strip('"')
        if line.startswith("??") and any(
                fnmatch.fnmatch(fname, g) or fnmatch.fnmatch(os.path.basename(fname), g)
                for g in ignore_globs):
            ignorable += 1  # regenerable noise (e.g. Godot .uid files)
            continue
        if line.startswith("??"):
            w.untracked += 1
        else:
            w.modified += 1
        w.changes.append(line)
    w.ignored_changes = ignorable
    w.in_progress = op_in_progress(w.path)

    # Commits reachable from HEAD but from no remote-tracking ref.
    w.unique_commits = git(w.path, "log", "--format=%h %s", "HEAD", "--not", "--remotes").splitlines()
    w.local_only_commits = len(w.unique_commits)

    if not w.branch:
        w.remote = "detached"
    else:
        on_remote = any(rb.split("/", 1)[-1] == w.branch for rb in remote_branches)
        if w.local_only_commits == 0:
            w.remote = "pushed" if on_remote else "merged"
        elif on_remote:
            w.remote = f"ahead {w.local_only_commits}"
        else:
            w.remote = f"unpushed {w.local_only_commits}"
        w.pr_state = pr_by_branch.get(w.branch, "")

    # --- classify
    age = now - w.last_edit if w.last_edit else float("inf")
    if w.is_main:
        w.state, w.reason = "MAIN", "primary checkout"
    elif w.locked or age <= active_secs:
        w.state = "ACTIVE"
        w.reason = ("locked: " + w.lock_reason) if w.locked else "edited recently"
    elif w.modified or w.untracked or w.in_progress:
        w.state = "DIRTY"
        bits = []
        if w.modified:
            bits.append(f"{w.modified} modified")
        if w.untracked:
            bits.append(f"{w.untracked} untracked")
        if w.in_progress:
            bits.append(f"{w.in_progress} in progress")
        w.reason = ", ".join(bits)
    elif w.local_only_commits and w.pr_state != "MERGED":
        w.state = "UNPUSHED"
        w.reason = f"{w.local_only_commits} commit(s) on no remote"
    else:
        w.state = "SAFE"
        w.reason = "PR merged" if w.local_only_commits else "nothing unique"
    if w.state == "ACTIVE":  # still show what deleting it would risk
        flags = []
        if w.modified or w.untracked:
            flags.append(f"dirty {w.modified}M/{w.untracked}?")
        if w.local_only_commits and w.pr_state != "MERGED":
            flags.append(f"{w.local_only_commits} unpushed")
        if flags:
            w.reason += " | " + ", ".join(flags)
    if w.ignored_changes and w.state != "DIRTY":
        w.reason += f" (+{w.ignored_changes} ignorable)"
    return w


# -------------------------------------------------------------------- output
def human_size(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n} B"


def human_age(secs: float) -> str:
    if secs == float("inf"):
        return "?"
    if secs < 3600:
        return f"{int(secs // 60)}m"
    if secs < 86400:
        return f"{int(secs // 3600)}h"
    return f"{int(secs // 86400)}d"


COLORS = {"ACTIVE": "32", "DIRTY": "31", "UNPUSHED": "33", "SAFE": "36", "MAIN": "90"}


def render(wts: list[Worktree], repo: Path, now: float, color: bool, verbose: bool) -> str:
    def c(state: str, text: str) -> str:
        return f"\033[{COLORS[state]}m{text}\033[0m" if color else text

    order = {s: i for i, s in enumerate(STATES)}
    # within a state: newest first
    rows = sorted(wts, key=lambda w: (order[w.state], -(w.last_edit or 0)))

    repo_str = str(repo)
    def rel(p: str) -> str:
        pp = p.replace("\\", "/")
        base = repo_str.replace("\\", "/").rstrip("/") + "/"
        return pp[len(base):] if pp.startswith(base) else (pp if not w_main(p) else ".")
    main_path = next((w.path for w in wts if w.is_main), "")
    def w_main(p: str) -> bool:
        return p == main_path

    hdr = ["STATE", "SRC", "WORKTREE", "BRANCH", "SIZE", "AGE", "REMOTE", "PR", "NOTES"]
    table = []
    for w in rows:
        table.append([
            w.state, w.source, rel(w.path) if not w.is_main else ". (main)",
            w.branch or "(detached)", human_size(w.size_bytes),
            human_age(now - w.last_edit) if w.last_edit else "?",
            w.remote, w.pr_state.lower(), w.reason,
        ])
    widths = [max(len(hdr[i]), *(len(r[i]) for r in table)) if table else len(hdr[i])
              for i in range(len(hdr))]
    lines = ["  ".join(h.ljust(widths[i]) for i, h in enumerate(hdr))]
    for r in table:
        cells = [r[i].ljust(widths[i]) for i in range(len(hdr))]
        cells[0] = c(r[0], cells[0])
        lines.append("  ".join(cells).rstrip())

    # summary
    lines += ["", f"{len(wts)} worktrees for {repo.name}"]
    by_src: dict[str, int] = {}
    for w in wts:
        by_src[w.source] = by_src.get(w.source, 0) + 1
    lines.append("  by source: " + ", ".join(f"{k}={v}" for k, v in sorted(by_src.items())))
    total = sum(w.size_bytes for w in wts)
    for s in STATES:
        group = [w for w in wts if w.state == s]
        if not group:
            continue
        size = sum(w.size_bytes for w in group)
        extra = "  <- reclaimable" if s == "SAFE" else ""
        lines.append(c(s, f"  {s:<9}") + f" {len(group):>3}  {human_size(size):>10}{extra}")
    lines.append(f"  {'TOTAL':<9} {len(wts):>3}  {human_size(total):>10}")

    if verbose:
        for s in ("DIRTY", "UNPUSHED", "ACTIVE"):
            for w in (x for x in rows if x.state == s and (x.changes or x.unique_commits)):
                lines += ["", c(s, f"{s}: {rel(w.path)} [{w.branch or 'detached'}]")]
                for ch in w.changes[:10]:
                    lines.append(f"    {ch}")
                if len(w.changes) > 10:
                    lines.append(f"    ... +{len(w.changes) - 10} more")
                for cm in w.unique_commits[:5]:
                    lines.append(f"    commit {cm}")
                if len(w.unique_commits) > 5:
                    lines.append(f"    ... +{len(w.unique_commits) - 5} more commits")
    return "\n".join(lines)


# ---------------------------------------------------------------------- main
def fetch_pr_states(repo: Path) -> dict[str, str]:
    """branch -> OPEN/MERGED/CLOSED via one `gh` call; {} if gh unavailable."""
    try:
        r = subprocess.run(
            ["gh", "pr", "list", "--state", "all", "--limit", "1000",
             "--json", "headRefName,state"],
            capture_output=True, text=True, timeout=60, cwd=str(repo),
            encoding="utf-8", errors="replace",
        )
        if r.returncode != 0:
            return {}
        out: dict[str, str] = {}
        rank = {"OPEN": 3, "MERGED": 2, "CLOSED": 1}
        for pr in json.loads(r.stdout):
            b, s = pr["headRefName"], pr["state"]
            if rank.get(s, 0) > rank.get(out.get(b, ""), 0):
                out[b] = s
        return out
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return {}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Report on a repo's git worktrees.",
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("Examples:")[1] if "Examples:" in __doc__ else "")
    ap.add_argument("repo", nargs="?", default=".", help="any path inside the repo (default: cwd)")
    ap.add_argument("--fetch", action="store_true", help="run `git fetch --prune` first")
    ap.add_argument("--no-prs", action="store_true", help="skip GitHub PR lookup via gh")
    ap.add_argument("--active-hours", type=float, default=24.0,
                    help="edited within N hours counts as ACTIVE (default 24)")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="list changed files / unique commits for non-SAFE worktrees")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of a table")
    ap.add_argument("--print-cleanup", action="store_true",
                    help="print `git worktree remove` commands for SAFE worktrees (does not run them)")
    ap.add_argument("--ignore", action="append", default=None, metavar="GLOB",
                    help="untracked files matching this glob don't count as dirty "
                         "(repeatable; default: *.uid)")
    ap.add_argument("--jobs", type=int, default=8, help="parallel workers (default 8)")
    ap.add_argument("--no-color", action="store_true")
    args = ap.parse_args(argv)

    start = translate_path(args.repo)
    top = git(start, "rev-parse", "--show-toplevel").strip()
    if not top:
        print(f"error: {args.repo} is not inside a git repository", file=sys.stderr)
        return 2
    # Anchor on the main worktree regardless of where we were invoked from.
    common = git(start, "rev-parse", "--path-format=absolute", "--git-common-dir").strip()
    repo = Path(translate_path(common)).parent if common.endswith(".git") else Path(top)

    if args.fetch:
        print("fetching...", file=sys.stderr)
        git(repo, "fetch", "--prune", "--quiet")

    wts = list_worktrees(repo)
    remote_branches = set(git(repo, "for-each-ref", "--format=%(refname:short)",
                              "refs/remotes").split())
    prs = {} if args.no_prs else fetch_pr_states(repo)
    now = time.time()
    nested = {norm(w.path) for w in wts}
    ignore_globs = args.ignore if args.ignore is not None else ["*.uid"]
    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as ex:
        list(ex.map(lambda w: inspect(w, remote_branches, prs, args.active_hours * 3600, now,
                                     nested, ignore_globs), wts))

    if args.json:
        print(json.dumps([asdict(w) for w in wts], indent=2))
        return 0
    if args.print_cleanup:
        for w in wts:
            if w.state == "SAFE":
                print(f'git -C "{repo}" worktree remove --force "{w.path}"')
        return 0

    color = sys.stdout.isatty() and not args.no_color and "NO_COLOR" not in os.environ
    if color and os.name == "nt":
        os.system("")  # enable ANSI on legacy Windows consoles
    print(render(wts, repo, now, color, args.verbose))
    if args.no_prs is False and not prs:
        print("\n(note: PR lookup unavailable - gh missing/unauthenticated; "
              "squash-merged branches may show as UNPUSHED)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
