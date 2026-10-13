#!/bin/bash
# Build the bootstrap and upgradeable keyring package from the committed public key.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[ "$#" -eq 1 ] || { echo "Usage: $0 <output-directory>" >&2; exit 2; }
output_dir="$1"
version="$(tr -d '[:space:]' < "$REPO_ROOT/keyring-package/VERSION")"
[ -s "$PUBLIC_KEY" ] || fail "Missing public key: $PUBLIC_KEY"
export SOURCE_DATE_EPOCH=1704067200
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
package_root="$work_dir/package"
install -d "$package_root/DEBIAN" "$package_root/usr/share/keyrings" "$package_root/etc/apt/sources.list.d"

sed "s|@VERSION@|$version|g" "$REPO_ROOT/keyring-package/control.in" > "$package_root/DEBIAN/control"
gpg --batch --yes --dearmor --output "$package_root/usr/share/keyrings/$KEYRING_NAME.gpg" "$PUBLIC_KEY"
sed "s|@APT_SITE_URL@|$APT_SITE_URL|g" \
	"$REPO_ROOT/keyring-package/sferalabs.sources.in" > "$package_root/etc/apt/sources.list.d/sferalabs.sources"
chmod 644 "$package_root/usr/share/keyrings/$KEYRING_NAME.gpg" "$package_root/etc/apt/sources.list.d/sferalabs.sources"

mkdir -p "$output_dir"
dpkg-deb --build --root-owner-group "$package_root" \
	"$output_dir/sferalabs-archive-keyring_${version}_all.deb" >/dev/null
