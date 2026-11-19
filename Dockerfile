# revdeprun for unprivileged Apptainer/Singularity runs: everything revdeprun
# would install with sudo is installed here, at build time.
#
#   docker build --build-arg PKGS="data.table" -t revdeprun-hpc - < Dockerfile
#
# PKGS: packages whose reverse dependencies' system requirements are baked in.
# R_VERSION: an R-hub version spec such as release, devel, or 4.5.2.

FROM rust:1-bookworm AS build
ARG REVDEPRUN_VERSION=2.4.0
RUN cargo install revdeprun --version "${REVDEPRUN_VERSION}" --locked

FROM ubuntu:24.04
ARG REVDEPRUN_VERSION=2.4.0
ARG R_VERSION=release
ARG PKGS="data.table"
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 TZ=UTC \
    PATH=/opt/TinyTeX/bin/x86_64-linux:$PATH

# apt packages from src/r_install.rs, plus git, jq, and compilers
RUN apt-get update -qq && apt-get install -y \
      ca-certificates curl git jq build-essential gfortran \
      gdebi-core qpdf devscripts ghostscript libcurl4-openssl-dev libssl-dev pandoc \
 && rm -rf /var/lib/apt/lists/*

# Same R-hub/Posit .deb that revdeprun installs
RUN url=$(curl -fsSL "https://api.r-hub.io/rversions/resolve/${R_VERSION}/linux-ubuntu-24.04/x86_64" | jq -r .url) \
 && curl -fsSL -o /tmp/r.deb "$url" \
 && apt-get update -qq && gdebi --non-interactive /tmp/r.deb \
 && ln -sf /opt/R/*/bin/R /usr/local/bin/R \
 && ln -sf /opt/R/*/bin/Rscript /usr/local/bin/Rscript \
 && rm -rf /tmp/r.deb /var/lib/apt/lists/*

# Quarto + TinyTeX. TinyTeX lands in /root/.TinyTeX, which the cluster user
# can't read, so move it to /opt (TinyTeX is relocatable).
RUN v=$(curl -fsSL https://quarto.org/docs/download/_download.json | jq -r .version) \
 && mkdir -p "/opt/quarto/$v" \
 && curl -fsSL "https://github.com/quarto-dev/quarto-cli/releases/download/v$v/quarto-$v-linux-amd64.tar.gz" \
    | tar -xz -C "/opt/quarto/$v" --strip-components=1 \
 && ln -sf "/opt/quarto/$v/bin/quarto" /usr/local/bin/quarto \
 && quarto install tinytex --no-prompt --log-level warning \
 && mv /root/.TinyTeX /opt/TinyTeX && chmod -R a+rX /opt/TinyTeX \
 && pdflatex --version > /dev/null

# System requirements of all revdeps, resolved by revdeprun's own sysreqs.R
RUN set -e; tmp=$(mktemp -d); \
    curl -fsSL -o "$tmp/sysreqs.R" \
      "https://raw.githubusercontent.com/nanxstats/revdeprun/v${REVDEPRUN_VERSION}/assets/r/sysreqs.R"; \
    apt-get update -qq; \
    for pkg in $PKGS; do \
      { echo "pkg_name <- '$pkg'"; echo "install_workers <- 4"; cat "$tmp/sysreqs.R"; } > "$tmp/run.R"; \
      R_LIBS_USER="$tmp/lib" Rscript --vanilla "$tmp/run.R" > "$tmp/sysreqs.json"; \
      jq -r '(.install_scripts, .post_install) | if type == "array" then .[] elif type == "string" then . else empty end' \
        "$tmp/sysreqs.json" > "$tmp/sysreqs.sh"; \
      sh -ex "$tmp/sysreqs.sh"; \
    done; \
    rm -rf "$tmp" /var/lib/apt/lists/*

# No root at run time and everything is preinstalled: log and skip sudo calls.
# Set SUDO_SHIM_LOG to also append each skipped command to a file.
RUN printf '%s\n' '#!/bin/sh' \
      'msg="sudo shim: skipped, no root in this container: $*"' \
      'echo "$msg" >&2' \
      'if [ -n "${SUDO_SHIM_LOG:-}" ]; then echo "$msg" >> "$SUDO_SHIM_LOG"; fi' \
      'exit 0' \
    > /usr/local/bin/sudo \
 && chmod 755 /usr/local/bin/sudo

# Bind target for results, so the bind works even where Apptainer can't create mount points
RUN mkdir -p /out

COPY --from=build /usr/local/cargo/bin/revdeprun /usr/local/bin/revdeprun
