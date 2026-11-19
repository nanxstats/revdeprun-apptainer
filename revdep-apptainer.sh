#!/bin/bash
#SBATCH --job-name=revdeprun
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --mem=128G
#SBATCH --time=48:00:00
#SBATCH --output=revdeprun-%j.log
#
# Run revdeprun inside the container as a normal user.
#
#   sbatch revdep-apptainer.sh [REPO]   # on a SLURM cluster (edit the limits above)
#   bash revdep-apptainer.sh [REPO]     # anywhere else
#
# REPO defaults to data.table. Environment overrides:
#   SIF        image path (default: ./revdeprun.sif)
#   WORK       big scratch directory, not $HOME (default: ./revdeprun-run)
#   NCPU       parallel workers (default: SLURM_CPUS_PER_TASK, else nproc)
#   APPTAINER  apptainer or singularity binary (default: whichever is on PATH)
set -euo pipefail

REPO=${1:-https://github.com/Rdatatable/data.table.git}
SIF=${SIF:-$PWD/revdeprun.sif}
WORK=${WORK:-$PWD/revdeprun-run}
NCPU=${NCPU:-${SLURM_CPUS_PER_TASK:-$(nproc)}}
APPTAINER=${APPTAINER:-$(command -v apptainer || command -v singularity || true)}

if [ -z "$APPTAINER" ]; then
  echo "error: neither apptainer nor singularity is on PATH (try: module load apptainer)" >&2
  exit 1
fi
if [ ! -f "$SIF" ]; then
  echo "error: image not found: $SIF (set SIF=...)" >&2
  exit 1
fi
mkdir -p "$WORK/apptainer" "$WORK/out"

# Variables for the container: the shim log, plus any proxy settings, because
# --cleanenv drops the host environment.
env_file=$WORK/container.env
echo "SUDO_SHIM_LOG=/out/sudo-shim.log" > "$env_file"
for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
  if [ -n "${!v:-}" ]; then
    printf '%s=%q\n' "$v" "${!v}" >> "$env_file"
  fi
done

# --containall keeps the host $HOME out of reach; --workdir puts the
# container's /tmp, /var/tmp and $HOME on disk instead of in RAM. The package
# clone, revdep library, and check results end up in $WORK/out.
"$APPTAINER" exec --containall --cleanenv \
  --workdir "$WORK/apptainer" \
  --bind "$WORK/out:/out" --pwd /out \
  --env-file "$env_file" \
  "$SIF" \
  revdeprun --skip-r-install --num-workers "$NCPU" "$REPO"
