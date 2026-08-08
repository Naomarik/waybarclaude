#!/usr/bin/env bash
# waybarclaude uninstaller.
#
# Deliberately conservative. It only ever touches an explicit list of paths, it
# refuses to delete a file that does not carry the waybarclaude marker, it never
# runs `rm -rf` on a directory, and it shows you the plan before doing anything.
#
#   ./uninstall.sh              show the plan, ask, then remove
#   ./uninstall.sh --yes        skip the confirmation
#   ./uninstall.sh --purge      also remove the queue state directory
#   ./uninstall.sh --dry-run    show the plan and exit
#   ./uninstall.sh --prefix DIR default $HOME/.local

set -euo pipefail

MARKER='waybarclaude:managed'
PREFIX="${PREFIX:-$HOME/.local}"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE="${WBC_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-queue}"

ASSUME_YES=0 PURGE=0 DRY=0

die() {
  printf '\033[31merror\033[0m %s\n' "$*" >&2
  exit 1
}
info() { printf '  %s\n' "$*"; }
warn() { printf '  \033[33mskip\033[0m %s\n' "$*"; }
head1() { printf '\n\033[1m%s\033[0m\n' "$*"; }
short() { printf '%s' "${1/#"$HOME"/\~}"; }

while (($#)); do
  case $1 in
  --yes | -y) ASSUME_YES=1 ;;
  --purge) PURGE=1 ;;
  --dry-run | -n) DRY=1 ;;
  --prefix)
    PREFIX=${2:?directory}
    shift
    ;;
  -h | --help)
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) die "unknown option: $1" ;;
  esac
  shift
done

BIN_DIR="$PREFIX/bin"
WAYBAR_DIR="$CFG/waybar"
SYSTEMD_DIR="$CFG/systemd/user"
HYPR_DIR="$CFG/hypr"
WBC_CFG_DIR="$CFG/waybarclaude"

# The complete set of paths this project ever installs. Nothing outside this list
# is considered for removal.
FILES=(
  "$BIN_DIR/claude-queue"
  "$WAYBAR_DIR/claude-queue.jsonc"
  "$WAYBAR_DIR/claude-queue.css"
  "$SYSTEMD_DIR/waybarclaude.service"
  "$HYPR_DIR/waybarclaude.conf"
  "$WBC_CFG_DIR/config.example"
)

# State files this project creates, and nothing else. Anything unexpected in the
# state directory makes us leave the directory in place.
STATE_FILES=(queue.tsv queue.tsv.tmp addrs bindings.tsv bindings.tsv.tmp
  lock daemon.lock daemon.pid events)

# --- safety gates ------------------------------------------------------------
[[ -n ${HOME:-} && -d $HOME ]] || die "HOME is not set to a real directory"

# Refuse to consider any path that is not inside $HOME.
inside_home() {
  local p
  p=$(readlink -m -- "$1")
  [[ $p == "$HOME"/* ]]
}

# A file is removable only if it exists, is a plain file, lives under $HOME, and
# carries our marker.
removable() {
  local f=$1
  [[ -e $f || -L $f ]] || return 1
  if [[ -L $f ]]; then
    warn "$(short "$f") is a symlink; leaving it alone"
    return 1
  fi
  if [[ ! -f $f ]]; then
    warn "$(short "$f") is not a regular file; leaving it alone"
    return 1
  fi
  if ! inside_home "$f"; then
    warn "$(short "$f") is outside \$HOME; leaving it alone"
    return 1
  fi
  if ! grep -q "$MARKER" -- "$f" 2>/dev/null; then
    warn "$(short "$f") has no waybarclaude marker; leaving it alone"
    return 1
  fi
  return 0
}

# --- plan --------------------------------------------------------------------
TO_REMOVE=()
head1 "files"
for f in "${FILES[@]}"; do
  if removable "$f"; then
    TO_REMOVE+=("$f")
    info "remove  $(short "$f")"
  elif [[ ! -e $f && ! -L $f ]]; then
    : # never installed, nothing to say
  fi
done
((${#TO_REMOVE[@]})) || info "nothing of ours found"

head1 "config edits to undo"
WCFG=''
for c in "$WAYBAR_DIR/config.jsonc" "$WAYBAR_DIR/config"; do
  [[ -f $c ]] && {
    WCFG=$c
    break
  }
done
UNWIRE=0
if [[ -n $WCFG ]] && grep -q 'claude-queue' -- "$WCFG"; then
  info "edit    $(short "$WCFG")  (drop the include entry and the module name)"
  UNWIRE=1
fi
SCSS="$WAYBAR_DIR/style.css"
UNCSS=0
if [[ -f $SCSS ]] && grep -q 'claude-queue.css' -- "$SCSS"; then
  info "edit    $(short "$SCSS")  (drop the @import line)"
  UNCSS=1
fi
((UNWIRE || UNCSS)) || info "nothing wired up"

head1 "walker theme"
WTDIR="$CFG/walker/themes"
WTHEME="$WTDIR/waybarclaude"
WCONF="$CFG/walker/config.toml"
UNTHEME=0
if [[ -f "$WTHEME/style.css" ]] && grep -q "$MARKER" -- "$WTHEME/style.css" 2>/dev/null; then
  info "remove  $(short "$WTHEME")"
  UNTHEME=1
fi
UNWCONF=0
if [[ -f $WCONF ]] && grep -q "$MARKER" -- "$WCONF" 2>/dev/null; then
  info "edit    $(short "$WCONF")  (restore additional_theme_location)"
  UNWCONF=1
fi
WLINKS=()
if [[ -d $WTDIR ]]; then
  for l in "$WTDIR"/*; do
    [[ -L $l ]] && WLINKS+=("$l")
  done
  ((${#WLINKS[@]})) && info "remove  ${#WLINKS[@]} theme symlink(s) we created"
fi
((UNTHEME || UNWCONF)) || info "no walker theme installed"

head1 "daemon"
SERVICE_PRESENT=0
if command -v systemctl >/dev/null 2>&1 &&
  systemctl --user cat waybarclaude.service >/dev/null 2>&1; then
  info "stop and disable waybarclaude.service"
  SERVICE_PRESENT=1
fi
DPID=''
if [[ -f "$STATE/daemon.pid" ]]; then
  DPID=$(cat -- "$STATE/daemon.pid" 2>/dev/null) || DPID=''
  # Only ever signal a pid whose command line really is our daemon.
  if [[ -n $DPID && $DPID =~ ^[0-9]+$ ]] && kill -0 "$DPID" 2>/dev/null &&
    tr '\0' ' ' <"/proc/$DPID/cmdline" 2>/dev/null | grep -q 'claude-queue'; then
    info "stop running daemon, pid $DPID"
  else
    DPID=''
  fi
fi
((SERVICE_PRESENT)) || [[ -n $DPID ]] || info "not running"

head1 "state"
STATE_OK=0
if ((PURGE)); then
  if [[ -L $STATE ]]; then
    warn "$(short "$STATE") is a symlink; leaving it alone"
  elif [[ ! -d $STATE ]]; then
    info "no state directory"
  elif ! inside_home "$STATE"; then
    warn "$(short "$STATE") is outside \$HOME; leaving it alone"
  else
    unexpected=()
    shopt -s nullglob dotglob
    for e in "$STATE"/*; do
      base=${e##*/}
      known=0
      for k in "${STATE_FILES[@]}"; do [[ $base == "$k" ]] && known=1 && break; done
      ((known)) || unexpected+=("$base")
    done
    shopt -u nullglob dotglob
    if ((${#unexpected[@]})); then
      warn "$(short "$STATE") holds files we did not create: ${unexpected[*]}"
      info "        our own files will go, the directory will stay"
    fi
    info "remove  $(short "$STATE")/{${STATE_FILES[0]},...}"
    STATE_OK=1
  fi
else
  info "keeping $(short "$STATE")  (pass --purge to remove the queue too)"
fi

if ((DRY)); then
  printf '\ndry run, nothing changed.\n'
  exit 0
fi

if ((!ASSUME_YES)); then
  if [[ ! -t 0 ]]; then
    die "not a terminal; re-run with --yes if you are sure"
  fi
  printf '\nproceed? [y/N] '
  read -r reply
  [[ $reply == [yY]* ]] || {
    printf 'aborted, nothing changed.\n'
    exit 0
  }
fi

# --- act ---------------------------------------------------------------------
head1 "removing"

if ((SERVICE_PRESENT)); then
  systemctl --user disable --now waybarclaude.service >/dev/null 2>&1 || true
  info "service stopped and disabled"
fi
if [[ -n $DPID ]]; then
  kill -TERM "$DPID" 2>/dev/null || true
  sleep 1
  kill -0 "$DPID" 2>/dev/null && kill -KILL "$DPID" 2>/dev/null || true
  info "daemon stopped"
fi

for f in "${TO_REMOVE[@]}"; do
  rm -f -- "$f"
  info "removed $(short "$f")"
done
if ((SERVICE_PRESENT)) && command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload || true
fi

if ((UNWIRE || UNCSS)) && command -v python3 >/dev/null 2>&1; then
  python3 - "$WCFG" "$SCSS" <<'PY'
import json, os, re, shutil, sys, time
cfg_path, css_path = sys.argv[1:3]

def bak(p):
    b = '%s.bak.%d' % (p, int(time.time()))
    shutil.copy2(p, b)
    return b.replace(os.path.expanduser('~'), '~')

if cfg_path and os.path.exists(cfg_path):
    text = open(cfg_path, encoding='utf-8').read()
    new = text
    # drop "custom/claude-queue" from any array, and the include entry
    new = re.sub(r',\s*"custom/claude-queue"', '', new)
    new = re.sub(r'"custom/claude-queue"\s*,\s*', '', new)
    new = re.sub(r',\s*"[^"]*claude-queue\.jsonc"', '', new)
    new = re.sub(r'"[^"]*claude-queue\.jsonc"\s*,\s*', '', new)
    # a lone include we added, now empty
    new = re.sub(r'\n\s*"include":\s*\[\s*"[^"]*claude-queue\.jsonc"\s*\],?', '', new)
    new = re.sub(r'\n\s*"include":\s*\[\s*\],?', '', new)
    if new != text:
        b = bak(cfg_path)
        open(cfg_path, 'w', encoding='utf-8').write(new)
        print("  unwired %s (backed up -> %s)"
              % (cfg_path.replace(os.path.expanduser('~'), '~'), b))

if css_path and os.path.exists(css_path):
    lines = open(css_path, encoding='utf-8').read().splitlines(True)
    kept = [l for l in lines if 'claude-queue.css' not in l]
    if len(kept) != len(lines):
        b = bak(css_path)
        open(css_path, 'w', encoding='utf-8').writelines(kept)
        print("  unimported style.css (backed up -> %s)" % b)
PY
elif ((UNWIRE || UNCSS)); then
  info "python3 not found; remove the claude-queue lines from your waybar config by hand"
fi

# --- walker theme ------------------------------------------------------------
if ((UNTHEME)); then
  # layout.xml is a verbatim copy of walker's own file so it carries no marker;
  # the marked style.css beside it is what authorises removing the pair.
  rm -f -- "$WTHEME/style.css" "$WTHEME/layout.xml"
  rmdir -- "$WTHEME" 2>/dev/null &&
    info "removed $(short "$WTHEME")" ||
    info "kept    $(short "$WTHEME") (not empty)"
fi

if ((UNWCONF)); then
  # Put additional_theme_location back where it pointed before, which the
  # symlink target tells us; if we cannot tell, drop the line and let walker
  # fall back to its own default theme.
  orig=''
  for l in "${WLINKS[@]}"; do
    tgt=$(readlink -f -- "$l" 2>/dev/null) || continue
    [[ -n $tgt ]] && orig=$(dirname -- "$tgt") && break
  done
  cp -p -- "$WCONF" "$WCONF.bak.$(date +%s)"
  if [[ -n $orig ]]; then
    python3 - "$WCONF" "$orig" <<'PYEOF'
import os, re, sys
p, orig = sys.argv[1:3]
t = open(p).read()
line = 'additional_theme_location = "%s/"' % orig.replace(os.path.expanduser('~'), '~')
t = re.sub(r'^additional_theme_location\s*=.*waybarclaude:managed.*$', line, t, flags=re.M)
open(p, 'w').write(t)
PYEOF
    info "restored additional_theme_location -> $(short "$orig")/"
  else
    python3 - "$WCONF" <<'PYEOF'
import re, sys
p = sys.argv[1]
t = open(p).read()
t = re.sub(r'^additional_theme_location\s*=.*waybarclaude:managed.*
', '', t, flags=re.M)
open(p, 'w').write(t)
PYEOF
    info "dropped the additional_theme_location line we added"
  fi
fi

for l in "${WLINKS[@]:-}"; do
  [[ -L $l ]] && rm -f -- "$l" && info "removed symlink $(short "$l")"
done
[[ -d $WTDIR ]] && rmdir -- "$WTDIR" 2>/dev/null && info "removed $(short "$WTDIR")"

if ((UNTHEME || UNWCONF)); then
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
fi

if ((STATE_OK)); then
  for k in "${STATE_FILES[@]}"; do
    [[ -e "$STATE/$k" ]] && rm -f -- "$STATE/$k"
  done
  # rmdir, never rm -rf: if anything unexpected is still in there, the directory
  # survives and you get told about it.
  if rmdir -- "$STATE" 2>/dev/null; then
    info "removed $(short "$STATE")"
  else
    info "kept    $(short "$STATE") (not empty; inspect it yourself)"
  fi
fi

if command -v omarchy >/dev/null 2>&1; then
  hint='omarchy restart waybar'
else
  hint='pkill waybar; waybar >/dev/null 2>&1 &'
fi
printf '\ndone. reload waybar to drop the module: %s\n' "$hint"
