#!/usr/bin/env bash
# wsl_real_run.sh — run as root INSIDE a WSL2 distro on a Windows runner:
# set up Docker Engine the way a "docker-ce inside WSL" student does, unzip
# the bundle into the distro's own filesystem (as a student working in their
# WSL home would), then drive its run_challenges.sh for real.
#
#   wsl_real_run.sh <bundle.zip> <log-dir> [drive_run_challenges.sh options]
#
# CI_IDS / CI_FIRST (passed from Windows via WSLENV) add --ids / --first, so
# a space-separated ID list doesn't have to survive wsl.exe's argument quoting.
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
    apt-get install -y -qq docker.io unzip sudo >/dev/null ||
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
[ -n "${CI_IDS:-}" ] && set -- "$@" --ids "$CI_IDS"
[ -n "${CI_FIRST:-}" ] && set -- "$@" --first "$CI_FIRST"
bash "$HERE/drive_run_challenges.sh" --bundle "$B" --mode real --log-dir "$LOGS" "$@"
