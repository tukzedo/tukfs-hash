# Tools for the slow leak checks: the sanitizers, Miri, the soak and CodeQL.
# Only those run in it. The rest of the pipeline stays on the host.
#
# ctr-image.bash builds it from this dir plus rust-toolchain.toml and
# cicd/tool-pins.env, and tags it with a hash of them, so an edit to any of
# them means a new image. The nightly and CodeQL versions come in as build
# args from tool-pins.env, so that way they're pinned in one place.
# From shcl's cicd/container/Dockerfile, cut down to Rust and CodeQL.
#
# Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
# SPDX-License-Identifier: MIT

FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f

# Apt reads the snapshot the base image was cut from, so a point release
# can't move clang or anything else under the checks.
ARG APT_SNAP=20261005T000000Z
RUN sed -i -e "s|^URIs: http://deb.debian.org/debian-security|URIs: http://snapshot.debian.org/archive/debian-security/${APT_SNAP}|" \
		-e "s|^URIs: http://deb.debian.org/debian\$|URIs: http://snapshot.debian.org/archive/debian/${APT_SNAP}|" \
		-e 's|^Signed-By:|Check-Valid-Until: no\nSigned-By:|' /etc/apt/sources.list.d/debian.sources \
	&& ! grep -q deb.debian.org /etc/apt/sources.list.d/debian.sources

# gcc links, and builds SQLite for the soak. clang builds it for the
# sanitizers, since its instrumentation is the same LLVM family rustc's
# runtime is. llvm-symbolizer names the frames in a report, and nm shows the
# SQLite objects were instrumented.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		bash ca-certificates curl git xz-utils unzip file jq binutils \
		gcc libc6-dev clang-19 llvm-19 \
	&& rm -rf /var/lib/apt/lists/*

# Stable from rust-toolchain.toml, with its components, so rustup never
# reaches for the network at run time. Then the dated nightly, with rust-src
# for -Zbuild-std and Miri. Miri's std is built here once.
ARG RUSTUP_VER=1.29.1
ARG RUSTUP_SHA256=dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71
ARG NIGHTLY
ARG JOBS=1
ENV RUSTUP_HOME=/opt/rustup MIRI_SYSROOT=/opt/miri-sysroot
COPY rust-toolchain.toml /opt/rustup-pin/
RUN test -n "${NIGHTLY}" \
	&& curl -fsSLo /tmp/rustup-init "https://static.rust-lang.org/rustup/archive/${RUSTUP_VER}/x86_64-unknown-linux-gnu/rustup-init" \
	&& echo "${RUSTUP_SHA256}  /tmp/rustup-init" | sha256sum -c - \
	&& chmod +x /tmp/rustup-init \
	&& export CARGO_HOME=/opt/cargo CARGO_BUILD_JOBS="${JOBS}" \
	&& /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain none \
	&& cd /opt/rustup-pin \
	&& /opt/cargo/bin/rustup toolchain install \
	&& /opt/cargo/bin/rustup default "$(/opt/cargo/bin/rustup show active-toolchain | cut -d' ' -f1)" \
	&& /opt/cargo/bin/rustup toolchain install "${NIGHTLY}" --profile minimal --component rust-src,miri \
	&& cd / && /opt/cargo/bin/cargo "+${NIGHTLY}" miri setup \
	&& rm -rf /opt/cargo/registry /tmp/rustup-init

# The bundle, since the bare CLI has no query packs and would fetch them at
# run time. Only Rust and C/C++ are kept.
ARG CODEQL_VER
ARG CODEQL_SHA256
WORKDIR /tmp/dl
RUN test -n "${CODEQL_VER}" && test -n "${CODEQL_SHA256}" \
	&& curl -fsSLo codeql.tgz "https://github.com/github/codeql-action/releases/download/codeql-bundle-v${CODEQL_VER}/codeql-bundle-linux64.tar.gz" \
	&& echo "${CODEQL_SHA256}  codeql.tgz" | sha256sum -c - \
	&& tar -C /opt -xzf codeql.tgz \
	&& for l in actions csharp go java javascript python ruby swift; do rm -rf "/opt/codeql/${l}" /opt/codeql/qlpacks/codeql/"${l}"-*; done \
	&& ln -s /opt/codeql/codeql /usr/local/bin/codeql \
	&& langs="$(codeql resolve languages --format=text | cut -d' ' -f1 | tr '\n' ' ')" \
	&& for l in cpp rust; do case " ${langs}" in *" ${l} "*) ;; *) echo "codeql has no ${l}: ${langs}"; exit 1 ;; esac; done \
	&& cd / && rm -rf /tmp/dl
WORKDIR /

# Runs as the caller's uid, which has no passwd entry here. CARGO_HOME, HOME
# and TMPDIR are set per run to dirs mounted from the host.
ENV PATH=/opt/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	LANG=C.UTF-8
