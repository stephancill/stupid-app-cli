#!/bin/bash
# Gets a throwaway x86-64 Ubuntu 24.04 machine (a Claude Code cloud session, a CI runner) ready to
# change an iOS app and check it end to end, with no Mac: the Swift toolchain, stupid-app, its
# device and simulator Swift SDKs, and (through stupid simulator) an iOS simulator with stupidsim.
#
#   curl -fsSL https://raw.githubusercontent.com/stephancill/stupid-app-cli/main/scripts/cloud-setup.sh \
#     | bash
#
# Then, at the start of each session:   stupidsim-linux boot
# and in an app's directory:             stupid-app run --simulator
#
# Everything comes from stupid simulator's public store: swift.org's own download host is not
# reachable from Claude Code cloud sessions, so the toolchain is mirrored there (checked against
# swift.org's signature when it was mirrored, and against its SHA-256 here). The simulator fetches
# the iOS runtime files an app needs the first time it opens them (stupid simulator 0.7.0 and
# later), so any app runs; STUPIDSIM_APPS optionally names recorded runtime manifests to fetch up
# front (stupid simulator's cloud-setup.sh).
set -euo pipefail
started=$(date +%s)
swift_version=6.4.2
public="${STUPIDSIM_PUBLIC_STORE:-https://stupidsim-store.stupidtech.net}"
# Networks that block that host (Claude Code cloud sessions refuse it with a CONNECT 403) still allow
# R2's S3 endpoint: read there with the store's read-only key, public on purpose (the bucket is
# publicly readable and the key cannot write), as stupid simulator's cloud-setup.sh does.
read_endpoint="https://2e6717908caccc8ef5eebae01beea4aa.r2.cloudflarestorage.com/stupidsim-runtimes"
read_key="71491aa6318f16f4ae12eb220ed03ca4:690014e1c18add82944fae4abc6da4601dd819342007bb0eb4fb5e37e5f7dc57"
if curl -fsS --max-time 15 -o /dev/null "${public}/current.json" 2>/dev/null; then reach=public; else reach=signed; fi
get() {
  if [ "${reach}" = public ]; then
    curl -fsS --retry 3 --retry-all-errors "${public}/$1"
  else
    curl -fsS --retry 3 --retry-all-errors --aws-sigv4 "aws:amz:auto:s3" --user "${read_key}" "${read_endpoint}/$1"
  fi
}
step() { echo "$1 ($(( $(date +%s) - started )) s)"; }

if [ "$(id -u)" = 0 ]; then prefix=/usr/local; sudo=""; else prefix="${HOME}/.local"; sudo="sudo"; fi
mkdir -p "${prefix}/bin"
export PATH="${prefix}/bin:${PATH}"

# Swift's own Ubuntu 24.04 dependencies (swift.org's install page), and zstd for the SDK archives.
packages=(binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libncurses-dev
  libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev libz3-dev pkg-config tzdata unzip
  zlib1g-dev zstd libssl3)
missing=()
for p in "${packages[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if [ ${#missing[@]} -gt 0 ]; then
  ${sudo} env DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null
  ${sudo} env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
  step "installed ${missing[*]}"
fi

# The Swift toolchain, unpacked under ${prefix}/share/swift-<version> and linked onto PATH.
toolchain="${prefix}/share/swift-${swift_version}"
if ! "${toolchain}/usr/bin/swift" --version 2>/dev/null | grep -q "Swift version ${swift_version}"; then
  key="toolchains/swift-${swift_version}-RELEASE-ubuntu24.04.tar.gz"
  expected=$(get "${key}.sha256" | cut -d' ' -f1)
  work=$(mktemp -d)
  get "${key}" > "${work}/swift.tar.gz"
  echo "${expected}  ${work}/swift.tar.gz" | sha256sum -c --quiet
  rm -rf "${toolchain}" && mkdir -p "${toolchain}"
  tar -xzf "${work}/swift.tar.gz" -C "${toolchain}" --strip-components=1 --no-same-owner
  rm -rf "${work}"
  step "installed Swift ${swift_version}"
fi
for tool in swift swiftc; do ln -sf "${toolchain}/usr/bin/${tool}" "${prefix}/bin/${tool}"; done

# stupid-app and stupid-app-macros (the open stand-in for Xcode's macOS-only SwiftUI,
# SwiftData and Preview macro plugins), Swift's standard library linked in statically.
work=$(mktemp -d)
get packages/stupid-app-linux-x86_64.tar.gz | tar -xz -C "${work}" --no-same-owner
install -m 755 "${work}/stupid-app" "${prefix}/bin/stupid-app"
install -m 755 "${work}/stupid-app-macros" "${prefix}/bin/stupid-app-macros"
rm -rf "${work}"
step "installed $(stupid-app --version)"

# The device and simulator Swift SDKs from Xcode, exported by `stupid-app sdk export`.
for sdk in $(get sdks/current.txt); do
  name="${sdk%%=*}"; sha="${sdk#*=}"
  if swift sdk list 2>/dev/null | grep -qx "${name%%-arm64-*}"; then continue; fi
  work=$(mktemp -d)
  get "sdks/${name}.artifactbundle.tar.zst" > "${work}/sdk.tar.zst"
  stupid-app sdk import "${work}/sdk.tar.zst" --expected-sha256 "${sha}" >/dev/null
  rm -rf "${work}"
  step "imported ${name%%-arm64-*}"
done

# The simulator: stupid simulator's runtime store, x86Sim, stupidsim and a booted-once device.
curl -fsSL https://raw.githubusercontent.com/stephancill/stupid-simulator/main/linux/cloud-setup.sh | bash
step "cloud setup done; boot with: stupidsim-linux boot, then in an app: stupid-app run --simulator"
