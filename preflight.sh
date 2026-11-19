#!/bin/bash
# Preflight checks for running revdeprun in the container as a normal user.
#
# On a cluster, run it on a compute node, not a login node:
#   srun -c 2 -t 00:30:00 bash preflight.sh
#
# Environment overrides:
#   SIF        image path (default: ./revdeprun.sif)
#   WORK       scratch directory for the real run (default: ./revdeprun-run)
#   APPTAINER  apptainer or singularity binary (default: whichever is on PATH)
#
# Exits non-zero if any check fails.
set -uo pipefail

SIF=${SIF:-$PWD/revdeprun.sif}
WORK=${WORK:-$PWD/revdeprun-run}
APPTAINER=${APPTAINER:-$(command -v apptainer || command -v singularity || true)}

failures=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }
note() { printf 'NOTE  %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }
indent() { sed 's/^/      /'; }

section "Host"
if [ -n "${SLURM_JOB_ID:-}" ]; then
  pass "inside SLURM job $SLURM_JOB_ID on $(hostname)"
else
  note "not inside a SLURM job; on a cluster, run this on a compute node with srun"
fi
arch=$(uname -m)
if [ "$arch" = x86_64 ]; then
  pass "architecture $arch"
else
  fail "architecture $arch: the image and revdeprun's Quarto download are x86_64 only"
fi
if [ -z "$APPTAINER" ]; then
  fail "neither apptainer nor singularity is on PATH (try: module load apptainer)"
  exit 1
fi
pass "$("$APPTAINER" --version)"
if [ ! -f "$SIF" ]; then
  fail "image not found: $SIF (set SIF=...)"
  exit 1
fi
pass "image $SIF"

section "No root inside the container"
uid=$("$APPTAINER" exec "$SIF" id -u 2>/dev/null || true)
if [ -n "$uid" ] && [ "$uid" != 0 ]; then
  pass "container runs as uid $uid, not root"
else
  fail "could not run the container as a normal user (uid: ${uid:-none})"
fi
out=$("$APPTAINER" exec "$SIF" apt-get install -y hello 2>&1)
if printf '%s\n' "$out" | grep -qiE 'permission denied|are you root|read-only file system'; then
  pass "apt-get install is refused in the container, so revdeprun's sudo steps can't work here"
else
  note "unexpected apt-get result: $(printf '%s\n' "$out" | tail -n 1)"
fi

section "Tools in the image"
for tool in "R --version" "quarto --version" "pdflatex --version" "revdeprun --version"; do
  # shellcheck disable=SC2086 # split "tool --flag" into words on purpose
  if out=$("$APPTAINER" exec --containall --cleanenv "$SIF" $tool 2>&1); then
    pass "$(printf '%s\n' "$out" | head -n 1)"
  else
    fail "$tool failed: $(printf '%s\n' "$out" | tail -n 1)"
  fi
done

section "Container /tmp and \$HOME on disk, results directory writable"
pre=$WORK/preflight
mkdir -p "$pre/apptainer" "$pre/out"
# shellcheck disable=SC2016 # $HOME must expand inside the container
if out=$("$APPTAINER" exec --containall --cleanenv --workdir "$pre/apptainer" \
          --bind "$pre/out:/out" --pwd /out "$SIF" \
          sh -c 'touch /out/write-test && stat -f -c %T /tmp && stat -f -c %T "$HOME"' 2>&1); then
  tmp_fs=$(printf '%s\n' "$out" | sed -n 1p)
  home_fs=$(printf '%s\n' "$out" | sed -n 2p)
  if [ -e "$pre/out/write-test" ]; then
    pass "bound results directory is writable from the container"
  else
    fail "write to /out did not reach $pre/out"
  fi
  for pair in "/tmp:$tmp_fs" "\$HOME:$home_fs"; do
    if [ "${pair#*:}" = tmpfs ]; then
      fail "container ${pair%%:*} is tmpfs (in RAM) despite --workdir"
    else
      pass "container ${pair%%:*} is on disk (${pair#*:})"
    fi
  done
else
  fail "container failed with --workdir/--bind: $(printf '%s\n' "$out" | tail -n 1)"
fi

section "Network from inside the container"
env_file=$pre/container.env
: > "$env_file"
for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
  if [ -n "${!v:-}" ]; then
    printf '%s=%q\n' "$v" "${!v}" >> "$env_file"
  fi
done
env_args=()
if [ -s "$env_file" ]; then
  env_args=(--env-file "$env_file")
  note "forwarding proxy settings from this shell: $(cut -d= -f1 "$env_file" | tr '\n' ' ')"
fi
check_url() { # level url purpose
  if "$APPTAINER" exec --containall --cleanenv ${env_args[@]+"${env_args[@]}"} "$SIF" \
       curl -fsS -o /dev/null --max-time 60 "$2" 2>/dev/null; then
    pass "reachable: $2"
  elif [ "$1" = required ]; then
    fail "unreachable: $2 ($3)"
  else
    note "unreachable: $2 ($3)"
  fi
}
check_url required https://packagemanager.posit.co/cran/latest/src/contrib/PACKAGES "R packages and metadata"
check_url required https://github.com "cloning the package; pak system requirements data"
check_url optional https://bioconductor.org/config.yaml "Bioconductor version map used by pak"
check_url optional https://cloud.r-project.org "some revdep tests contact CRAN"

section "Resources (compare with what the real run needs)"
note "CPUs visible: $(nproc); SLURM_CPUS_PER_TASK=${SLURM_CPUS_PER_TASK:-unset}; SLURM_MEM_PER_NODE=${SLURM_MEM_PER_NODE:-unset} (MB)"
note "space and inodes of the file system holding $WORK:"
df -h "$WORK" | indent
df -i "$WORK" | indent
note "also check your quota for both space and file count (e.g. lfs quota -h -u ${USER:-$(id -un)} <mount> on Lustre)"

rm -rf "$pre"

printf '\n'
if [ "$failures" -eq 0 ]; then
  echo "Preflight passed."
else
  echo "Preflight: $failures check(s) failed."
fi
[ "$failures" -eq 0 ]
