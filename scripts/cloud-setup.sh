#!/bin/bash
# Gets a throwaway x86-64 Ubuntu 24.04 machine (a Claude Code cloud session, a CI runner) ready to
# change an iOS app and check it end to end, with no Mac: the Swift toolchain, stupid-app, its
# device and simulator Swift SDKs, and (through stupid simulator) an iOS simulator with stupidsim.
#
#   curl -fsSL -o cloud-setup.sh https://raw.githubusercontent.com/stephancill/stupid-app-cli/main/scripts/cloud-setup.sh
#   bash cloud-setup.sh
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

# The rest downloads in parallel: stupid simulator's setup (the longest part: its own packages, then
# the simulator's runtime parts) and the SDK archives run in the background while the toolchain
# downloads here. apt above finished first, so stupid simulator's apt-get does not meet ours on
# dpkg's lock. Each background part logs to its own file and is waited for, and its exit status
# checked, before the script ends.
background=$(mktemp -d)
# A failure here stops the background parts too, rather than leaving them running.
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
toolchain="${prefix}/share/swift-${swift_version}"

# The simulator: stupid simulator's runtime store, x86Sim, stupidsim and a booted-once device.
curl -fsSL -o "${background}/stupidsim-setup.sh" \
  https://raw.githubusercontent.com/stephancill/stupid-simulator/main/linux/cloud-setup.sh
bash "${background}/stupidsim-setup.sh" > "${background}/stupidsim.log" 2>&1 &
stupidsim_pid=$!

# The device and simulator Swift SDKs from Xcode, exported by `stupid-app sdk export`: downloaded
# now, imported once the toolchain and stupid-app are in place. One already imported is skipped.
sdks=$(get sdks/current.txt)
(
  for sdk in ${sdks}; do
    name="${sdk%%=*}"
    if "${toolchain}/usr/bin/swift" sdk list 2>/dev/null | grep -qx "${name%%-arm64-*}"; then continue; fi
    get "sdks/${name}.artifactbundle.tar.zst" > "${background}/${name}.tar.zst"
  done
) > "${background}/sdks.log" 2>&1 &
sdks_pid=$!

# The Swift toolchain, unpacked under ${prefix}/share/swift-<version> and linked onto PATH.
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

if ! wait "${sdks_pid}"; then
  echo "downloading the SDKs failed:" >&2; cat "${background}/sdks.log" >&2; exit 1
fi
for sdk in ${sdks}; do
  name="${sdk%%=*}"; sha="${sdk#*=}"
  [ -f "${background}/${name}.tar.zst" ] || continue  # already imported
  stupid-app sdk import "${background}/${name}.tar.zst" --expected-sha256 "${sha}" >/dev/null
  rm -f "${background}/${name}.tar.zst"
  step "imported ${name%%-arm64-*}"
done

if wait "${stupidsim_pid}"; then status=0; else status=$?; fi
sed 's/^/stupid simulator: /' "${background}/stupidsim.log"
if [ "${status}" != 0 ]; then
  echo "stupid simulator's setup failed (status ${status}); its output is above" >&2; exit "${status}"
fi
rm -rf "${background}"
step "cloud setup done; boot with: stupidsim-linux boot, then in an app: stupid-app run --simulator"
