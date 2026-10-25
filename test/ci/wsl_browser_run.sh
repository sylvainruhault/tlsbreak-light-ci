#!/usr/bin/env bash
# wsl_browser_run.sh — run as root INSIDE a WSL2 distro on a Windows runner:
# the Option B (run_in_browser.sh) counterpart of wsl_real_run.sh. Sets up
# Docker Engine the way a "docker-ce inside WSL" student does, unzips the
# bundle into the distro's own filesystem, then drives run_in_browser.sh —
# which builds the workstation image on WSL's Docker daemon, serves the
# KasmVNC desktop on 127.0.0.1:6080 INSIDE the distro, and runs
# run_challenges.sh against the nested daemon. This is the Windows student's
# real Option B path: Docker lives in WSL2, so the whole lab (outer daemon +
# the privileged workstation container + its nested daemon) lives there too.
#
#   wsl_browser_run.sh <bundle.zip> <log-dir> [drive_run_in_browser.sh options]
#
# CI_FIRST (passed from Windows via WSLENV) adds --first.
#
# Exit status: the driver's (number of failed checks), or 2 on setup failure.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ZIP="$1"
LOGS="$2"
shift 2
mkdir -p "$LOGS"
LOGS="$(cd "$LOGS" && pwd)"
echo "WSL kernel: $(uname -r)"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null &&
    apt-get install -y -qq docker.io docker-buildx unzip sudo >/dev/null ||
    {
        echo "apt-get install docker.io failed" >&2
        exit 2
    }
if ! docker info >/dev/null 2>&1; then
    (dockerd >"$LOGS/dockerd.log" 2>&1 &)
    for _ in $(seq 1 60); do
        docker info >/dev/null 2>&1 && break
        sleep 2
    done
fi
docker info >/dev/null 2>&1 || {
    echo "dockerd did not start:" >&2
    tail -20 "$LOGS/dockerd.log" >&2
    exit 2
}
echo "docker: $(docker version --format '{{.Server.Version}}')"

B=/root/bundle
rm -rf "$B"
mkdir -p "$B"
unzip -q "$ZIP" -d "$B" || {
    echo "unzip failed" >&2
    exit 2
}
[ -n "${CI_FIRST:-}" ] && set -- "$@" --first "$CI_FIRST"
bash "$HERE/drive_run_in_browser.sh" --bundle "$B" --log-dir "$LOGS" "$@"
