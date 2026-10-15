#!/bin/bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APT_SITE_URL="${APT_SITE_URL:-https://apt.sferalabs.cc}"
APT_SITE_URL="${APT_SITE_URL%/}"
APT_SITE_REPOSITORY="${GITHUB_REPOSITORY:-sfera-labs/apt}"
KEYRING_NAME="sferalabs-archive-keyring"
PUBLIC_KEY="$REPO_ROOT/keys/$KEYRING_NAME.asc"

[[ "$APT_SITE_URL" == https://* ]] || { echo "ERROR: APT_SITE_URL must use HTTPS" >&2; exit 1; }
SITE_HOST="${APT_SITE_URL#https://}"
SITE_HOST="${SITE_HOST%%/*}"
SITE_USES_DEFAULT_GITHUB_PAGES="no"
case "$SITE_HOST" in
	github.io|*.github.io) SITE_USES_DEFAULT_GITHUB_PAGES="yes" ;;
esac

escape_sed_replacement() {
	sed 's/[\\&|]/\\&/g'
}

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

primary_fingerprint() {
	awk -F: '$1 == "fpr" && !seen { print $10; seen = 1 }'
}
