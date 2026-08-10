#!/usr/bin/env bash
# End-to-end test for claude-queue.
#
# Runs the real daemon against a scratch roster and a fake compositor event
# socket, so every transition is deterministic and nothing touches your real
# ~/.claude or your real queue state.
#
# Needs a running Hyprland with at least three terminal windows open, because
# binding checks a window's real class. Everything else is synthetic:
#   - hyprctl is shimmed so the test can never steal your focus, and so a focus
#     request can be asserted on instead of watched for
#   - notify-send is shimmed for the same reason
#   - a session's process is real, because liveness is decided from /proc: each
#     one is a copy of /bin/sleep named claude, started so that it reparents away
#     from this script rather than inheriting its ancestry, which is what lets the
#     suite run inside tmux without every fake session looking like a pane
# The tmux sections skip themselves if tmux is not installed.
set -uo pipefail

REPO=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
CQ="$REPO/bin/claude-queue"
[[ -x $CQ ]] || {
  echo "not found: $CQ" >&2
  exit 1
}

SB=$(mktemp -d -t waybarclaude-test-XXXXXX)
export WBC_SESSIONS_DIR="$SB/sessions"
export WBC_PROJECTS_DIR="$SB/projects" # empty: forces the focus-based binding path
export WBC_STATE="$SB/state"
mkdir -p "$WBC_SESSIONS_DIR" "$WBC_PROJECTS_DIR" "$WBC_STATE"

SEP=$'\x1f'
REAL_SIG=${HYPRLAND_INSTANCE_SIGNATURE:?needs a running Hyprland}
FAKE_SIG=waybarclaude-test
FAKE_DIR="${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr/$FAKE_SIG"
EVFIFO="$SB/evfifo"

pass=0 fail=0
ok() {
  printf '  \033[32mPASS\033[0m %s\n' "$1"
  ((pass++))
}
no() {
  printf '  \033[31mFAIL\033[0m %s\n       expected [%s] got [%s]\n' "$1" "$3" "$2"
  ((fail++))
}
check() { if [[ $2 == "$3" ]]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

# Machine-agnostic: take whichever window class has at least three windows open
# and declare that class a terminal for the duration of the test. Avoids assuming
# any particular terminal is installed.
CLASS=$(hyprctl clients -j |
  jq -r '[.[] | select(.mapped) | .class] | group_by(.) | map(select(length >= 3))
         | sort_by(-length) | .[0][0] // empty')
if [[ -z $CLASS ]]; then
  echo "need at least 3 windows of the same class open; found none" >&2
  rm -rf "$SB"
  exit 1
fi
export WBC_CONFIG="$SB/config"
printf 'TERMINAL_CLASSES=%q\n' "$CLASS" >"$WBC_CONFIG"
mapfile -t WINS < <(hyprctl clients -j |
  jq -r --arg c "$CLASS" '.[] | select(.class==$c) | .address')
A=${WINS[0]} B=${WINS[1]} C=${WINS[2]}
echo "class:   $CLASS"
echo "windows: A=$A B=$B C=$C"
echo "sandbox: $SB"

# Fake compositor event socket. hyprctl still needs to answer real queries, so
# .socket.sock is symlinked to the real one while .socket2.sock is ours.
mkdir -p "$FAKE_DIR"
ln -sf "${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr/$REAL_SIG/.socket.sock" \
  "$FAKE_DIR/.socket.sock"
rm -f "$FAKE_DIR/.socket2.sock" "$EVFIFO"
mkfifo "$EVFIFO"
socat UNIX-LISTEN:"$FAKE_DIR/.socket2.sock" - <"$EVFIFO" >/dev/null 2>&1 &
LPID=$!
exec 4>"$EVFIFO" # hold the write end so socat's stdin never EOFs
for _ in {1..40}; do [[ -S "$FAKE_DIR/.socket2.sock" ]] && break; sleep 0.1; done

# Shims. Everything reaches the real hyprctl except a focus change, which is
# logged instead: the test can then assert on it without the window manager
# yanking your focus around mid-run.
REAL_HYPRCTL=$(command -v hyprctl)
mkdir -p "$SB/shim"
cat >"$SB/shim/hyprctl" <<SHIM
#!/usr/bin/env bash
if [[ \$1 == dispatch && \$2 == focuswindow* ]]; then
  printf '%s\n' "\${3:-\$2}" >>"$SB/focused.log"
  exit 0
fi
exec $REAL_HYPRCTL "\$@"
SHIM
cat >"$SB/shim/notify-send" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SB/notified.log"
SHIM
chmod +x "$SB/shim/hyprctl" "$SB/shim/notify-send"
export PATH="$SB/shim:$PATH"
: >"$SB/focused.log"
: >"$SB/notified.log"

# A session's process has to exist, and has to look like claude, because a roster
# file whose process is gone is now treated as the leftover it is. The subshell is
# what reparents the process away from this script: started as a plain background
# job it would inherit our ancestry, and inside tmux that would make every fake
# session look like it lives in a pane.
cp -- "$(command -v sleep)" "$SB/claude"
FAKE_PIDS=()
spawn_fake() {
  local f="$SB/spawned.pid"
  rm -f "$f" "$f.tmp"
  ("$SB/claude" 9000 >/dev/null 2>&1 &
    printf '%s' "$!" >"$f.tmp"
    mv -f "$f.tmp" "$f")
  local i pid=''
  for i in {1..20}; do
    pid=$(cat "$f" 2>/dev/null) && [[ -n $pid ]] && break
    sleep 0.05
  done
  FAKE_PIDS+=("$pid")
  printf '%s' "$pid"
}

TSESS=waybarclaude-test-$$

export HYPRLAND_INSTANCE_SIGNATURE=$FAKE_SIG
"$CQ" watch &
DPID=$!
cleanup() {
  kill -TERM "$DPID" 2>/dev/null
  sleep 0.4
  kill -KILL "$DPID" "$LPID" 2>/dev/null
  ((${#FAKE_PIDS[@]})) && kill -KILL "${FAKE_PIDS[@]}" 2>/dev/null
  command -v tmux >/dev/null 2>&1 && tmux kill-session -t "$TSESS" 2>/dev/null
  exec 4>&- || true
  rm -rf "$FAKE_DIR" "$SB"
  wait 2>/dev/null
}
trap cleanup EXIT
sleep 1.5

write_session() { # pid sid status name cwd
  printf '{"pid":%s,"sessionId":"%s","cwd":"%s","startedAt":1,"kind":"interactive","name":"%s","nameSource":"derived","status":"%s","updatedAt":1,"statusUpdatedAt":1}' \
    "$1" "$2" "$5" "$4" "$3" >"$WBC_SESSIONS_DIR/$1.json.tmp"
  mv -f "$WBC_SESSIONS_DIR/$1.json.tmp" "$WBC_SESSIONS_DIR/$1.json"
  sleep 0.6
}
focus() {
  printf 'activewindowv2>>%s\n' "${1#0x}" >&4
  sleep 0.5
}
closew() {
  printf 'closewindow>>%s\n' "${1#0x}" >&4
  sleep 0.5
}
qcount() {
  local n
  n=$(grep -c . "$WBC_STATE/queue.tsv" 2>/dev/null)
  printf '%s' "${n:-0}"
}
bind_of() { awk -F"$SEP" -v s="$1" '$1==s{print $2}' "$WBC_STATE/bindings.tsv" 2>/dev/null; }
bartext() { "$CQ" status | jq -r .text; }
# field 7 of a queue record is the tmux pane, field 8 the window showing it
qfield() { awk -F"$SEP" -v s="$1" -v f="$2" '$1==s{print $f}' "$WBC_STATE/queue.tsv" 2>/dev/null; }
qhas() { awk -F"$SEP" -v s="$1" '$1==s{n++} END{print n+0}' "$WBC_STATE/queue.tsv" 2>/dev/null; }
lastline() { tail -1 "$1" 2>/dev/null; }

# Stand-in for the picker: records what it was offered, chooses row $1.
mkdir -p "$SB/stub"
make_picker() {
  cat >"$SB/stub/menu" <<STUB
#!/usr/bin/env bash
cat >"$SB/menu-shown.txt"
sed -n ${1}p "$SB/menu-shown.txt"
STUB
  chmod +x "$SB/stub/menu"
}

ICON_RUN=$(printf '\xf3\xb0\x94\x9f')  # U+F051F nf-md-timer_sand
ICON_WAIT=$(printf '\xf3\xb0\x82\x9a') # U+F009A nf-md-bell

S1=11111111-1111-1111-1111-111111111111
S2=22222222-2222-2222-2222-222222222222
S3=33333333-3333-3333-3333-333333333333
S4=44444444-4444-4444-4444-444444444444
T1=aaaaaaaa-1111-1111-1111-111111111111
T2=bbbbbbbb-2222-2222-2222-222222222222

P1=$(spawn_fake)
P2=$(spawn_fake)
P3=$(spawn_fake)
P4=$(spawn_fake)
echo "fakes:   $P1 $P2 $P3 $P4"

echo
echo "1. a turn starts while window A is focused -> the session learns it lives in A"
focus "$A"
write_session "$P1" "$S1" busy sess-one /tmp/proj-one
check "bound to A" "$(bind_of "$S1")" "$A"
check "not queued while running" "$(qcount)" "0"
check "counted as in flight" "$(bartext)" "$ICON_RUN 1"

echo
echo "2. the turn ends while you are looking right at it -> no entry"
write_session "$P1" "$S1" idle sess-one /tmp/proj-one
check "still nothing queued" "$(qcount)" "0"
check "bar is empty" "$(bartext)" ""

echo
echo "3. the turn ends while you are looking elsewhere -> queued"
write_session "$P1" "$S1" busy sess-one /tmp/proj-one
focus "$B"
write_session "$P1" "$S1" idle sess-one /tmp/proj-one
check "one entry queued" "$(qcount)" "1"
check "bar shows waiting" "$(bartext)" "$ICON_WAIT 1"
check "addrs cache points at A" "$(cat "$WBC_STATE/addrs")" "$A"

echo
echo "4. visiting that window yourself clears the entry"
focus "$A"
check "entry cleared on focus" "$(qcount)" "0"
check "bar is empty again" "$(bartext)" ""

echo
echo "5. a second session, and both counts show at once"
focus "$B"
write_session "$P2" "$S2" busy sess-two /tmp/proj-two
check "session 2 bound to B" "$(bind_of "$S2")" "$B"
focus "$A"
write_session "$P2" "$S2" idle sess-two /tmp/proj-two
check "session 2 queued" "$(qcount)" "1"
write_session "$P1" "$S1" busy sess-one /tmp/proj-one
check "one running, one waiting" "$(bartext)" "$ICON_RUN 1  $ICON_WAIT 1"

echo
echo "6. a queued session that starts working again drops out of the queue"
focus "$B"
write_session "$P2" "$S2" busy sess-two /tmp/proj-two
check "queue emptied" "$(qcount)" "0"
check "two in flight" "$(bartext)" "$ICON_RUN 2"

echo
echo "7. a session that exits takes its entry with it"
focus "$A"
write_session "$P2" "$S2" idle sess-two /tmp/proj-two
check "queued again" "$(qcount)" "1"
rm -f "$WBC_SESSIONS_DIR/$P2.json"
sleep 0.6
check "removed when the session exited" "$(qcount)" "0"

echo
echo "8. closing a queued window clears its entry"
focus "$C"
write_session "$P3" "$S3" busy sess-three /tmp/proj-three
check "bound to C (A and B are taken)" "$(bind_of "$S3")" "$C"
focus "$B"
write_session "$P3" "$S3" idle sess-three /tmp/proj-three
check "queued (bound to C)" "$(qcount)" "1"
closew "$C"
check "cleared when the window closed" "$(qcount)" "0"

echo
echo "9. a session with no known window still queues"
printf 'activewindowv2>>\n' >&4
sleep 0.4
write_session "$P4" "$S4" busy lonely /tmp/proj-lonely
write_session "$P4" "$S4" idle lonely /tmp/proj-lonely
check "queued without a window" "$(qcount)" "1"
check "counted alongside the running one" "$(bartext)" "$ICON_RUN 1  $ICON_WAIT 1"

echo
echo "10. the picker lists both groups; a row with nowhere to go says so and stays"
make_picker 1
: >"$SB/notified.log"
WBC_MENU="$SB/stub/menu" "$CQ" menu >/dev/null 2>&1 || true
if [[ -s "$SB/menu-shown.txt" ]]; then
  row1=$(head -1 "$SB/menu-shown.txt")
  row2=$(sed -n 2p "$SB/menu-shown.txt")
  check "picker offered 2 rows" "$(grep -c . "$SB/menu-shown.txt")" "2"
  check "waiting row first" "${row1:0:1}" "$ICON_WAIT"
  check "running row second" "${row2:0:1}" "$ICON_RUN"
  check "the entry survives, because we did not take you there" "$(qhas "$S4")" "1"
  check "and it explains itself instead" \
    "$(grep -c 'Could not find a window' "$SB/notified.log")" "1"
else
  no "picker ran" "no menu captured" "2 rows"
fi

echo
echo "11. give that session a window and the same row now jumps to it"
"$CQ" bind "$S4" "$B" # B is free again: the session that held it has ended
check "bound to B" "$(bind_of "$S4")" "$B"
: >"$SB/focused.log"
make_picker 1
WBC_MENU="$SB/stub/menu" "$CQ" menu >/dev/null 2>&1 || true
check "focused its window" "$(lastline "$SB/focused.log")" "address:$B"
check "and dequeued it" "$(qhas "$S4")" "0"

echo
echo "12. a session in a tmux pane: located through tmux, never bound to the terminal"
if ! command -v tmux >/dev/null 2>&1; then
  echo "  SKIP tmux is not installed"
else
  tmux new-session -d -s "$TSESS" -x 80 -y 24 "$SB/claude 9000" 2>/dev/null
  tmux split-window -t "$TSESS" -d "$SB/claude 9000" 2>/dev/null
  sleep 0.5
  mapfile -t PANES < <(tmux list-panes -t "$TSESS" \
    -F "#{pane_id}$SEP#{pane_pid}$SEP#{?pane_active,1,0}" 2>/dev/null)
  if ((${#PANES[@]} < 2)); then
    no "tmux fixture" "${#PANES[@]} panes" "2 panes"
  else
    IFS=$SEP read -r PANE1 TP1 ACT1 <<<"${PANES[0]}"
    IFS=$SEP read -r PANE2 TP2 ACT2 <<<"${PANES[1]}"
    # PANE1 is the one on screen in that tmux session; PANE2 is behind it.
    ((ACT1)) || {
      t=$PANE1 p=$TP1
      PANE1=$PANE2 TP1=$TP2
      PANE2=$t TP2=$p
    }
    echo "  panes:   $PANE1 (visible, pid $TP1)  $PANE2 (hidden, pid $TP2)"

    focus "$A" # a real window, and the wrong answer for a pane
    write_session "$TP1" "$T1" busy pane-one /tmp/proj-pane
    check "not bound to the focused window" "$(bind_of "$T1")" ""
    write_session "$TP1" "$T1" idle pane-one /tmp/proj-pane
    check "queued" "$(qhas "$T1")" "1"
    check "carrying its pane" "$(qfield "$T1" 7)" "$PANE1"
    # Nothing is attached to this tmux session, so there is no window to raise --
    # the pane is still selectable, and the picker says as much.
    check "with no window showing it" "$(qfield "$T1" 8)" ""

    tmux select-pane -t "$PANE2" 2>/dev/null
    : >"$SB/notified.log"
    make_picker 1
    WBC_MENU="$SB/stub/menu" "$CQ" menu >/dev/null 2>&1 || true
    check "choosing it selects the pane" \
      "$(tmux display -p -t "$TSESS" '#{pane_id}' 2>/dev/null)" "$PANE1"
    check "and says no window is showing it" \
      "$(grep -c 'No window is showing' "$SB/notified.log")" "1"
    check "then dequeues" "$(qhas "$T1")" "0"

    echo
    echo "13. looking at a terminal running tmux only clears the pane you can see"
    # Both panes queued against the same terminal, which is what a real tmux
    # window looks like: written directly so the rule is tested, not the lookup.
    tmux select-pane -t "$PANE1" 2>/dev/null
    {
      printf '%s\n' "$T1$SEP${SEP}pane-one$SEP/tmp/proj-pane${SEP}1${SEP}one$SEP$PANE1$SEP$A"
      printf '%s\n' "$T2$SEP${SEP}pane-two$SEP/tmp/proj-pane${SEP}1${SEP}two$SEP$PANE2$SEP$A"
    } >"$WBC_STATE/queue.tsv"
    "$CQ" drop-visited "$A" >/dev/null 2>&1
    check "the visible pane's entry goes" "$(qhas "$T1")" "0"
    check "the hidden one stays" "$(qhas "$T2")" "1"
    "$CQ" drop-window "$A" >/dev/null 2>&1
    check "closing the terminal takes the rest" "$(qcount)" "0"
  fi
fi

echo
echo "14. a roster file left behind by a killed session stops counting"
focus "$C"
write_session "$P1" "$S1" busy sess-one /tmp/proj-one
write_session "$P1" "$S1" idle sess-one /tmp/proj-one
check "queued" "$(qhas "$S1")" "1"
kill -KILL "$P1" 2>/dev/null
sleep 0.3
# The file is still there -- a killed session cannot clean up after itself -- so
# nothing woke the daemon. The bar has to work that out for itself.
check "roster file is still on disk" \
  "$([[ -f $WBC_SESSIONS_DIR/$P1.json ]] && echo yes || echo no)" "yes"
check "bar stops counting it right away" "$(bartext)" ""
"$CQ" sync >/dev/null 2>&1
check "and sync prunes the record" "$(qhas "$S1")" "0"

echo
echo "15. the daemon burns no CPU on a quiet event stream"
sleep 2
read -r u1 s1 < <(awk '{print $14, $15}' "/proc/$DPID/stat")
sleep 6
read -r u2 s2 < <(awk '{print $14, $15}' "/proc/$DPID/stat")
check "0 jiffies over 6s idle" "$(((u2 + s2) - (u1 + s1)))" "0"
echo "  process tree:"
sup=$(ps -o pid= --ppid "$DPID" | tr -d ' ')
ps -o pid,pcpu,rss,args --no-headers -p "$DPID" --ppid "$DPID" ${sup:+--ppid "$sup"} 2>/dev/null |
  sed 's/^/    /' | cut -c1-100

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ $fail == 0 ]]
