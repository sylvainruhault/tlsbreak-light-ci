#!/usr/bin/env bash
# static_checks.sh <bundle.zip|bundle_dir> <full|light>
#
# Portability / packaging checks on a student bundle, no Docker needed —
# runs unchanged on ubuntu-latest, macos-latest (/bin/bash 3.2) and
# windows-latest (Git Bash). Written for bash 3.2: no mapfile, no
# associative arrays, no ${x,,}.
#
# Exit status = number of failed checks.
set -u

BUNDLE_IN="${1:?usage: static_checks.sh <bundle.zip|bundle_dir> <full|light>}"
TIER="${2:?usage: static_checks.sh <bundle.zip|bundle_dir> <full|light>}"
case "$TIER" in full | light) ;; *)
    echo "tier must be full or light" >&2
    exit 2
    ;;
esac

FAILS=0
pass() { printf '  PASS  %s\n' "$1"; }
failc() {
    printf '  FAIL  %s\n' "$1"
    FAILS=$((FAILS + 1))
}
check() { # check <description> <command...>
    local d="$1"
    shift
    if "$@" >/dev/null 2>&1; then pass "$d"; else failc "$d"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 1. get an extracted bundle -------------------------------------------
if [ -d "$BUNDLE_IN" ]; then
    B="$BUNDLE_IN"
else
    B="$WORK/bundle"
    mkdir -p "$B"
    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$BUNDLE_IN" -d "$B" || {
            echo "unzip failed" >&2
            exit 2
        }
    else
        # Windows runners without unzip: python's zipfile drops exec bits,
        # exactly like Explorer / Expand-Archive does for a student.
        python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$BUNDLE_IN" "$B" 2>/dev/null ||
            python -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$BUNDLE_IN" "$B" || exit 2
    fi
fi
echo "== static checks: $BUNDLE_IN (tier=$TIER, bash $BASH_VERSION, $(uname -s))"

# --- 2. expected top-level layout ------------------------------------------
for f in run_challenges.sh run_wireshark.sh solve_incomplete.sh run_in_browser.sh \
    Dockerfile.workstation LICENSE THIRD_PARTY_NOTICES; do
    check "ships $f" test -f "$B/$f"
done
# Multi-arch bundles (2026-10-24+) carry images/<arch>/; older ones a flat images/.
ARCHES="$(cd "$B/images" 2>/dev/null && for a in amd64 arm64; do [ -d "$a" ] && printf '%s ' "$a"; done)"
if [ -n "$ARCHES" ]; then
    echo "        image arches: $ARCHES"
    for a in amd64 arm64; do
        for img in tls-lab-server tls-lab-client tls-lab-validator; do
            check "ships images/$a/$img.tar" test -s "$B/images/$a/$img.tar"
        done
    done
else
    for img in tls-lab-server tls-lab-client tls-lab-validator; do
        check "ships images/$img.tar" test -s "$B/images/$img.tar"
    done
fi
if [ "$TIER" = full ]; then
    check "ships manual.pdf" test -s "$B/manual.pdf"
    check "ships solutions/" test -d "$B/solutions"
    check "run_in_browser.sh LAB_TIER_DEFAULT=full" grep -q '^LAB_TIER_DEFAULT=full$' "$B/run_in_browser.sh"
else
    check "ships manual-light.pdf" test -s "$B/manual-light.pdf"
    check "no solutions/ in light" test ! -e "$B/solutions"
    check "run_in_browser.sh LAB_TIER_DEFAULT=light" grep -q '^LAB_TIER_DEFAULT=light$' "$B/run_in_browser.sh"
fi

# --- 3. things that must NEVER ship ------------------------------------------
for f in CLAUDE.md docs assets wordlists wordlist.txt challenges.sh Cargo.toml keys; do
    check "does not ship $f" test ! -e "$B/$f"
done
check "no private key material (*_priv.bin, *.key.pem)" \
    sh -c '! find "$1" \( -name "*_priv.bin" -o -name "*.key.pem" \) | grep -q .' _ "$B"

# --- 4. shell scripts: syntax under THIS bash, LF line endings -------------
for s in "$B"/*.sh; do
    n="$(basename "$s")"
    check "bash -n $n" bash -n "$s"
    check "$n has no CRLF" sh -c '! LC_ALL=C grep -q "$(printf "\r")" "$1"' _ "$s"
done
# run_challenges.sh carries a base64 payload after `exit 0` — only its
# shell part has to be CR-free, which the loop above already covers since
# base64 has no CR either.

# --- 5. generated menu --------------------------------------------------------
META_LINE="$(grep -m1 '^CHALLENGE_META=(' "$B/run_challenges.sh" || true)"
check "CHALLENGE_META placeholder was substituted" sh -c 'test -n "$1" && ! printf %s "$1" | grep -q __CHALLENGE_META__' _ "$META_LINE"
NIDS="$(printf '%s' "$META_LINE" | sed 's/^CHALLENGE_META=(\(.*\))$/\1/' | tr ' ' '\n' | grep -c ':')"
echo "        menu has $NIDS challenges"
check "menu entries are id:level:tls" sh -c \
    'printf %s "$1" | sed "s/^CHALLENGE_META=(\(.*\))$/\1/" | tr " " "\n" | grep . | grep -vqE "^[a-z0-9_]+:([1-4]|meta):[a-z0-9]+$" && exit 1 || exit 0' _ "$META_LINE"
if [ "$TIER" = light ]; then
    check "light menu has no meta_* challenge" sh -c '! printf %s "$1" | grep -q "meta_"' _ "$META_LINE"
    if [ -n "${LIGHT_LIST:-}" ] && [ -f "$LIGHT_LIST" ]; then
        want="$(grep -vE '^[[:space:]]*(#|$)' "$LIGHT_LIST" | sed 's/[[:space:]]//g' | sort)"
        got="$(printf '%s' "$META_LINE" | sed 's/^CHALLENGE_META=(\(.*\))$/\1/' | tr ' ' '\n' | grep . | cut -d: -f1 | sort)"
        check "light menu == \$LIGHT_LIST" test "$want" = "$got"
    fi
elif [ -n "${CHALLENGES_SH:-}" ] && [ -f "$CHALLENGES_SH" ]; then
    want="$(sed -n 's/^CHALLENGES=(\(.*\))$/\1/p' "$CHALLENGES_SH" | tr ' ' '\n' | grep . | sort)"
    got="$(printf '%s' "$META_LINE" | sed 's/^CHALLENGE_META=(\(.*\))$/\1/' | tr ' ' '\n' | grep . | cut -d: -f1 | sort)"
    check "full menu == challenges.sh CHALLENGES" test "$want" = "$got"
fi

# --- 6. embedded keygen payload(s) ------------------------------------------
# One base64 block per arch: __KEYGEN_PAYLOAD_BEGIN__ <arch> ... _END__ <arch>
# (older single-arch bundles: everything after __KEYGEN_PAYLOAD_BELOW__).
case "$(uname -m)" in x86_64 | amd64) HOST_ARCH=amd64 ;; aarch64 | arm64) HOST_ARCH=arm64 ;; *) HOST_ARCH=other ;; esac
b64dec() { base64 -d 2>/dev/null || base64 -D; }
keygen_check() { # keygen_check <label> <file>
    check "keygen payload ($1) base64-decodes to a non-empty file" test -s "$2"
    # ELF magic \x7fELF: a Linux binary, so record (not fail) whether THIS
    # host can run it. On macOS / Git Bash it can't (identity rotation skipped).
    magic="$(head -c 4 "$2" | od -An -c | tr -d ' \n')"
    check "keygen payload ($1) is an ELF binary" test "$magic" = '177ELF'
}
if grep -q '^__KEYGEN_PAYLOAD_BEGIN__ ' "$B/run_challenges.sh"; then
    for a in amd64 arm64; do
        awk -v b="__KEYGEN_PAYLOAD_BEGIN__ $a" -v e="__KEYGEN_PAYLOAD_END__ $a" \
            '$0==b{f=1;next} $0==e{f=0} f' "$B/run_challenges.sh" | b64dec >"$WORK/keygen-$a"
        keygen_check "$a" "$WORK/keygen-$a"
    done
    KG="$WORK/keygen-$HOST_ARCH"
else
    PL="$(awk '/^__KEYGEN_PAYLOAD_BELOW__$/{print NR+1; exit}' "$B/run_challenges.sh")"
    check "keygen payload marker present" test -n "$PL"
    KG="$WORK/keygen"
    if [ -n "$PL" ]; then
        tail -n +"$PL" "$B/run_challenges.sh" | b64dec >"$KG"
        keygen_check single "$KG"
    fi
fi
if [ -s "$KG" ]; then
    chmod +x "$KG" 2>/dev/null
    if (cd "$WORK" && "$KG") >/dev/null 2>&1; then
        echo "  INFO  keygen runs natively on this host"
    else
        echo "  INFO  keygen does NOT run on this host ($(uname -s)/$HOST_ARCH) — identity rotation would be skipped"
    fi
fi

# --- 7. exec bits after extraction (informational on Windows) -----------------
for s in run_challenges.sh run_in_browser.sh run_wireshark.sh solve_incomplete.sh; do
    [ -f "$B/$s" ] || continue
    if [ -x "$B/$s" ]; then
        echo "  INFO  $s is executable after extraction"
    else
        echo "  INFO  $s lost its exec bit after extraction — student must run: bash $s"
    fi
done

# --- 8. shellcheck, if available ----------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
    # run_challenges.sh: only the shell part — everything after the
    # payload marker is base64, which shellcheck parses as garbage.
    # The template's last line is a `# shellcheck disable=` directive aimed
    # at the marker; give it a statement to attach to.
    {
        sed -e '/^__KEYGEN_PAYLOAD_BELOW__$/,$d' -e '/^__KEYGEN_PAYLOAD_BEGIN__ /,$d' "$B/run_challenges.sh"
        echo ':'
    } >"$WORK/run_challenges.shell.sh"
    check "shellcheck -S error run_challenges.sh (shell part)" shellcheck -S error -s bash "$WORK/run_challenges.shell.sh"
    for s in run_in_browser.sh run_wireshark.sh solve_incomplete.sh; do
        [ -f "$B/$s" ] || continue
        check "shellcheck -S error $s" shellcheck -S error -s bash "$B/$s"
    done
else
    echo "  SKIP  shellcheck not installed"
fi

echo "== $FAILS check(s) failed"
exit "$FAILS"
