#!/usr/bin/env bash
# drive_run_challenges.sh — unattended run of a student bundle's
# ./run_challenges.sh, the way a student uses it: load the images, pick a
# challenge from the menu, wait for it to go live, paste a proof, press
# 'n', and finally 'q'.
#
#   test/ci/drive_run_challenges.sh --bundle <dir> --mode real|mock [options]
#
#   --mode real   real (rootful) Docker + sudo: ubuntu-latest, or a
#                 self-hosted macOS/Windows runner.
#   --mode mock   no container engine (macos-latest, windows-latest): runs a
#                 PATCHED COPY of run_challenges.sh against the mock
#                 docker/sudo in test/ci/mock-docker/ and the fake endpoints
#                 in test/ci/mock_lab_services.py. The patch only points
#                 SERVER_IP/VALIDATOR_IP at 127.0.0.1 and moves ports
#                 443/4435 to unprivileged ones. Each patch must match, so
#                 template drift fails loudly.
#   --ids "a b c" challenge IDs to visit, in that order (default: all, in menu order)
#   --first N     only the first N menu entries (overrides --ids)
#   --log-dir D   where to write the logs (default: a fresh temp dir)
#
# Per challenge it checks:
#   - the challenge reaches "is live" (90s default, 600s for hundreds_servers)
#   - the validator is reachable and a wrong proof is shown as a FAILURE
#     (red "[!] validator: ...") and not as a success
#   - mock only: the right proof is shown as a success, and the exact
#     `docker run` arguments: server-only NET_BIND_SERVICE, --cap-drop=ALL
#     everywhere, CHALLENGE_ID, --cpus, a read-only /run/identity mount
#     holding the 6 rotated *.bin keys
# Once, at the end: 'q' exits 0, no tls-lab-* container or network is
# left, and the identity temp dirs are deleted.
#
# KNOWN_ISSUES="keygen verdict" turns those checks into warnings so CI can
# stay green while a known bug is still open:
#   keygen  - the embedded Linux keygen can't run on this host (macOS/Git
#             Bash), so identity rotation is skipped silently
#   verdict - a bundle built before 2026-10-23 shows "FAIL — incorrect
#             secret" as a success ("incorrect" matched its 'correct' grep)
#
# Exit status: number of failed checks (capped at 100). Bash 3.2-compatible.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE=""
MODE=""
IDS=""
FIRST=""
LOG_DIR=""
KNOWN_ISSUES="${KNOWN_ISSUES:-}"
MOCK_TLS_PORT="${MOCK_TLS_PORT:-18443}"
MOCK_VAL_PORT="${MOCK_VAL_PORT:-14435}"
MENU_TIMEOUT="${MENU_TIMEOUT:-120}"
LOAD_TIMEOUT="${LOAD_TIMEOUT:-300}"

while [ $# -gt 0 ]; do
    case "$1" in
    --bundle)
        BUNDLE="$2"
        shift 2
        ;;
    --mode)
        MODE="$2"
        shift 2
        ;;
    --ids)
        IDS="$2"
        shift 2
        ;;
    --first)
        FIRST="$2"
        shift 2
        ;;
    --log-dir)
        LOG_DIR="$2"
        shift 2
        ;;
    -h | --help)
        sed -n '2,45p' "$0"
        exit 0
        ;;
    *)
        echo "unknown option: $1" >&2
        exit 2
        ;;
    esac
done
[ -n "$BUNDLE" ] && [ -f "$BUNDLE/run_challenges.sh" ] || {
    echo "--bundle <dir with run_challenges.sh> required" >&2
    exit 2
}
case "$MODE" in real | mock) ;; *)
    echo "--mode real|mock required" >&2
    exit 2
    ;;
esac
BUNDLE="$(cd "$BUNDLE" && pwd)"

[ -n "$LOG_DIR" ] || LOG_DIR="$(mktemp -d)"
mkdir -p "$LOG_DIR"
LOG_DIR="$(cd "$LOG_DIR" && pwd)"
RUNLOG="$LOG_DIR/run_challenges.log"
HLOG="$LOG_DIR/driver.log"
: >"$RUNLOG"
: >"$HLOG"
WORK="$(mktemp -d)"

ESC="$(printf '\033')"
FAILS=0
log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$HLOG"; }
pass() { log "  PASS  $*"; }
failc() {
    log "  FAIL  $*"
    FAILS=$((FAILS + 1))
}
known() { case " $KNOWN_ISSUES " in *" $1 "*) return 0 ;; *) return 1 ;; esac }
# fail_or_known <issue-tag> <message>
fail_or_known() {
    if known "$1"; then log "  WARN  [known:$1] $2"; else failc "$2"; fi
}
strip() { sed "s/${ESC}\[[0-9;]*m//g"; }

# ---------------------------------------------------------------------------
# menu order: same expansion as run_challenges.sh (levels 1..4, then meta)
# ---------------------------------------------------------------------------
META_RAW="$(sed -n 's/^CHALLENGE_META=(\(.*\))$/\1/p' "$BUNDLE/run_challenges.sh" | head -1)"
[ -n "$META_RAW" ] || {
    echo "no CHALLENGE_META=(...) in $BUNDLE/run_challenges.sh" >&2
    exit 2
}
MENU=""
for lvl in 1 2 3 4 meta; do
    for m in $META_RAW; do
        id="${m%%:*}"
        rest="${m#*:}"
        [ "${rest%%:*}" = "$lvl" ] && MENU="$MENU $id"
    done
done
# shellcheck disable=SC2206  # IDs are [a-z0-9_], word-splitting is the point
MENU_ARR=($MENU)
menu_number() { # menu_number <id> -> 1-based menu number, or empty
    local i=0
    while [ "$i" -lt "${#MENU_ARR[@]}" ]; do
        [ "${MENU_ARR[$i]}" = "$1" ] && {
            echo $((i + 1))
            return
        }
        i=$((i + 1))
    done
}
if [ -n "$FIRST" ]; then
    IDS="$(printf '%s\n' "${MENU_ARR[@]}" | head -n "$FIRST" | tr '\n' ' ')"
elif [ -z "$IDS" ]; then
    IDS="$MENU"
fi
for id in $IDS; do
    [ -n "$(menu_number "$id")" ] || {
        echo "'$id' is not in this bundle's menu" >&2
        exit 2
    }
done

log "bundle: $BUNDLE"
log "mode:   $MODE   host: $(uname -s)   bash: $BASH_VERSION"
log "menu:   ${#MENU_ARR[@]} entries; visiting: $(echo $IDS | wc -w | tr -d ' ')"
log "logs:   $LOG_DIR"
[ -n "$KNOWN_ISSUES" ] && log "known issues tolerated: $KNOWN_ISSUES"
# run_challenges.sh removes its fixed-name containers and network on start:
# never let a local real run destroy someone's live lab.
if [ "$MODE" = real ] && sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qE '^tls-lab-(server|client|validator)$'; then
    echo "refusing: tls-lab-server/client/validator containers already exist (a live lab?) and run_challenges.sh would remove them" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# mock mode setup
# ---------------------------------------------------------------------------
SVC_PID=""
EXPECTED_SECRET="$(printf 'c1%.0s' $(seq 1 32))" # 64 hex chars
RUN_DIR="$BUNDLE"
if [ "$MODE" = mock ]; then
    RUN_DIR="$WORK/bundle"
    mkdir -p "$RUN_DIR"
    cp -R "$BUNDLE"/. "$RUN_DIR"/
    rc="$RUN_DIR/run_challenges.sh"
    patch_one() { # patch_one <sed-expr> <must-match-regex-after>
        sed "$1" "$rc" >"$rc.new" && mv "$rc.new" "$rc"
        grep -q "$2" "$rc" || {
            echo "mock patch did not apply: $1 — run_challenges.sh template changed?" >&2
            exit 2
        }
    }
    patch_one 's/^SERVER_IP=192\.168\.50\.4$/SERVER_IP=127.0.0.1/' '^SERVER_IP=127\.0\.0\.1$'
    patch_one 's/^VALIDATOR_IP=192\.168\.50\.5$/VALIDATOR_IP=127.0.0.1/' '^VALIDATOR_IP=127\.0\.0\.1$'
    patch_one "s#/dev/tcp/\$SERVER_IP/443#/dev/tcp/\$SERVER_IP/$MOCK_TLS_PORT#" "/dev/tcp/\$SERVER_IP/$MOCK_TLS_PORT"
    patch_one "s#/dev/tcp/\$VALIDATOR_IP/4435#/dev/tcp/\$VALIDATOR_IP/$MOCK_VAL_PORT#" "/dev/tcp/\$VALIDATOR_IP/$MOCK_VAL_PORT"

    export MOCK_DOCKER_STATE="$WORK/docker-state"
    mkdir -p "$MOCK_DOCKER_STATE"
    chmod +x "$HERE/mock-docker/docker" "$HERE/mock-docker/sudo" 2>/dev/null
    export PATH="$HERE/mock-docker:$PATH"

    PY=""
    for p in python3 python; do
        if command -v "$p" >/dev/null 2>&1 && "$p" -c 'import sys; sys.exit(sys.version_info < (3, 6))' >/dev/null 2>&1; then
            PY="$p"
            break
        fi
    done
    [ -n "$PY" ] || {
        echo "mock mode needs python 3" >&2
        exit 2
    }
    "$PY" "$HERE/mock_lab_services.py" "$MOCK_TLS_PORT" "$MOCK_VAL_PORT" "$EXPECTED_SECRET" "$WORK/svc.ready" >>"$LOG_DIR/mock_services.log" 2>&1 &
    SVC_PID=$!
    for _ in $(seq 1 50); do
        [ -f "$WORK/svc.ready" ] && break
        sleep 0.2
    done
    [ -f "$WORK/svc.ready" ] || {
        echo "mock services did not start (see $LOG_DIR/mock_services.log)" >&2
        exit 2
    }
fi

# docker wrapper for our own checks: the same engine run_challenges.sh uses
dk() { sudo docker "$@"; }

# ---------------------------------------------------------------------------
# start run_challenges.sh, its stdin fed from a control file by `tail -f`
# (more portable than a FIFO, which Git Bash only emulates)
# ---------------------------------------------------------------------------
CTL="$WORK/stdin.ctl"
: >"$CTL"
RUN_PID=""
FEED_PID=""
cleanup() {
    set +e
    if [ -n "$RUN_PID" ] && kill -0 "$RUN_PID" 2>/dev/null; then
        printf 'q\n' >>"$CTL"
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$RUN_PID" 2>/dev/null || break
            sleep 1
        done
        kill "$RUN_PID" 2>/dev/null
    fi
    [ -n "$FEED_PID" ] && kill "$FEED_PID" 2>/dev/null
    [ -n "$SVC_PID" ] && kill "$SVC_PID" 2>/dev/null
    if [ "$MODE" = real ]; then
        sudo docker rm -f tls-lab-server tls-lab-client tls-lab-validator >/dev/null 2>&1
        sudo docker network rm tls-lab-net >/dev/null 2>&1
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'log "interrupted"; exit 130' INT TERM

(
    cd "$RUN_DIR" || exit 1
    tail -n +1 -f "$CTL" | bash ./run_challenges.sh >>"$RUNLOG" 2>&1
    echo "$?" >"$WORK/run.rc"
) &
RUN_PID=$!

MARK=0
mark() { MARK=$(($(wc -c <"$RUNLOG"))); }
since() { tail -c "+$((MARK + 1))" "$RUNLOG" 2>/dev/null | strip; }
drive() { printf '%s\n' "$1" >>"$CTL"; }
alive() { [ ! -f "$WORK/run.rc" ]; }
# wait_for <ERE> <timeout-s> [<fail-ERE>] -> 0 found, 1 fail-ERE, 2 script exited, 3 timeout
wait_for() {
    local re="$1" to="$2" fre="${3:-}" start=$SECONDS out
    while [ $((SECONDS - start)) -lt "$to" ]; do
        out="$(since)"
        printf '%s' "$out" | grep -qE "$re" && return 0
        [ -n "$fre" ] && printf '%s' "$out" | grep -qE "$fre" && return 1
        alive || return 2
        sleep 1
    done
    return 3
}

MENU_RE='Pick a challenge \[1-'
FAIL_RE='never opened within|never reached UDP bootstrap|failed to load|Could not create the'
PROMPT_RE="paste (the recovered secret|this round's secret)"

mark
if wait_for 'All images ready' "$LOAD_TIMEOUT" 'No image tars found|failed to load'; then
    pass "images loaded"
else
    failc "images never loaded"
    tail -n 40 "$RUNLOG" | strip | tee -a "$HLOG"
    exit 100
fi
if wait_for "$MENU_RE" "$MENU_TIMEOUT"; then pass "menu shown (${#MENU_ARR[@]} entries)"; else
    failc "menu never shown"
    exit 100
fi
n_shown="$(since | grep -oE 'Pick a challenge \[1-[0-9]+\]' | head -1 | grep -oE '[0-9]+\]' | tr -d ']')"
if [ "$n_shown" = "${#MENU_ARR[@]}" ]; then pass "menu range is 1-$n_shown"; else failc "menu range 1-$n_shown != CHALLENGE_META count ${#MENU_ARR[@]}"; fi

# ---------------------------------------------------------------------------
# mock-only: assertions on the recorded `docker run`s
# ---------------------------------------------------------------------------
has_arg() { grep -qxF -- "$2" "$MOCK_DOCKER_STATE/runs/$1.args"; }
check_mock_runs() { # check_mock_runs <id>
    local id="$1" c want_cpus n
    for c in tls-lab-server tls-lab-validator tls-lab-client; do
        [ -f "$MOCK_DOCKER_STATE/runs/$c.args" ] || {
            failc "$id: no docker run recorded for $c"
            continue
        }
        has_arg "$c" "--cap-drop=ALL" || failc "$id: $c missing --cap-drop=ALL"
        has_arg "$c" "--read-only" || failc "$id: $c missing --read-only"
        has_arg "$c" "CHALLENGE_ID=$id" || failc "$id: $c missing CHALLENGE_ID=$id"
        has_arg "$c" "no-new-privileges" || failc "$id: $c missing no-new-privileges"
        grep -q ':/run/identity:ro$' "$MOCK_DOCKER_STATE/runs/$c.args" || failc "$id: $c has no read-only /run/identity mount"
        if [ "$c" = tls-lab-server ]; then
            has_arg "$c" "--cap-add=NET_BIND_SERVICE" || failc "$id: server missing --cap-add=NET_BIND_SERVICE"
            case "$id" in server_rsa_hundreds_servers_*) want_cpus=8 ;; *) want_cpus=2 ;; esac
            has_arg "$c" "--cpus=$want_cpus" || failc "$id: server not run with --cpus=$want_cpus"
        else
            has_arg "$c" "--cap-add=NET_BIND_SERVICE" && failc "$id: $c should NOT get NET_BIND_SERVICE"
            has_arg "$c" "--cpus=2" || failc "$id: $c not run with --cpus=2"
        fi
        n="$(cat "$MOCK_DOCKER_STATE/runs/$c.identity" 2>/dev/null || echo 0)"
        # keygen writes {client,server,validator}_{priv,pub}.bin
        if [ "$n" = 6 ]; then :; else
            fail_or_known keygen "$id: $c's /run/identity held $n *.bin file(s), expected 6 (identity rotation skipped)"
        fi
        cat "$MOCK_DOCKER_STATE/runs/$c.identity_dir" 2>/dev/null >>"$WORK/identity_dirs"
    done
    has_arg tls-lab-client "VALIDATOR_HOST=127.0.0.1" || failc "$id: client missing VALIDATOR_HOST"
}

# submit <proof> -> prints the stripped "validator: ..." line, waits for the next prompt
submit() {
    mark
    drive "$1"
    if wait_for 'validator:' 30; then
        since | grep 'validator:' | head -1
    fi
    wait_for "$PROMPT_RE" 30 >/dev/null || true
}

WRONG_PROOF="0000000000000000000000000000000000000000000000000000000000000000"
for id in $IDS; do
    num="$(menu_number "$id")"
    log "-- #$num $id"
    [ "$MODE" = mock ] && rm -f "$MOCK_DOCKER_STATE"/runs/*
    live_to=90
    case "$id" in server_rsa_hundreds_servers_*) live_to=600 ;; esac
    mark
    drive "$num"
    # Resync to THIS challenge's launcher banner before watching for "is live".
    # "is live"/$FAIL_RE are generic (not id-specific), so without this anchor a
    # challenge that never comes up (e.g. an arch-incompatible asset holding the
    # launcher on its own 90s wait, plus the extra menu redisplay) would drift
    # the driver one challenge behind the launcher, and every following
    # challenge would time out against the wrong output until the backlog
    # drained. The banner IS id-specific, so it realigns us each iteration.
    # run_challenges.sh prints: [*] Starting '<id>'...
    if ! wait_for "Starting '$id'" "$MENU_TIMEOUT" "$FAIL_RE"; then
        failc "$id: launcher never announced 'Starting $id' (desync or menu error)"
        wait_for "$MENU_RE" "$MENU_TIMEOUT" >/dev/null
        continue
    fi
    mark # re-anchor: only count "is live"/failure printed AFTER this banner
    wait_for 'is live' $((live_to + 60)) "$FAIL_RE"
    rc=$?
    case "$rc" in
    0) pass "$id is live" ;;
    1)
        failc "$id failed to start: $(since | grep -E "$FAIL_RE" | head -1)"
        since | tail -n 30 >"$LOG_DIR/$id.failure.log"
        wait_for "$MENU_RE" "$MENU_TIMEOUT" >/dev/null
        continue
        ;;
    2)
        failc "run_challenges.sh exited during $id"
        break
        ;;
    3)
        failc "$id never went live"
        drive n
        wait_for "$MENU_RE" "$MENU_TIMEOUT" >/dev/null
        continue
        ;;
    esac
    wait_for "$PROMPT_RE" 30 >/dev/null || failc "$id: proof prompt not shown"

    [ "$MODE" = mock ] && check_mock_runs "$id"

    line="$(submit "$WRONG_PROOF")"
    if [ -z "$line" ]; then
        failc "$id: no validator reply to a wrong proof (validator unreachable?)"
    else
        # No '^' anchor: the captured line can carry a leading "  > " prompt
        # echo (seen on slower runners), which an anchored match would miss and
        # wrongly flag as "not shown as a failure".
        if printf '%s' "$line" | grep -q '\[!\] validator:.*FAIL'; then
            pass "$id: wrong proof shown as a failure"
        else
            fail_or_known verdict "$id: wrong proof not shown as a failure: '$line'"
        fi
    fi
    if [ "$MODE" = mock ]; then
        line="$(submit "$EXPECTED_SECRET")"
        if printf '%s' "$line" | grep -q '\[+\] validator:.*solved'; then
            pass "$id: right proof shown as solved"
        else
            failc "$id: right proof not shown as solved: '$line'"
        fi
    fi

    mark
    drive n
    if wait_for "$MENU_RE" "$MENU_TIMEOUT"; then :; else failc "$id: menu not shown again after 'n'"; fi
done

# ---------------------------------------------------------------------------
# quit and check the teardown
# ---------------------------------------------------------------------------
mark
drive q
for _ in $(seq 1 30); do
    alive || break
    sleep 1
done
if alive; then
    failc "run_challenges.sh still running 30s after 'q'"
else
    rc="$(cat "$WORK/run.rc")"
    if [ "$rc" = 0 ]; then pass "'q' exits 0"; else failc "'q' exited $rc"; fi
fi
RUN_PID=""
since | grep -q 'Done. Bye.' && pass "teardown banner shown" || failc "no 'Done. Bye.' after 'q'"

left="$(dk ps -a --filter 'name=tls-lab-' --format '{{.Names}}' 2>/dev/null | grep -E '^tls-lab-(server|client|validator)$' || true)"
if [ -z "$left" ]; then pass "no lab containers left"; else failc "containers left behind: $(echo $left)"; fi
if dk network inspect tls-lab-net >/dev/null 2>&1; then failc "tls-lab-net network left behind"; else pass "tls-lab-net removed"; fi
if [ "$MODE" = mock ] && [ -f "$WORK/identity_dirs" ]; then
    stale=""
    for d in $(sort -u "$WORK/identity_dirs"); do [ -e "$d" ] && stale="$stale $d"; done
    if [ -z "$stale" ]; then pass "identity temp dirs removed"; else failc "identity temp dirs left:$stale"; fi
fi

[ "$MODE" = mock ] && cp "$MOCK_DOCKER_STATE/calls.log" "$LOG_DIR/mock_docker_calls.log" 2>/dev/null
log "== $FAILS check(s) failed — full launcher output: $RUNLOG"
[ "$FAILS" -gt 100 ] && FAILS=100
exit "$FAILS"
