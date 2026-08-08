# walker theme for the waybarclaude picker

Optional add-on. Installs and removes on its own, separately from waybarclaude
itself, because it is the one piece that has to edit a config file you own.

```sh
./install.sh        # install
./install.sh --check
./uninstall.sh      # remove, restoring walker's config
```

## What it changes about the picker

Opaque panel instead of transparent, so rows stay readable over a busy screen.
Compact monospace rows, a hairline under the prompt, a rounded selection band, no
keybind or quick-activation hints. Rows waiting on you get an inset amber accent
bar; rows still working dim back.

Your normal launcher is untouched — the picker asks for this theme per-invocation
with `walker --theme waybarclaude`.

## Why installing it needs one line of walker's config

Walker looks for themes in `XDG_CONFIG_DIRS` and in the single
`additional_theme_location` from its config, and resolves them in the **service**
process — so a per-invocation environment variable cannot inject one, and
`additional_theme_location` takes one path, not a list. So the installer:

1. puts this theme in `~/.config/walker/themes/` — yours, untouched by distro updates
2. gives every theme in your current location a **shim** there, so they keep resolving
3. points `additional_theme_location` at `~/.config/walker/themes/`, backing the file up first

Step 3 is the only file of yours that changes, and it fails safe: if anything
later resets it — `omarchy refresh walker`, say — walker falls back to its own
default theme and the picker keeps working. Re-run `./install.sh` to reapply.

**Shims, not symlinks.** A theme whose `style.css` imports its colours by
*relative* path (omarchy's does, with seven `../`) would resolve that path from a
symlink's depth instead of its real one. The import fails, its colours end up
undefined, and its window renders transparent. Each shim is therefore a
`style.css` that imports the original by absolute path, so the original's own
relative import still resolves from where it actually lives — and it keeps
tracking upstream.

## Why the accent bar instead of amber text

Walker's dmenu mode sets only an item's **text** — no icon field, no state class,
and no pango markup (all three checked against the 2.16.2 source). One row is one
label, so CSS cannot colour a row's icon, title and path separately the way a
mockup can. Tinting the whole row amber was too loud, so waiting rows get an
inset accent bar and keep readable text.

What walker *does* allow is re-reading the theme stylesheet on every invocation,
so the picker writes `rows.css` immediately before launching with the current
counts. Tune it from `~/.config/waybarclaude/config`:

```sh
COLOR_WAITING='#e0af68'   # the accent
DIM_RUNNING='0.55'        # opacity for rows still working
WALKER_THEME='waybarclaude'   # set to '' to stop asking for this theme
```

Colours otherwise come from an `@import` of your desktop theme's walker palette
when one exists, so switching desktop themes recolours the picker too.

## Caveat

Row emphasis uses `nth-child`, which counts **realised** widgets. If the list ever
grows long enough to scroll, the accent can drift from the intended rows. Fine at
normal queue sizes.
