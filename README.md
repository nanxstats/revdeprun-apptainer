# Validating revdeprun under Apptainer/Singularity without root

A scratch kit for checking that revdeprun can run as an unprivileged user
inside an Apptainer/Singularity container, as on a SLURM cluster. It is not
part of the revdeprun package.

Stock revdeprun can't do this: even with `--skip-r-install`, the
system-requirements step runs `sudo sh -c ...`, and `sudo` can't gain root
inside Apptainer. The image here preinstalls everything revdeprun would
install and replaces `sudo` with a shim that logs and skips the call.

| File                  | Runs where                         | What it does                                                                                                     |
| --------------------- | ---------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `Dockerfile`          | anywhere with Docker and root      | Image with R, Quarto, pandoc, TinyTeX, the revdeps' system requirements, the `sudo` shim, and revdeprun.          |
| `vm-setup.sh`         | VM, as the default sudo user       | Installs Docker and Apptainer, builds `revdeprun.sif`, creates the unprivileged `hpcuser`.                        |
| `vm-validate.sh`      | VM, as `hpcuser`                   | Runs `preflight.sh`, a smoke revdep run, and post-run checks, printing PASS/FAIL.                                 |
| `preflight.sh`        | VM or a cluster compute node       | Checks that the container has no root, the tools run, `/tmp` and `$HOME` are on disk, and the network is reachable. |
| `revdep-apptainer.sh` | VM, or the cluster via `sbatch`    | Runs `revdeprun --skip-r-install` in the container.                                                               |

## 1. Validate on a VM

Use a fresh Ubuntu 24.04 x86_64 VM with about 8 vCPU, 32 GB RAM, and 100 GB
disk. Pick a small package (`SMALLPKG`) whose reverse dependencies need some
system libraries, so the sudo path gets exercised.

```bash
ssh ubuntu@HOST
git clone https://github.com/nanxstats/revdeprun-apptainer.git
cd revdeprun-apptainer && bash vm-setup.sh SMALLPKG
tmux new -s revdep    # the smoke run takes a while
sudo -iu hpcuser bash vm-validate.sh https://github.com/OWNER/SMALLPKG.git
```

`vm-validate.sh` exits non-zero if any check fails. To run it again, first
remove the previous run as `hpcuser`:

```bash
sudo -iu hpcuser sh -c 'chmod -R u+w revdeprun-run && rm -rf revdeprun-run'
```

## 2. Run on the cluster

Get `revdeprun.sif` onto the cluster: copy it from the VM, or build it on any
machine with Docker and root:

```bash
docker build --build-arg PKGS="data.table" -t revdeprun-hpc - < Dockerfile
docker save revdeprun-hpc > revdeprun-hpc.tar
apptainer build revdeprun.sif docker-archive://revdeprun-hpc.tar
```

Build close to the run: the list of system requirements is fixed at build time.
On Apple Silicon, use `docker buildx build --platform linux/amd64 ...`.

Then, from a directory on scratch with `revdeprun.sif`, `preflight.sh`, and
`revdep-apptainer.sh`:

```bash
export WORK=$PWD/revdeprun-run      # scratch, not $HOME
srun -c 2 -t 00:30:00 bash preflight.sh

# Optional smoke run with a small package first
WORK=$PWD/revdeprun-smoke sbatch -c 8 -t 04:00:00 revdep-apptainer.sh https://github.com/OWNER/SMALLPKG.git

# Real run: edit the #SBATCH limits in revdep-apptainer.sh first
sbatch revdep-apptainer.sh          # data.table by default

# When it finishes
apptainer exec --containall --bind "$WORK/out:/out" --pwd /out revdeprun.sif \
  revdeprun bundle data.table
```

The bundle lands in `$WORK/out/`. revdeprun prints it as `/out/...`, which is
the path inside the container. Skipped sudo calls are logged in
`$WORK/out/sudo-shim.log`.
