#!/bin/bash
# Fail the build when the product would be signed ad-hoc ("-") or not at all.
# An ad-hoc signature changes on every build, which revokes the TCC grants
# (Full Disk Access, Accessibility) and breaks the privileged helper.
#
# Xcode exposes the resolved identity in two variables:
#   EXPANDED_CODE_SIGN_IDENTITY      the certificate SHA-1, or "-" for ad-hoc
#   EXPANDED_CODE_SIGN_IDENTITY_NAME the display name, "Sign to Run Locally"
#                                    for ad-hoc
# Only the first one is reliable, so check it first.
set -euo pipefail

allowed="${CODE_SIGNING_ALLOWED:-YES}"
if [ "${allowed}" != "YES" ]; then
	echo "error: code signing is disabled (CODE_SIGNING_ALLOWED=${allowed}). MacTools must be signed with a real identity." >&2
	exit 1
fi

hash="${EXPANDED_CODE_SIGN_IDENTITY:-}"
name="${EXPANDED_CODE_SIGN_IDENTITY_NAME:-${CODE_SIGN_IDENTITY:-}}"

case "${hash}" in
-)
	echo "error: ad-hoc signing identity. Set CODE_SIGN_IDENTITY to a real certificate, for example 'Apple Development'." >&2
	exit 1
	;;
esac

case "${name}" in
"" | "-" | "Sign to Run Locally")
	echo "error: ad-hoc or empty signing identity ('${name}'). Set CODE_SIGN_IDENTITY to a real certificate, for example 'Apple Development'." >&2
	exit 1
	;;
esac

if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
	echo "error: DEVELOPMENT_TEAM is empty. The helper and the app must share a team identifier." >&2
	exit 1
fi

echo "signing identity: ${name} (team ${DEVELOPMENT_TEAM})"
