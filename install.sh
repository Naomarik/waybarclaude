#!/usr/bin/env bash
# waybarclaude installer.
#
# Installs into your home directory only. Never uses sudo, never writes outside
# $PREFIX and $XDG_CONFIG_HOME, and backs up any file it would overwrite that it
# did not write itself.
#
#   ./install.sh                 install, then print the two wiring edits
#   ./install.sh --wire          also make those edits for you (with backups)
#   ./install.sh --check         report what is installed and wired, change nothing
#   ./install.sh --no-service    skip the systemd user unit
#   ./install.sh --walker-theme  style the picker (edits walker/config.toml)
#   ./install.sh --prefix DIR    default $HOME/.local

set -euo pipefail

REPO=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)
MARKER='waybarclaude:managed'

PREFIX="${PREFIX:-$HOME/.local}"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
WAYBAR_DIR="$CFG/waybar"
SYSTEMD_DIR="$CFG/systemd/user"
HYPR_DIR="$CFG/hypr"
WBC_CFG_DIR="$CFG/waybarclaude"

DO_WIRE=0 DO_SERVICE=1 CHECK_ONLY=0 POSITION=right DO_WALKER_THEME=0

die() {
  printf '\033[31merror\033[0m %s\n' "$*" >&2
  exit 1
}
info() { printf '  %s\n' "$*"; }
head1() { printf '\n\033[1m%s\033[0m\n' "$*"; }

while (($#)); do
  case $1 in
  --wire) DO_WIRE=1 ;;
  --walker-theme) DO_WALKER_THEME=1 ;;
  --no-service) DO_SERVICE=0 ;;
  --check) CHECK_ONLY=1 ;;
  --position)
    POSITION=${2:?left or right}
    shift
    ;;
  --prefix)
    PREFIX=${2:?directory}
    shift
    ;;
  -h | --help)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) die "unknown option: $1" ;;
  esac
  shift
done

[[ $POSITION == left || $POSITION == right ]] || die "--position must be left or right"
BIN_DIR="$PREFIX/bin"

# How to reload waybar on this machine. Generic by default; omarchy has a wrapper.
restart_hint() {
  if command -v omarchy >/dev/null 2>&1; then
    printf 'omarchy restart waybar'
  elif command -v systemctl >/dev/null 2>&1 &&
    systemctl --user is-enabled waybar.service >/dev/null 2>&1; then
    printf 'systemctl --user restart waybar'
  else
    printf 'pkill waybar; waybar >/dev/null 2>&1 &'
  fi
}

waybar_config() {
  local c
  for c in "$WAYBAR_DIR/config.jsonc" "$WAYBAR_DIR/config"; do
    [[ -f $c ]] && {
      printf '%s' "$c"
      return 0
    }
  done
  return 1
}

# --- dependencies ------------------------------------------------------------
check_deps() {
  local d missing=() optional=()
  for d in bash jq socat inotifywait hyprctl pkill flock tac; do
    command -v "$d" >/dev/null 2>&1 || missing+=("$d")
  done
  command -v waybar >/dev/null 2>&1 || optional+=(waybar)
  local m found=0
  for m in omarchy-launch-walker walker fuzzel rofi wofi tofi bemenu dmenu; do
    command -v "$m" >/dev/null 2>&1 && {
      found=1
      break
    }
  done
  ((found)) || missing+=("a dmenu-capable launcher (walker, fuzzel, rofi, wofi, tofi, bemenu or dmenu)")

  if ((${#missing[@]})); then
    printf '\033[31mmissing dependencies:\033[0m\n' >&2
    printf '  - %s\n' "${missing[@]}" >&2
    printf '\n  Arch:   sudo pacman -S --needed jq socat inotify-tools\n' >&2
    printf '  Debian: sudo apt install jq socat inotify-tools\n' >&2
    printf '  Fedora: sudo dnf install jq socat inotify-tools\n' >&2
    return 1
  fi
  ((${#optional[@]})) && info "note: ${optional[*]} not on PATH; install it to see the module"
  info "all dependencies present"
  return 0
}

# --- install -----------------------------------------------------------------
# Copy src to dst, backing up an existing dst we did not write ourselves.
install_file() {
  local src=$1 dst=$2 mode=$3 bak
  mkdir -p -- "$(dirname -- "$dst")"
  if [[ -e $dst ]]; then
    if [[ -L $dst ]]; then
      die "$dst is a symlink; refusing to overwrite it"
    fi
    if ! grep -q "$MARKER" -- "$dst" 2>/dev/null; then
      bak="$dst.bak.$(date +%s)"
      cp -p -- "$dst" "$bak"
      info "backed up existing $(short "$dst") -> $(short "$bak")"
    fi
  fi
  install -m "$mode" -- "$src" "$dst"
  info "installed $(short "$dst")"
}

short() { printf '%s' "${1/#"$HOME"/\~}"; }

# Same as install_file, but substitutes @BIN@ with the installed binary path so
# nothing depends on waybar or systemd inheriting your PATH.
install_template() {
  local src=$1 dst=$2 mode=$3 tmp
  tmp=$(mktemp)
  sed "s|@BIN@|$BIN_DIR/claude-queue|g" -- "$src" >"$tmp"
  install_file "$tmp" "$dst" "$mode"
  rm -f -- "$tmp"
}

do_install() {
  head1 "installing"
  install_file "$REPO/bin/claude-queue" "$BIN_DIR/claude-queue" 755
  install_template "$REPO/share/waybar/claude-queue.jsonc" "$WAYBAR_DIR/claude-queue.jsonc" 644
  install_file "$REPO/share/waybar/claude-queue.css" "$WAYBAR_DIR/claude-queue.css" 644
  install_template "$REPO/share/hypr/waybarclaude.conf" "$HYPR_DIR/waybarclaude.conf" 644

  # The user's own config is never overwritten, only seeded.
  mkdir -p -- "$WBC_CFG_DIR"
  if [[ -e "$WBC_CFG_DIR/config" ]]; then
    info "kept your $(short "$WBC_CFG_DIR/config")"
  else
    install -m 644 -- "$REPO/share/config.example" "$WBC_CFG_DIR/config.example"
    info "reference config at $(short "$WBC_CFG_DIR/config.example")"
  fi

  case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) info "warning: $(short "$BIN_DIR") is not on your PATH; waybar will not find claude-queue" ;;
  esac
}

do_service() {
  ((DO_SERVICE)) || return 0
  head1 "daemon"
  if ! command -v systemctl >/dev/null 2>&1; then
    info "no systemd; add this to ~/.config/hypr/hyprland.conf instead:"
    info "    source = ~/.config/hypr/waybarclaude.conf"
    return 0
  fi
  install_template "$REPO/share/systemd/waybarclaude.service" \
    "$SYSTEMD_DIR/waybarclaude.service" 644
  systemctl --user daemon-reload
  systemctl --user enable --now waybarclaude.service 2>/dev/null ||
    info "could not start it yet; it will come up with your next graphical session"
  if systemctl --user is-active --quiet waybarclaude.service; then
    info "waybarclaude.service is running"
  else
    info "waybarclaude.service is enabled but not active yet"
  fi
}

# --- walker theme ------------------------------------------------------------
# Walker only looks for themes in XDG_CONFIG_DIRS and in the single
# `additional_theme_location` from its config, and resolves them in the *service*
# process, so a per-invocation env var cannot inject one. To get a themed picker
# without changing your normal launcher's look we therefore:
#   1. put our theme in ~/.config/walker/themes/  (yours, survives distro updates)
#   2. symlink whatever themes the current location holds into there, so they keep
#      resolving -- through the symlink they also keep tracking their upstream
#   3. point additional_theme_location at ~/.config/walker/themes/
#   4. ask for it per-invocation with `walker --theme waybarclaude`
# Only step 3 touches a file you own; if something later resets it, walker just
# falls back to its default theme and the picker still works.
WALKER_THEME_NAME=waybarclaude

walker_theme() {
  ((DO_WALKER_THEME)) || return 0
  head1 "walker theme"
  command -v walker >/dev/null 2>&1 || { info "walker not installed, skipping"; return 0; }

  local wcfg="$CFG/walker/config.toml"
  local tdir="$CFG/walker/themes"
  local dst="$tdir/$WALKER_THEME_NAME"
  mkdir -p -- "$dst"

  # layout.xml: copy from a theme this walker install already ships, so we inherit
  # the widget schema of the installed version instead of pinning our own.
  local src='' c
  for c in "$tdir"/*/layout.xml \
    "$HOME/.local/share/omarchy/default/walker/themes/omarchy-default/layout.xml" \
    /etc/xdg/walker/themes/default/layout.xml \
    /usr/share/walker/themes/default/layout.xml; do
    [[ -f $c && $c != "$dst/layout.xml" ]] && { src=$c; break; }
  done
  [[ -n $src ]] || { info "no walker layout.xml found to base the theme on, skipping"; return 0; }
  install -m 644 -- "$src" "$dst/layout.xml"
  info "layout from $(short "$src")"

  # colours: follow the desktop theme when it exposes walker colours
  local colours theme_css="$CFG/omarchy/current/theme/walker.css"
  if [[ -f $theme_css ]]; then
    colours="@import url(\"file://$theme_css\");"
    info "colours follow $(short "$theme_css")"
  else
    colours=$'@define-color base #1a1b26;\n@define-color text #c0caf5;\n@define-color border #2f3549;\n@define-color selected-text #7aa2f7;\n@define-color background #1a1b26;\n@define-color foreground #c0caf5;'
    info "colours: built-in fallback palette"
  fi
  local tmp
  tmp=$(mktemp)
  python3 - "$REPO/share/walker/style.css" "$tmp" "$colours" <<'PYEOF'
import sys
src, dst, colours = sys.argv[1:4]
open(dst, 'w').write(open(src).read().replace('@COLORS@', colours))
PYEOF
  install_file "$tmp" "$dst/style.css" 644
  rm -f -- "$tmp"
  # regenerated by the picker on every launch; must exist so the @import resolves
  [[ -f "$dst/rows.css" ]] || printf '/* %s: regenerated per launch */\n' "$MARKER" >"$dst/rows.css"

  # Keep the themes from the old location working from the new one. A symlink is
  # NOT enough: a theme whose style.css imports its colours with a relative path
  # (omarchy's does) would resolve that path from the symlink's depth, the import
  # would fail, its colours would be undefined and its window would render
  # transparent. So each one gets a shim whose stylesheet imports the original by
  # absolute path; the original's own relative import then resolves from where it
  # really lives, and it keeps tracking upstream.
  local cur
  cur=$(sed -n 's/^additional_theme_location[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$wcfg" 2>/dev/null | head -1)
  cur=${cur/#\~/$HOME}
  if [[ -n $cur && -d $cur && ${cur%/} != "${tdir%/}" ]]; then
    local d name
    for d in "$cur"/*/; do
      [[ -d $d ]] || continue
      d=${d%/}
      name=${d##*/}
      [[ $name == "$WALKER_THEME_NAME" ]] && continue
      if [[ -f "$d/style.scss" ]]; then
        info "skipped $name (uses style.scss, which cannot be shimmed)"
        continue
      fi
      [[ -f "$d/style.css" && -f "$d/layout.xml" ]] || continue
      mkdir -p -- "$tdir/$name"
      ln -sfn -- "$d/layout.xml" "$tdir/$name/layout.xml"
      printf '/* %s */\n@import url("file://%s/style.css");\n' "$MARKER" "$d" \
        >"$tdir/$name/style.css"
      info "shimmed $name -> $(short "$d")"
    done
  fi

  # point walker at the new location
  if [[ -f $wcfg ]]; then
    if grep -q "waybarclaude:managed" -- "$wcfg" 2>/dev/null; then
      info "config.toml already points here"
    else
      cp -p -- "$wcfg" "$wcfg.bak.$(date +%s)"
      python3 - "$wcfg" "$tdir" <<'PYEOF'
import re, sys
p, tdir = sys.argv[1:3]
t = open(p).read()
line = 'additional_theme_location = "%s/"  # waybarclaude:managed' % tdir.replace(__import__('os').path.expanduser('~'), '~')
if re.search(r'^additional_theme_location\s*=', t, re.M):
    t = re.sub(r'^additional_theme_location\s*=.*$', line, t, count=1, flags=re.M)
else:
    t = line + '\n' + t
open(p, 'w').write(t)
PYEOF
      info "config.toml: additional_theme_location -> $(short "$tdir")/ (backed up)"
    fi
  else
    printf 'additional_theme_location = "~/.config/walker/themes/"  # waybarclaude:managed\n' >"$wcfg"
    info "created $(short "$wcfg")"
  fi

  # the walker service caches its config; restart it so the theme is visible
  local svc
  svc=$(pgrep -x walker 2>/dev/null | head -1) || svc=''
  if [[ -n $svc ]]; then
    kill "$svc" 2>/dev/null && sleep 1
    if command -v uwsm-app >/dev/null 2>&1; then
      setsid uwsm-app -- env GSK_RENDERER=cairo walker --gapplication-service >/dev/null 2>&1 &
    else
      setsid walker --gapplication-service >/dev/null 2>&1 &
    fi
    sleep 1
    info "walker service restarted"
  fi
}

# --- wiring ------------------------------------------------------------------
INCLUDE_PATH='~/.config/waybar/claude-queue.jsonc'
MODULE_NAME='custom/claude-queue'
CSS_IMPORT='@import "claude-queue.css";'

print_wiring() {
  local wcfg
  wcfg=$(waybar_config) || wcfg="$WAYBAR_DIR/config.jsonc"
  head1 "two edits left, in your own files"
  cat <<EOF
  waybar cannot append to a modules array from an included file, so these two
  lines are yours to add. Re-run with --wire to have them applied for you.

  1. $(short "$wcfg")

       "include": ["$INCLUDE_PATH"],
       "modules-$POSITION": [ ..., "$MODULE_NAME" ],

  2. $(short "$WAYBAR_DIR/style.css")   (first line)

       $CSS_IMPORT

  then reload waybar:  $(restart_hint)
EOF
}

wire() {
  local wcfg scss
  wcfg=$(waybar_config) || die "no waybar config found in $(short "$WAYBAR_DIR")"
  scss="$WAYBAR_DIR/style.css"
  command -v python3 >/dev/null 2>&1 ||
    die "--wire needs python3 to edit your config safely; do it by hand instead"

  head1 "wiring"
  python3 - "$wcfg" "$scss" "$INCLUDE_PATH" "$MODULE_NAME" "modules-$POSITION" "$CSS_IMPORT" <<'PY'
import json, os, shutil, sys, time

cfg_path, css_path, inc, module, arr_key, css_import = sys.argv[1:7]

def strip_comments(text):
    """Remove // and /* */ comments that are not inside a string literal."""
    out, i, n = [], 0, len(text)
    in_str = in_line = in_block = False
    while i < n:
        c, nxt = text[i], text[i+1] if i+1 < n else ''
        if in_line:
            if c == '\n':
                in_line = False
                out.append(c)
        elif in_block:
            if c == '*' and nxt == '/':
                in_block = False
                i += 1
        elif in_str:
            out.append(c)
            if c == '\\':
                if i+1 < n:
                    out.append(nxt)
                    i += 1
            elif c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
                out.append(c)
            elif c == '/' and nxt == '/':
                in_line = True
                i += 1
            elif c == '/' and nxt == '*':
                in_block = True
                i += 1
            else:
                out.append(c)
        i += 1
    return ''.join(out)

def append_to_array(text, lb, rb, item):
    """Insert "item" as the last element of the array spanning lb..rb.

    Inserts after the last real element rather than immediately before the
    closing bracket, so a `]` sitting on its own line stays there.
    """
    if text[lb+1:rb].strip():
        j = rb - 1
        while j > lb and text[j] in ' \t\r\n':
            j -= 1
        return text[:j+1] + ', "%s"' % item + text[j+1:]
    return text[:lb+1] + '"%s"' % item + text[rb:]

def parses(text):
    try:
        json.loads(strip_comments(text))
        return True
    except Exception as e:
        print("    validation failed: %s" % e)
        return False

changed = []

# ---- config.jsonc -------------------------------------------------------
orig = open(cfg_path, encoding='utf-8').read()
text = orig
data = json.loads(strip_comments(orig))

listed = any(module in (data.get(k) or [])
             for k in data if k.startswith('modules-'))
if listed:
    print("    module already listed in a modules-* array")
else:
    # add to the modules array, keeping comments intact by editing text
    key = '"%s"' % arr_key
    at = text.find(key)
    if at == -1:
        print("    no %s array found; add \"%s\" to one yourself" % (arr_key, module))
    else:
        lb = text.find('[', at)
        rb = text.find(']', lb)
        if lb == -1 or rb == -1:
            print("    could not parse %s; add \"%s\" yourself" % (arr_key, module))
        else:
            text = append_to_array(text, lb, rb, module)
            changed.append('added "%s" to %s' % (module, arr_key))

if 'claude-queue.jsonc' in json.dumps(data.get('include', '')):
    print("    include already present")
else:
    if 'include' in data:
        at = text.find('"include"')
        lb = text.find('[', at)
        if lb != -1:
            text = append_to_array(text, lb, text.find(']', lb), inc)
            changed.append('appended to existing include')
        else:  # include is a bare string
            q1 = text.find('"', at + len('"include"'))
            q1 = text.find('"', q1)  # opening quote of the value
            q2 = text.find('"', q1+1)
            old = text[q1:q2+1]
            text = text[:q1] + '[%s, "%s"]' % (old, inc) + text[q2+1:]
            changed.append('converted include to an array')
    else:
        brace = text.find('{')
        text = text[:brace+1] + '\n  "include": ["%s"],' % inc + text[brace+1:]
        changed.append('added include')

if text != orig:
    if not parses(text):
        print("    NOT writing config.jsonc; wire it by hand")
        sys.exit(1)
    bak = '%s.bak.%d' % (cfg_path, int(time.time()))
    shutil.copy2(cfg_path, bak)
    open(cfg_path, 'w', encoding='utf-8').write(text)
    print("    backed up -> %s" % bak.replace(os.path.expanduser('~'), '~'))
    for c in changed:
        print("    %s" % c)

# ---- style.css ----------------------------------------------------------
if os.path.exists(css_path):
    css = open(css_path, encoding='utf-8').read()
    if 'claude-queue.css' in css:
        print("    style.css already imports it")
    else:
        bak = '%s.bak.%d' % (css_path, int(time.time()))
        shutil.copy2(css_path, bak)
        open(css_path, 'w', encoding='utf-8').write(css_import + '\n' + css)
        print("    added @import to style.css (backed up -> %s)"
              % bak.replace(os.path.expanduser('~'), '~'))
else:
    open(css_path, 'w', encoding='utf-8').write(css_import + '\n')
    print("    created style.css with the @import")
PY
  info "reload waybar to pick it up: $(restart_hint)"
}

# --- check -------------------------------------------------------------------
do_check() {
  head1 "installed files"
  local f
  for f in "$BIN_DIR/claude-queue" "$WAYBAR_DIR/claude-queue.jsonc" \
    "$WAYBAR_DIR/claude-queue.css" "$SYSTEMD_DIR/waybarclaude.service" \
    "$HYPR_DIR/waybarclaude.conf"; do
    if [[ -f $f ]] && grep -q "$MARKER" -- "$f" 2>/dev/null; then
      info "ok      $(short "$f")"
    else
      info "absent  $(short "$f")"
    fi
  done
  head1 "runtime"
  if [[ -x "$BIN_DIR/claude-queue" ]]; then
    "$BIN_DIR/claude-queue" doctor || true
  else
    info "claude-queue not installed"
  fi
}

# --- main --------------------------------------------------------------------
if ((CHECK_ONLY)); then
  do_check
  exit 0
fi

head1 "checking dependencies"
check_deps || die "install the missing dependencies and run this again"

do_install
do_service

if ((DO_WIRE)); then
  wire
else
  print_wiring
fi
walker_theme

head1 "status"
"$BIN_DIR/claude-queue" doctor || true
printf '\ndone. uninstall with: %s/uninstall.sh\n' "$(short "$REPO")"
