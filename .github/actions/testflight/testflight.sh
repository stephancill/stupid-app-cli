#!/bin/bash
# Builds the app unsigned, asks the broker for a release session (the owner approves it with a
# passkey), then fetches signing material, bumps the build number, archives and uploads through
# the session. The session URL carries its secret: it is masked and never echoed.
set -euo pipefail
export PATH="${HOME}/.local/bin:${PATH}"
broker="${BROKER%/}"

fail() { echo "::error::$1" >&2; exit 1; }
[ -f stupid-app.yml ] || fail "no stupid-app.yml in $(pwd)"
[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || fail "the job needs permissions: id-token: write"

oidc_token() {
  curl -fsS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${broker}" | jq -r .value
}

# Bundle ids: the app and every extension (`bundleID:` keys), and the marketing version and
# build number from the app's Info.plist.
mapfile -t bundles < <(sed -nE 's/^[[:space:]]*-?[[:space:]]*bundleID:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/p' stupid-app.yml)
[ ${#bundles[@]} -gt 0 ] || fail "no bundleID in stupid-app.yml"
info_path=$(sed -nE 's/^infoPath:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/p' stupid-app.yml)
plist_value() { python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))[sys.argv[2]])' "${info_path}" "$1"; }
version=$(plist_value CFBundleShortVersionString)
current_build=$(plist_value CFBundleVersion)

# Release sessions need stupid-app 0.0.31 or later (`signing fetch`, STUPID_APP_RELEASE_SESSION).
stupid-app signing fetch --help >/dev/null 2>&1 \
  || fail "$(stupid-app --version | head -1) predates release sessions; the store's stupid-app package is stale"

echo "::group::Unsigned build"
stupid-app build
echo "::endgroup::"

body=$(jq -n --arg v "${version}" '{bundle_ids: $ARGS.positional, version: $v, build_number: "next"}' --args "${bundles[@]}")
created=$(curl -sS -X POST "${broker}/v1/release/sessions" \
  -H "Authorization: Bearer $(oidc_token)" -H "Content-Type: application/json" -d "${body}")
session_id=$(jq -r '.session_id // empty' <<<"${created}")
[ -n "${session_id}" ] || fail "the broker refused the release session: ${created}"
echo "Waiting for approval of ${bundles[*]} ${version} in the vault app (${broker}/approve/release/${session_id})"

deadline=$(( $(date +%s) + APPROVAL_TIMEOUT_MINUTES * 60 ))
session_url=""
while [ -z "${session_url}" ]; do
  [ "$(date +%s)" -lt "${deadline}" ] || fail "not approved within ${APPROVAL_TIMEOUT_MINUTES} minutes"
  sleep 5
  polled=$(curl -sS "${broker}/v1/release/sessions/${session_id}" -H "Authorization: Bearer $(oidc_token)")
  status=$(jq -r '.status // empty' <<<"${polled}")
  case "${status}" in
    PENDING_APPROVAL) ;;
    APPROVED|ACTIVE)
      session_url=$(jq -r '.session_url // empty' <<<"${polled}")
      [ -n "${session_url}" ] || fail "approved, but the session URL was already handed out" ;;
    *) fail "release session ${status:-failed}: ${polled}" ;;
  esac
done
echo "::add-mask::${session_url}"
export STUPID_APP_RELEASE_SESSION="${session_url}"
close_session() { curl -sS -o /dev/null -X DELETE "${STUPID_APP_RELEASE_SESSION}" || true; }
trap close_session EXIT
echo "Approved"

stupid-app signing fetch

# The next build number: after the latest upload, and never below the checked-in one.
next=$(stupid-app release new-build)
if [ "${current_build}" -gt "${next}" ] 2>/dev/null; then next="${current_build}"; fi
if [ "${next}" != "${current_build}" ]; then
  stupid-app release bump --build-number "${next}"
  if [ "${COMMIT_BUILD_NUMBER}" = "true" ]; then
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git commit -qam "chore: bump build to ${next}"
    git push -q origin "HEAD:${GITHUB_REF}"
  fi
fi
echo "Releasing ${version} (${next})"

stupid-app release archive
stupid-app release upload --wait
