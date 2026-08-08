#!/usr/bin/env bash
# End-to-end test for claude-queue.
#
# Runs the real daemon against a scratch roster and a fake compositor event
# socket, so every transition is deterministic and nothing touches your real
# ~/.claude or your real queue state.
#
# Needs a running Hyprland with at least three terminal windows open, because
# binding checks a window's real class. Everything else is synthetic.
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

export HYPRLAND_INSTANCE_SIGNATURE=$FAKE_SIG
"$CQ" watch &
DPID=$!
cleanup() {
  kill -TERM "$DPID" 2>/dev/null
  sleep 0.4
  kill -KILL "$DPID" "$LPID" 2>/dev/null
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

ICON_RUN=$(printf '\xf3\xb0\x94\x9f')  # U+F051F nf-md-timer_sand
ICON_WAIT=$(printf '\xf3\xb0\x82\x9a') # U+F009A nf-md-bell

S1=11111111-1111-1111-1111-111111111111
S2=22222222-2222-2222-2222-222222222222
S3=33333333-3333-3333-3333-333333333333
S4=44444444-4444-4444-4444-444444444444

echo
echo "1. a turn starts while window A is focused -> the session learns it lives in A"
focus "$A"
write_session 900001 "$S1" busy sess-one /tmp/proj-one
check "bound to A" "$(bind_of "$S1")" "$A"
check "not queued while running" "$(qcount)" "0"
check "counted as in flight" "$(bartext)" "$ICON_RUN 1"

echo
echo "2. the turn ends while you are looking right at it -> no entry"
write_session 900001 "$S1" idle sess-one /tmp/proj-one
check "still nothing queued" "$(qcount)" "0"
check "bar is empty" "$(bartext)" ""

echo
echo "3. the turn ends while you are looking elsewhere -> queued"
write_session 900001 "$S1" busy sess-one /tmp/proj-one
focus "$B"
write_session 900001 "$S1" idle sess-one /tmp/proj-one
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
write_session 900002 "$S2" busy sess-two /tmp/proj-two
check "session 2 bound to B" "$(bind_of "$S2")" "$B"
focus "$A"
write_session 900002 "$S2" idle sess-two /tmp/proj-two
check "session 2 queued" "$(qcount)" "1"
write_session 900001 "$S1" busy sess-one /tmp/proj-one
check "one running, one waiting" "$(bartext)" "$ICON_RUN 1  $ICON_WAIT 1"

echo
echo "6. a queued session that starts working again drops out of the queue"
focus "$B"
write_session 900002 "$S2" busy sess-two /tmp/proj-two
check "queue emptied" "$(qcount)" "0"
check "two in flight" "$(bartext)" "$ICON_RUN 2"

echo
echo "7. a session that exits takes its entry with it"
focus "$A"
write_session 900002 "$S2" idle sess-two /tmp/proj-two
check "queued again" "$(qcount)" "1"
rm -f "$WBC_SESSIONS_DIR/900002.json"
sleep 0.6
check "removed when the session exited" "$(qcount)" "0"

echo
echo "8. closing a queued window clears its entry"
focus "$C"
write_session 900003 "$S3" busy sess-three /tmp/proj-three
check "bound to C (A and B are taken)" "$(bind_of "$S3")" "$C"
focus "$B"
write_session 900003 "$S3" idle sess-three /tmp/proj-three
check "queued (bound to C)" "$(qcount)" "1"
closew "$C"
check "cleared when the window closed" "$(qcount)" "0"

echo
echo "9. a session with no known window still queues"
printf 'activewindowv2>>\n' >&4
sleep 0.4
write_session 900004 "$S4" busy lonely /tmp/proj-lonely
write_session 900004 "$S4" idle lonely /tmp/proj-lonely
check "queued without a window" "$(qcount)" "1"
check "counted alongside the running one" "$(bartext)" "$ICON_RUN 1  $ICON_WAIT 1"

echo
echo "10. the picker lists both groups, and choosing an entry dequeues it"
mkdir -p "$SB/stub"
cat >"$SB/stub/menu" <<STUB
#!/usr/bin/env bash
# stand-in for the picker: record what it was offered, choose the first row
cat >"$SB/menu-shown.txt"
head -1 "$SB/menu-shown.txt"
STUB
chmod +x "$SB/stub/menu"
WBC_MENU="$SB/stub/menu" "$CQ" menu >/dev/null 2>&1 || true
if [[ -s "$SB/menu-shown.txt" ]]; then
  row1=$(head -1 "$SB/menu-shown.txt")
  row2=$(sed -n 2p "$SB/menu-shown.txt")
  check "picker offered 2 rows" "$(grep -c . "$SB/menu-shown.txt")" "2"
  check "waiting row first" "${row1:0:1}" "$ICON_WAIT"
  check "running row second" "${row2:0:1}" "$ICON_RUN"
  check "choosing the waiting row dequeued it" "$(qcount)" "0"
else
  no "picker ran" "no menu captured" "2 rows"
fi

echo
echo "11. the daemon burns no CPU on a quiet event stream"
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
