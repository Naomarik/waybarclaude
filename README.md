# waybarclaude

**You have eleven Claude Code sessions open. Which one wants you next?**

A waybar module that answers that at a glance, and a picker that takes you
straight there.

![waybarclaude: the bar module and the session picker](docs/demo.svg)

The bar shows two numbers: **sessions still working**, and **sessions that
finished and are waiting on you**. It goes amber the moment something needs you,
and disappears entirely when nothing does.

Click it and you get your launcher in dmenu mode, listing the waiting sessions
first and the running ones underneath — each labelled with the actual title
Claude gave that session, so you're choosing between *"Fix flaky auth test"* and
*"Port parser to streaming"*, not between eleven identical terminal windows.

Pick one: it focuses that window and drops the entry.

## Why you'd want this

Claude Code already fires a desktop notification when a session finishes, and
clicking it focuses the right window. That works beautifully for one session.

At ten sessions it stops working, because notifications are **transient**. You
step away, six of them finish, the toasts expire, and now you're alt-tabbing
through a wall of terminals reading each one to figure out which still needs you.

This turns those notifications into a **queue that persists until you actually
deal with each session** — and a running count so you know how much is still
in flight.

## What clears an entry

Everything you'd expect, so the queue never lies to you:

- you pick it from the menu
- **you visit that window any other way** — the notification, a keybind, alt-tab, the mouse
- the session starts working again
- the session exits, or its window closes — or is killed outright, leaving its
  roster file behind
- a turn that finishes while you're *already looking at that window* never queues at all

For a session in a tmux pane the same rules apply per **pane**: only the pane you
can actually see counts as visited, and a turn that ends in the pane you are
watching never queues.

## Install

```sh
git clone https://github.com/naomarik/waybarclaude
cd waybarclaude
./install.sh --wire
```

`--wire` makes the two waybar edits for you, with backups. Leave it off and it
prints them instead. Then reload waybar and check:

```sh
claude-queue doctor
```

The installer writes only inside your home directory, never uses sudo, and backs
up anything it would overwrite that it didn't write itself.

<details>
<summary><b>What gets installed, and the two edits that can't be automated</b></summary>

| Path | What |
|---|---|
| `~/.local/bin/claude-queue` | the whole tool, one script |
| `~/.config/waybar/claude-queue.jsonc` | module definition, pulled in via waybar's `include` |
| `~/.config/waybar/claude-queue.css` | styling, pulled in via CSS `@import` |
| `~/.config/systemd/user/waybarclaude.service` | the event daemon |
| `~/.config/hypr/waybarclaude.conf` | `exec-once` fallback for non-systemd setups |

waybar can define a module from an included file but **cannot append to a
`modules-*` array** from one, so these two are yours (or use `--wire`):

```jsonc
// ~/.config/waybar/config.jsonc
"include": ["~/.config/waybar/claude-queue.jsonc"],
"modules-right": [ ..., "custom/claude-queue" ],
```

```css
/* first line of ~/.config/waybar/style.css */
@import "claude-queue.css";
```

**Tip:** put the module at the **end of `modules-left`**, after your workspace
list. It hides itself when there's nothing to report, and at that position
appearing and disappearing shifts nothing else on the bar.

Three of the installed files ship with an `@BIN@` placeholder that the installer
replaces with the real path to `claude-queue`, so the module and the systemd unit
don't depend on waybar or systemd inheriting your `PATH`. Substitute it yourself
if you copy them by hand.

</details>

## A nicer picker (optional)

Walker's default look leans transparent with large rows, which gets hard to read
over a busy screen. There is a small theme for **the picker only** — opaque panel,
compact monospace rows, and a hairline under the prompt, with the rows still
working dimmed back:

```sh
./walker-theme/install.sh
```

It installs and removes **separately** from waybarclaude itself, because it is the
one piece that has to edit a config file you own (walker's). Your normal launcher
keeps the theme it already uses. See [walker-theme/README.md](walker-theme/README.md)
for what it changes, why that one line is needed, and how to tune the colours.

```sh
./walker-theme/uninstall.sh    # restores walker's config
```

## Requirements

- **Hyprland** — the compositor-specific code is four functions at the top of
  `bin/claude-queue`; a Sway port would reimplement those against `swaymsg`
- **waybar**, bash 5, `jq`, `socat`, `inotify-tools`
- a dmenu-capable launcher — `walker`, `fuzzel`, `rofi`, `wofi`, `tofi`,
  `bemenu` or `dmenu`, auto-detected in that order
- a Nerd Font in your bar, for the default icons
- `tmux` **only if you run sessions in panes** — it is what makes those rows
  clickable, and it is never invoked otherwise

```sh
# Arch
sudo pacman -S --needed jq socat inotify-tools
# Debian/Ubuntu
sudo apt install jq socat inotify-tools
```

## How it works

**No Claude Code hooks.** Claude Code keeps a roster at
`~/.claude/sessions/<pid>.json` and rewrites a session's file on every status
transition (`busy` ↔ `idle`). An inotify watch on that one directory is enough to
know when every turn starts and ends.

That matters for safety: this tool never writes under `~/.claude`, never signals a
session, and never touches a session's messaging socket. It is **read-only
observation**, so it cannot disturb a session you have running.

### The interesting part: which window is this session in?

Terminals like Ghostty run every window in **one process**. All eleven of your
windows report the same PID, so there is no way to get from a session to its
window through the process tree. Three mechanisms cover it:

**1. Transcript title match (primary).** Claude records the terminal title it set
for a session as `aiTitle` in the session transcript. The live window title is
that same string behind a status marker — `✳ Fix flaky auth test` when idle, a
braille spinner while busy. Matching the two identifies the window *exactly*, and
works for sessions that were already running long before the daemon started.

**2. Focus at turn start (fallback).** If a session has no title yet, the window
focused at the instant a turn begins is its window — because you just pressed
enter in it.

A session lives in one window for its whole life, so the first binding wins, and a
window already claimed by another live session is never stolen.

**3. tmux panes.** A session in a pane has no window of its own: its process tree
hangs off the detached tmux server, and its terminal is titled after tmux rather
than the session, so neither mechanism above finds anything. Two hops close the
gap — the session's PID identifies its pane, and the pane's tmux session
identifies the attached client, whose process tree *does* lead to a real window.
Clicking such a row selects the pane and raises that window.

This matters as soon as you run several sessions in one terminal: without it, a
whole tmux window's worth of sessions queue up as rows that go nowhere. tmux is
optional, and none of this runs unless a session's ancestry actually contains a
tmux server — a machine without tmux never invokes it.

### Nothing in the queue is stale

Every row is checked against reality rather than against the record that created
it:

- **Liveness comes from `/proc`, not from the roster file.** Claude removes a
  session's file when it exits, but a session that is *killed* never gets the
  chance, so the file outlives the process. The bar stops counting such a session
  the moment it next refreshes, and `sync` prunes the record.
- **The picker re-locates every row before it draws it.** A window can be
  reassigned; a pane can move, or lose the client that was showing it.
- **A row that genuinely has nowhere to go says so.** It stays in the queue and
  tells you it could not find a window, instead of silently vanishing as though
  the click had worked.

## Configuration

Copy `~/.config/waybarclaude/config.example` to
`~/.config/waybarclaude/config`. It's sourced by bash; set only what you want to
change.

| Key | Default | Notes |
|---|---|---|
| `TERMINAL_CLASSES` | ghostty, alacritty, kitty, foot, … | window app-ids that may host a session |
| `WAYBAR_SIGNAL` | `14` | must match `signal` in the `.jsonc`, and not collide with your other modules |
| `ICON_RUNNING` / `ICON_WAITING` | `󰔟` / `󰂚` | Nerd Font glyphs — plain Unicode like `✳` often has no coverage in bar fonts |
| `MENU` | auto | force a launcher by name, or give a full command line |
| `MENU_WIDTH`, `MENU_LINES`, `MENU_PROMPT` | | picker appearance |
| `CLAUDE_DIR` | `~/.claude` | |

Find your terminal's class with
`hyprctl clients -j | jq -r '.[].class' | sort -u`.

## Commands

```
claude-queue status     waybar JSON (what the module runs)
claude-queue menu       the picker
claude-queue watch      the event daemon (systemd runs this)
claude-queue list       the queue and the window bindings, panes included
claude-queue doctor     check dependencies, wiring, and what is reachable
claude-queue clear      empty the queue
claude-queue unbind ID  forget a session's window so it can be re-learned
claude-queue sync       prune dead sessions and closed windows
```

## What it costs

Four processes, every one of them **blocked on a read**. Nothing polls, and there
is no timer anywhere: the shell, a supervisor subshell, `socat` on Hyprland's
event socket, and `inotifywait` on the roster directory.

Measured across the whole process tree over 60s of normal desktop use:

| | |
|---|---|
| CPU | **0 jiffies — unmeasurable** |
| RSS | 19.5 MiB combined, mostly shared bash text |

That was taken with 14 sessions live, 9 of them in tmux panes.

Hyprland re-emits focus events constantly, so the daemon *does* wake often, but
each wake is shell string operations against a one-line cache file. A subprocess
is forked only when the queue actually changes. Deciding whether a session is
alive, and whether it lives in a tmux pane, is `/proc` read with shell builtins —
no fork either, which is why tmux support costs nothing until a pane session
actually finishes a turn. The bar module is signal-driven
(`interval: once` + `signal`), so it runs when something happens rather than on a
timer.

## Limitations

- **One session per window, unless it's tmux.** Sessions in tmux panes are
  resolved individually. Sessions in a terminal's own tabs or splits are not —
  those collapse to one address, so focusing the window works and picking the
  right tab doesn't.
- A pane in a tmux session that **no window is attached to** can be selected but
  not raised, because there is nothing on screen to raise. The picker tells you
  so; attach the tmux session and the row starts working.
- **Hyprland only** for now.
- A session that has never produced a title, was never focused at a turn start,
  and isn't in a pane will queue without a known window. It still shows and still
  counts, and picking it says it could not find a window rather than pretending it
  worked. `claude-queue list` shows which rows are in that state.
- The roster is Claude Code's internal state, not a documented API. It's been
  stable in practice, but a future version could change it — `claude-queue
  doctor` will tell you if it stops parsing.

## Uninstall

```sh
./uninstall.sh              # shows the plan, asks, then removes
./uninstall.sh --dry-run    # just show the plan
./uninstall.sh --purge      # also delete the queue state
```

The walker theme is a separate package, so this leaves it alone and says so; use
`./walker-theme/uninstall.sh` for that.

Deliberately paranoid, because uninstallers that guess are how people lose
configs. It touches only an explicit list of paths, refuses to delete any file
that doesn't carry the `waybarclaude:managed` marker, skips symlinks and anything
outside `$HOME`, backs up your waybar config before un-wiring it, and uses
`rmdir` rather than `rm -rf` on the state directory — so anything unexpected in
there **blocks** the deletion instead of being destroyed.

Verified by installing into a throwaway tree and tearing it down: afterwards the
waybar config was byte-identical to the original.

## Tests

```sh
./test/e2e.sh
```

45 assertions covering every transition, tmux panes, leftover roster files, the
picker, and idle CPU. It runs the real daemon against a scratch roster and a
**fake compositor event socket**, so focus events are deterministic and nothing
touches your real `~/.claude` or your real queue. `hyprctl` and `notify-send` are
shimmed, so the suite can never steal your focus or pop a toast at you. Needs
Hyprland running with at least three windows of the same class open.

## License

MIT
