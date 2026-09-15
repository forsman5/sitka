---
name: show-me
description: Launch a real, visible Godot window (a specific scene, or the game's main menu) so the user can look at or interact with Sitka directly on their own machine, instead of a description. Smoke-tests headlessly first so a broken scene never gets shown. Use whenever the user asks to "show me", "open it up", "let me see it", "launch the dashboard", "run the scene", "pull up the editor", or similar.
---

# show-me (Sitka)

Puts an actual, running Godot window in front of the user — not a
screenshot, not a description, the real thing, on their own screen. This
is a project-tracked skill: the launch mechanics below are specific to
this repo (its scenes, its known pre-existing noise, its worktree
convention). If you're building an equivalent for a different project or
engine, treat this as a template, not something to import wholesale.

## 0. Godot executable location (env vars, with fallbacks for this machine)

```bash
GUI_EXE="${SITKA_GODOT_EXE:-/c/Users/jrfor/OneDrive/Desktop/gamedev/Godot_v4.6.2-stable_win64.exe}"
CONSOLE_EXE="${SITKA_GODOT_CONSOLE_EXE:-/c/Users/jrfor/OneDrive/Desktop/gamedev/Godot_v4.6.2-stable_win64_console.exe}"
```

- `SITKA_GODOT_EXE` — the GUI build, used for the actual window you show
  the user. Silent on stdout/stderr.
- `SITKA_GODOT_CONSOLE_EXE` — same engine, console build. Required for the
  headless smoke test below (`--headless` on the plain GUI exe produces no
  visible output at all, so you can't tell if anything went wrong).

If neither var is set and the fallback path above no longer exists (e.g. a
Godot version bump, or a different machine), search `~/Downloads` for an
unextracted `Godot_v*.zip` and extract it to a scratch/tmp directory rather
than the Downloads folder itself, or ask the user where their binary is.
Once you find it working, you don't need to re-search for the rest of the
session.

## 1. Know what you're launching

Reachable directly, or via the main menu's buttons:

| Scene | Path | Main menu button |
| --- | --- | --- |
| Main menu (default scene) | `res://scenes/ui/main_menu.tscn` | -- |
| RTS game world | `res://scenes/world/world.tscn` | "Start" (after placing a capital) |
| Pooled valley economy dashboard | `res://scenes/sim/dashboard.tscn` | "Single Valley Simulation" / "Large Valleys Simulation" |
| H1 household-economy dashboard | `res://scenes/sim/he_dashboard.tscn` | "Household Economy Simulation" |
| River valley view | `res://scenes/valley/river_valley.tscn` | "River Valley View" |

Prefer launching the specific scene directly (fastest, no clicking
required) unless the user specifically wants the normal game entry point.

**Always launch against the directory you're actually working in** (a
worktree under `.claude/worktrees/<name>`, or the main checkout) --
`--path "$(pwd)"` from wherever your edits live, not a hardcoded path to
one specific checkout. Showing the user the wrong worktree's version of a
scene is worse than not showing them anything.

## 2. Headless smoke-test BEFORE showing the user anything

Never launch the GUI cold against a scene you just touched.

```bash
"$CONSOLE_EXE" --headless --path "$(pwd)" res://path/to/scene.tscn > /tmp/show-me-smoke.log 2>&1
```

Run with `run_in_background: true`, `sleep 9`, then read the log (a scene
with no `quit()` call runs forever even headless -- you're not waiting for
completion, just giving it time to hit any load-time parse/script error).

**Known, pre-existing, unrelated noise** -- do not treat this as a
failure, and do not re-investigate it every time:

```
SCRIPT ERROR: Parse Error: Could not find type "IslandEconomy" in the current scope.
   at: GDScript::reload (res://scripts/global/game_state.gd:24)
ERROR: Failed to load script "res://scripts/global/game_state.gd" with error "Parse error".
ERROR: Failed to instantiate an autoload, script 'res://scripts/global/game_state.gd' does not inherit from 'Node'.
```

This fires whenever ANY scene or `--script` harness other than the actual
game is launched (a broken `IslandEconomy` type reference in the
`GameState` autoload, unrelated to simulation/dashboard work) -- it happens
on the pooled valley dashboard, the H1 dashboard, and every headless test
harness alike. Any OTHER `SCRIPT ERROR`/`Parse Error`/`ERROR:` line is real
and must be fixed and re-tested before step 4.

## 3. Clean up any previous instance from this session

Before relaunching (e.g. after a code change):

```bash
tasklist //FI "IMAGENAME eq Godot_v4.6.2-stable_win64_console.exe"
tasklist //FI "IMAGENAME eq Godot_v4.6.2-stable_win64.exe"
taskkill //PID <pid> //F
```

Always safe to kill: the console smoke-test process itself (you always own
it), and a GUI window YOU opened earlier via this same skill when you're
relaunching to show an update. **Never kill a Godot GUI process you didn't
launch, or one the user might be looking at right now, without checking
first** -- if a `tasklist` result is ambiguous about whose window it is,
ask, or launch alongside it instead of closing anything.

## 4. Launch the GUI, detached

```bash
"$GUI_EXE" --path "$(pwd)" res://path/to/scene.tscn &
disown
```

Needs `dangerouslyDisableSandbox: true` on the Bash call -- a real window
needs actual desktop access, which the sandbox blocks by default. Expected
and fine for this specific launch; not a green light to disable the
sandbox for anything else.

For the main menu, drop the scene argument entirely (it's the project's
`run/main_scene`). For the editor instead of running anything, add
`--editor` in place of the scene path.

## 5. Tell the user, briefly

One or two sentences: what window just opened, what they're looking at.
The point of this skill is that they can look for themselves -- don't
narrate the contents back to them at length.

## Extending this skill

When a new "put the real thing in front of the user" need shows up in this
repo (a screenshot, a specific save state, something in the actual RTS
world rather than a sim dashboard), grow this file rather than
re-improvising the launch dance in a session. If the same need comes up
across OTHER projects (not just Sitka), that's a candidate for a separate,
genuinely generic skill at the user level (`~/.claude/skills/`) instead --
keep this one specific to what's actually true here.
