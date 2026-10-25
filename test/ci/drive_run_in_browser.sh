#!/usr/bin/env bash
# drive_run_in_browser.sh — unattended run of a student bundle's Option B,
# ./run_in_browser.sh, the way a student uses it: start it, wait for the
# workstation image to build and the desktop to come up, then — standing in
# for "open a Terminal in the desktop" — drive /lab/run_challenges.sh inside
# the container against its nested Docker daemon, and finally press Ctrl-C.
#
#   test/ci/drive_run_in_browser.sh --bundle <dir> [options]
#
#   --ids "a b c" / --first N   passed to drive_run_challenges.sh (default --first 2)
#   --log-dir D                 where to write the logs (default: a fresh temp dir)
#   BUILD_TIMEOUT=S             seconds allowed for build + desktop start (default 7200)
#
# Checks:
#   - the desktop answers on http://localhost:6080 with the lab's KasmVNC
#     page (lab-branding.js injected) before BUILD_TIMEOUT
#   - the launcher tried to open that URL in a browser (open/xdg-open are
#     shimmed: nothing really opens on a runner)
#   - the container is --privileged and its port is bound to 127.0.0.1 only
#   - the nested Docker daemon comes up, and drive_run_challenges.sh --mode
#     real passes inside the container (its logs land in <log-dir>/inside/)
#   - Ctrl-C (SIGINT to the launcher's process group, as a terminal sends
#     it) tears the container down and the launcher exits
#
# Exit status: number of failed checks (capped at 100). Bash 3.2-compatible.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE=""
LOG_DIR=""
DRIVER_ARGS=""
BUILD_TIMEOUT="${BUILD_TIMEOUT:-7200}"
while [ $# -gt 0 ]; do
    case "$1" in
    --bundle)
        BUNDLE="$2"
        shift 2
        ;;
    --ids)
        DRIVER_ARGS="--ids"
        IDS="$2"
        shift 2
        ;;
    --first)
        DRIVER_ARGS="--first"
        IDS="$2"
        shift 2
        ;;
    --log-dir)
        LOG_DIR="$2"
        shift 2
        ;;
    -h | --help)
        sed -n '2,26p' "$0"
        exit 0
        ;;
    *)
        echo "unknown option: $1" >&2
        exit 2
        ;;
    esac
done
[ -n "$DRIVER_ARGS" ] || {
    DRIVER_ARGS="--first"
    IDS=2
}
[ -n "$BUNDLE" ] && [ -f "$BUNDLE/run_in_browser.sh" ] || {
    echo "--bundle <dir with run_in_browser.sh> required" >&2
    exit 2
}
BUNDLE="$(cd "$BUNDLE" && pwd)"
[ -n "$LOG_DIR" ] || LOG_DIR="$(mktemp -d)"
mkdir -p "$LOG_DIR"
LOG_DIR="$(cd "$LOG_DIR" && pwd)"
HLOG="$LOG_DIR/driver.log"
RLOG="$LOG_DIR/run_in_browser.log"
: >"$HLOG"

FAILS=0
log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$HLOG"; }
pass() { log "  PASS  $*"; }
failc() {
    log "  FAIL  $*"
    FAILS=$((FAILS + 1))
}
finish() {
    log "result: $FAILS failed check(s)"
    [ "$FAILS" -gt 100 ] && FAILS=100
    exit "$FAILS"
}

TIER="$(sed -n 's/^LAB_TIER_DEFAULT=\([a-z]*\).*/\1/p' "$BUNDLE/run_in_browser.sh" | head -1)"
C="tls-lab-workstation-$TIER"
URL="http://localhost:6080"
log "bundle: $BUNDLE   tier: $TIER   host: $(uname -s)   bash: $BASH_VERSION"
# The launcher starts with `docker rm -fv $C`: never let a local run destroy
# someone's live workstation session.
if sudo docker ps -a --format '{{.Names}}' | grep -qx "$C"; then
    echo "refusing: container $C already exists (a live workstation session?) and run_in_browser.sh would remove it" >&2
    exit 2
fi

# Browser shims: record what the launcher tries to open.
SHIM="$(mktemp -d)"
OPENED="$SHIM/opened.log"
for b in open xdg-open; do
    printf '#!/bin/sh\necho "$0 $*" >>"%s"\n' "$OPENED" >"$SHIM/$b"
    chmod +x "$SHIM/$b"
done
printf '#!/bin/sh\nexit 1\n' >"$SHIM/xdg-settings" # no default browser configured
chmod +x "$SHIM/xdg-settings"

# Own process group (set -m), so Ctrl-C can be simulated the way a terminal
# sends it: SIGINT to the whole foreground group (launcher + sudo docker wait).
set -m
(cd "$BUNDLE" && PATH="$SHIM:$PATH" exec bash ./run_in_browser.sh) </dev/null >"$RLOG" 2>&1 &
RIB=$!
set +m
log "run_in_browser.sh started (pid $RIB), allowing ${BUILD_TIMEOUT}s for build + desktop"

up=0
start=$(date +%s)
while [ $(($(date +%s) - start)) -lt "$BUILD_TIMEOUT" ]; do
    if ! kill -0 "$RIB" 2>/dev/null; then
        failc "run_in_browser.sh exited before the desktop came up; last lines:"
        tail -30 "$RLOG" | tee -a "$HLOG"
        finish
    fi
    if grep -q 'Workstation running' "$RLOG" && curl -fsS -o /dev/null "$URL/" 2>/dev/null; then
        up=1
        break
    fi
    sleep 10
done
log "waited $(($(date +%s) - start))s"
if [ "$up" = 1 ]; then pass "desktop answers on $URL"; else
    failc "desktop not up after ${BUILD_TIMEOUT}s; last lines:"
    tail -30 "$RLOG" | tee -a "$HLOG"
    kill -INT -- "-$RIB" 2>/dev/null
    finish
fi

if curl -fsS "$URL/" 2>/dev/null | grep -q 'lab-branding.js'; then pass "page is the lab's KasmVNC (branding injected)"; else failc "page at $URL lacks lab-branding.js"; fi
if grep -q "$URL" "$OPENED" 2>/dev/null; then pass "launcher opened the URL: $(head -1 "$OPENED")"; else failc "launcher never tried to open $URL"; fi
[ "$(sudo docker inspect -f '{{.HostConfig.Privileged}}' "$C" 2>/dev/null)" = true ] &&
    pass "container is --privileged" || failc "container is not --privileged"
pb="$(sudo docker inspect -f '{{json .HostConfig.PortBindings}}' "$C" 2>/dev/null)"
case "$pb" in *'"HostIp":"127.0.0.1"'*) pass "port bound to 127.0.0.1 only: $pb" ;; *) failc "port binding not loopback-only: $pb" ;; esac

# "Open a Terminal in the desktop": drive run_challenges.sh inside.
nested=0
for _ in $(seq 1 60); do
    sudo docker exec "$C" docker info >/dev/null 2>&1 && {
        nested=1
        break
    }
    sleep 2
done
if [ "$nested" = 1 ]; then
    pass "nested Docker daemon is up"
    sudo docker exec "$C" rm -rf /tmp/ci /tmp/ci-logs
    sudo docker cp "$HERE" "$C:/tmp/ci" >/dev/null
    log "driving /lab/run_challenges.sh inside the container ($DRIVER_ARGS $IDS)"
    sudo docker exec "$C" bash /tmp/ci/drive_run_challenges.sh --bundle /lab --mode real \
        "$DRIVER_ARGS" "$IDS" --log-dir /tmp/ci-logs 2>&1 | sed 's/^/    | /' >>"$HLOG"
    rc="${PIPESTATUS[0]}"
    grep '^    | ' "$HLOG" | grep -E 'PASS|FAIL|WARN|check\(s\) failed' | tail -40
    sudo docker cp "$C:/tmp/ci-logs" "$LOG_DIR/inside" >/dev/null 2>&1
    if [ "${rc:-x}" = 0 ]; then pass "run_challenges.sh inside the workstation: all checks passed"; else
        failc "run_challenges.sh inside the workstation: ${rc:-unknown} failed check(s) (see inside/)"
    fi
else
    failc "nested Docker daemon never came up"
    sudo docker logs --tail 30 "$C" 2>&1 | tee -a "$HLOG"
fi

log "pressing Ctrl-C"
kill -INT -- "-$RIB" 2>/dev/null
gone=0
for _ in $(seq 1 60); do
    kill -0 "$RIB" 2>/dev/null || {
        gone=1
        break
    }
    sleep 1
done
[ "$gone" = 1 ] && pass "launcher exited on Ctrl-C" || {
    failc "launcher still running 60s after Ctrl-C"
    kill -KILL -- "-$RIB" 2>/dev/null
}
if sudo docker ps -a --format '{{.Names}}' | grep -qx "$C"; then
    failc "container $C left behind"
    sudo docker rm -fv "$C" >/dev/null 2>&1
else pass "container torn down"; fi
grep -q 'nothing left running' "$RLOG" && pass "launcher printed its teardown message" || failc "no teardown message in run_in_browser.log"
rm -rf "$SHIM"
finish
