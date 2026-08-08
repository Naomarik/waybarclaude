#!/usr/bin/env bash
# Removes the waybarclaude walker theme and puts walker's config back.
#
# As conservative as the main uninstaller: it only touches an explicit list of
# paths, refuses to delete a file that does not carry the waybarclaude marker,
# never runs `rm -rf` on a directory, and shows you the plan first.
#
#   ./uninstall.sh            show the plan, ask, then remove
#   ./uninstall.sh --yes      skip the confirmation
#   ./uninstall.sh --dry-run  show the plan and exit

set -euo pipefail

MARKER='waybarclaude:managed'
THEME_NAME=waybarclaude
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
WCONF="$CFG/walker/config.toml"
TDIR="$CFG/walker/themes"
DST="$TDIR/$THEME_NAME"

ASSUME_YES=0 DRY=0
while (($#)); do
  case $1 in
  --yes | -y) ASSUME_YES=1 ;;
  --dry-run | -n) DRY=1 ;;
  -h | --help)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    printf 'unknown option: %s\n' "$1" >&2
    exit 1
    ;;
  esac
  shift
done

info() { printf '  %s\n' "$*"; }
warn() { printf '  \033[33mskip\033[0m %s\n' "$*"; }
head1() { printf '\n\033[1m%s\033[0m\n' "$*"; }
short() { printf '%s' "${1/#"$HOME"/\~}"; }
die() {
  printf '\033[31merror\033[0m %s\n' "$*" >&2
  exit 1
}

[[ -n ${HOME:-} && -d $HOME ]] || die "HOME is not set to a real directory"
inside_home() {
  local p
  p=$(readlink -m -- "$1")
  [[ $p == "$HOME"/* ]]
}

# --- plan --------------------------------------------------------------------
head1 "theme"
RM_THEME=0
if [[ -L $DST ]]; then
  warn "$(short "$DST") is a symlink; leaving it alone"
elif [[ -f "$DST/style.css" ]] && grep -q "$MARKER" -- "$DST/style.css" 2>/dev/null &&
  inside_home "$DST"; then
  info "remove  $(short "$DST")"
  RM_THEME=1
elif [[ -e $DST ]]; then
  warn "$(short "$DST") has no waybarclaude marker; leaving it alone"
else
  info "not installed"
fi

# Shims we created: a marked style.css beside a symlinked layout.xml.
SHIMS=()
if [[ -d $TDIR ]]; then
  for d in "$TDIR"/*/; do
    d=${d%/}
    [[ ${d##*/} == "$THEME_NAME" ]] && continue
    [[ -f "$d/style.css" ]] && grep -q "$MARKER" -- "$d/style.css" 2>/dev/null &&
      [[ -L "$d/layout.xml" ]] && SHIMS+=("$d")
  done
fi
((${#SHIMS[@]})) && info "remove  ${#SHIMS[@]} theme shim(s) we created"

head1 "walker config"
RESTORE=0
if [[ -f $WCONF ]] && grep -q "$MARKER" -- "$WCONF" 2>/dev/null; then
  info "edit    $(short "$WCONF")  (restore additional_theme_location)"
  RESTORE=1
else
  info "not pointed here, nothing to restore"
fi

if ((DRY)); then
  printf '\ndry run, nothing changed.\n'
  exit 0
fi
((RM_THEME || RESTORE || ${#SHIMS[@]})) || {
  printf '\nnothing to do.\n'
  exit 0
}
if ((!ASSUME_YES)); then
  [[ -t 0 ]] || die "not a terminal; re-run with --yes if you are sure"
  printf '\nproceed? [y/N] '
  read -r reply
  [[ $reply == [yY]* ]] || {
    printf 'aborted, nothing changed.\n'
    exit 0
  }
fi

# --- act ---------------------------------------------------------------------
head1 "removing"

if ((RM_THEME)); then
  rm -f -- "$DST/style.css" "$DST/layout.xml" "$DST/rows.css"
  # rmdir, never rm -rf: anything unexpected left in there blocks the delete
  rmdir -- "$DST" 2>/dev/null &&
    info "removed $(short "$DST")" ||
    info "kept    $(short "$DST") (not empty; inspect it yourself)"
fi

if ((RESTORE)); then
  # A shim's symlinked layout.xml points back at the original theme, which is how
  # we recover where additional_theme_location used to point.
  orig=''
  for d in "${SHIMS[@]:-}"; do
    tgt=$(readlink -f -- "$d/layout.xml" 2>/dev/null) || continue
    [[ -n $tgt ]] && orig=$(dirname -- "$(dirname -- "$tgt")") && break
  done
  cp -p -- "$WCONF" "$WCONF.bak.$(date +%s)"
  if [[ -n $orig ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$WCONF" "$orig" <<'PYEOF'
import os, re, sys
p, orig = sys.argv[1:3]
t = open(p).read()
line = 'additional_theme_location = "%s/"' % orig.replace(os.path.expanduser('~'), '~')
t = re.sub(r'^additional_theme_location\s*=.*waybarclaude:managed.*$', line, t, flags=re.M)
open(p, 'w').write(t)
PYEOF
    info "restored additional_theme_location -> $(short "$orig")/"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$WCONF" <<'PYEOF'
import re, sys
p = sys.argv[1]
t = open(p).read()
t = re.sub(r'^additional_theme_location\s*=.*waybarclaude:managed.*\n', '', t, flags=re.M)
open(p, 'w').write(t)
PYEOF
    info "dropped the additional_theme_location line we added"
  else
    info "python3 missing; edit $(short "$WCONF") by hand"
  fi
fi

for d in "${SHIMS[@]:-}"; do
  rm -f -- "$d/style.css" "$d/layout.xml"
  rmdir -- "$d" 2>/dev/null && info "removed shim $(short "$d")"
done
[[ -d $TDIR ]] && rmdir -- "$TDIR" 2>/dev/null && info "removed $(short "$TDIR")"

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

printf '\ndone. the picker keeps working, using walkers default theme.\n'
