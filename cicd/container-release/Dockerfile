# The release builds, both targets, so the glibc they need is this image's
# and not the box's. Debian 10 has glibc 2.28, which RHEL 8, Debian 10 and
# Ubuntu 18.10 onward all have, and a binary built against it keeps working
# on anything newer. arm64 is cross-built with Debian's own cross gcc and
# libc, and run under qemu-user for its checks.
#
# ctr-image.bash builds it from this dir plus rust-toolchain.toml, and tags it
# with a hash of them, so an edit to either means a new image.
#
# Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
# SPDX-License-Identifier: MIT

FROM debian:buster-slim@sha256:bb3dc79fddbca7e8903248ab916bb775c96ec61014b3d02b4f06043b604726dc

# Buster is archived, so apt reads the snapshot the base image names, which
# also keeps gcc and libc from moving under the bytes.
ARG APT_SNAP=20240612T000000Z
RUN printf 'deb http://snapshot.debian.org/archive/debian/%s buster main\ndeb http://snapshot.debian.org/archive/debian-security/%s buster/updates main\ndeb http://snapshot.debian.org/archive/debian/%s buster-updates main\n' \
		"${APT_SNAP}" "${APT_SNAP}" "${APT_SNAP}" > /etc/apt/sources.list \
	&& apt-get -o Acquire::Check-Valid-Until=false update \
	&& apt-get install -y --no-install-recommends \
		bash ca-certificates curl file binutils gcc libc6-dev \
		gcc-aarch64-linux-gnu libc6-dev-arm64-cross qemu-user-static \
	&& rm -rf /var/lib/apt/lists/*

# Stable from rust-toolchain.toml, with its components, so rustup never
# reaches for the network at run time, plus the arm64 std.
ARG RUSTUP_VER=1.29.1
ARG RUSTUP_SHA256=dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71
ENV RUSTUP_HOME=/opt/rustup
COPY rust-toolchain.toml /opt/rustup-pin/
RUN curl -fsSLo /tmp/rustup-init "https://static.rust-lang.org/rustup/archive/${RUSTUP_VER}/x86_64-unknown-linux-gnu/rustup-init" \
	&& echo "${RUSTUP_SHA256}  /tmp/rustup-init" | sha256sum -c - \
	&& chmod +x /tmp/rustup-init \
	&& export CARGO_HOME=/opt/cargo \
	&& /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain none \
	&& cd /opt/rustup-pin \
	&& /opt/cargo/bin/rustup toolchain install \
	&& /opt/cargo/bin/rustup target add aarch64-unknown-linux-gnu \
	&& /opt/cargo/bin/rustup default "$(/opt/cargo/bin/rustup show active-toolchain | cut -d' ' -f1)" \
	&& rm -rf /opt/cargo/registry /tmp/rustup-init

# Runs as the caller's uid, which has no passwd entry here. CARGO_HOME, HOME
# and TMPDIR are set per run to dirs mounted from the host.
ENV PATH=/opt/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	LANG=C.UTF-8 \
	CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
	CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc \
	AR_aarch64_unknown_linux_gnu=aarch64-linux-gnu-ar \
	CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUNNER="qemu-aarch64-static -L /usr/aarch64-linux-gnu"
