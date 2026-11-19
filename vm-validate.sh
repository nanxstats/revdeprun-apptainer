#!/bin/bash
# End-to-end validation on the VM, as the unprivileged test user from vm-setup.sh:
#
#   sudo -iu hpcuser bash vm-validate.sh https://github.com/OWNER/SMALLPKG.git
#
# SMALLPKG must be one of the packages the image was built for (vm-setup.sh).
# Runs preflight.sh, a smoke revdep run, and post-run checks. Exits non-zero
# if any check fails.
set -uo pipefail

REPO=${1:?usage: bash vm-validate.sh https://github.com/OWNER/SMALLPKG.git}
HERE=$(cd "$(dirname "$0")" && pwd)
export SIF=${SIF:-$HERE/revdeprun.sif}
export WORK=${WORK:-$HOME/revdeprun-run}
export APPTAINER=${APPTAINER:-$(command -v apptainer || command -v singularity || true)}
LOG=$WORK/smoke.log

failures=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }
note() { printf 'NOTE  %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }

if [ -e "$WORK/out" ]; then
  echo "$WORK/out exists from an earlier run; for a fresh run remove it with:" >&2
  echo "  chmod -R u+w '$WORK' && rm -rf '$WORK'" >&2
  exit 2
fi

section "This user is like a cluster user"
if sudo -n true 2> /dev/null; then
  fail "$(id -un) can use sudo; run this as the unprivileged test user (sudo -iu hpcuser ...)"
else
  pass "$(id -un) has no sudo on the host"
fi

if ! bash "$HERE/preflight.sh"; then
  echo "Preflight failed; fix that before the smoke run." >&2
  exit 1
fi

home_had_r=no
if [ -e "$HOME/R" ] || [ -e "$HOME/.cache/R" ]; then
  home_had_r=yes
fi

section "Smoke run: $REPO"
mkdir -p "$WORK"
echo "Full log: $LOG"
bash "$HERE/revdep-apptainer.sh" "$REPO" 2>&1 | tee "$LOG"
run_status=${PIPESTATUS[0]}

section "Results"
if [ "$run_status" -eq 0 ] && grep -q 'Reverse dependency check finished successfully' "$LOG"; then
  pass "revdeprun finished successfully as uid $(id -u) inside the container"
else
  fail "revdeprun exited with status $run_status; see $LOG"
fi

shim_log=$WORK/out/sudo-shim.log
if [ -s "$shim_log" ]; then
  pass "$(wc -l < "$shim_log" | tr -d ' ') sudo call(s) went to the shim and were skipped:"
  sed 's/^/      /' "$shim_log"
else
  note "no sudo calls were made, so the system requirements path was not exercised; pick a package whose revdeps need system libraries"
fi

pattern='cannot open shared object file|cannot find -l'
lib_hits=$(grep -rlE "$pattern" "$WORK/out" --include=00install.out 2> /dev/null || true)
log_hits=$(grep -E "$pattern" "$LOG" | head -n 20 || true)
if [ -z "$lib_hits" ] && [ -z "$log_hits" ]; then
  pass "no missing system library errors"
else
  fail "possible missing system libraries (missing from the image, hidden by the shim):"
  [ -n "$lib_hits" ] && printf '%s\n' "$lib_hits" | sed 's/^/      /'
  [ -n "$log_hits" ] && printf '%s\n' "$log_hits" | sed 's/^/      /'
fi

if [ "$home_had_r" = yes ]; then
  note "\$HOME/R or \$HOME/.cache/R existed before the run, so host \$HOME isolation was not checked"
elif [ -e "$HOME/R" ] || [ -e "$HOME/.cache/R" ]; then
  fail "R wrote into the host \$HOME (~/R or ~/.cache/R): --containall did not isolate it"
else
  pass "host \$HOME untouched (no ~/R or ~/.cache/R)"
fi

clone=$(find "$WORK/out" -mindepth 1 -maxdepth 1 -type d ! -name revdeprun-work -print -quit 2> /dev/null)
if [ -z "$clone" ]; then
  fail "no package clone found under $WORK/out"
elif compgen -G "$clone/*.Rcheck" > /dev/null || compgen -G "$clone/*.Rcheck2" > /dev/null ||
  [ -e "$clone/00check_diffs.md" ]; then
  if "$APPTAINER" exec --containall --cleanenv --bind "$WORK/out:/out" --pwd /out "$SIF" \
       revdeprun bundle "$(basename "$clone")"; then
    pass "bundle written under $WORK/out (revdeprun prints it as /out/..., the path inside the container)"
  else
    fail "revdeprun bundle failed"
  fi
else
  note "no check differences, so there is nothing to bundle"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
  echo "All checks passed."
else
  echo "$failures check(s) failed."
fi
[ "$failures" -eq 0 ]
