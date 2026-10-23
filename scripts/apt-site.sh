#!/bin/bash
# Publish immutable package files and signed apt indexes to this repository's gh-pages branch.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SITE_DIR="${SITE_DIR:-$REPO_ROOT/site}"
SITE_BRANCH="gh-pages"
INDEX_ARCHITECTURES="all arm64 armhf"
CHANGED=0
SIGNING_FPR=""
GNUPGHOME=""
TMP_DIR=""

log_info() {
	printf '[INFO] %s\n' "$*"
}

cleanup() {
	[ -z "$GNUPGHOME" ] || rm -rf "$GNUPGHOME"
	[ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT

usage() {
	printf '%s\n' \
		"Usage: apt-site.sh publish-selection <module|all> <debian-version|empty> <testing|stable>" \
		"       apt-site.sh publish-keyring" \
		"       apt-site.sh resign" >&2
	exit 2
}

git_site() {
	local auth
	auth="$(printf 'x-access-token:%s' "${GITHUB_TOKEN:?GITHUB_TOKEN is not set}" | base64 | tr -d '\n')"
	git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $auth" "$@"
}

open_site() {
	local remote="https://github.com/$APT_SITE_REPOSITORY.git" status=0
	[ ! -e "$SITE_DIR" ] || fail "Site work directory already exists: $SITE_DIR"
	log_info "Checking public repository access and whether branch $SITE_BRANCH exists: $APT_SITE_REPOSITORY"
	if git ls-remote --exit-code --heads "$remote" "$SITE_BRANCH"; then
		status=0
	else
		status=$?
	fi
	case "$status" in
		0)
			log_info "Cloning existing $SITE_BRANCH branch from $APT_SITE_REPOSITORY"
			git clone --branch "$SITE_BRANCH" --depth 1 "$remote" "$SITE_DIR"
			;;
		2)
			log_info "Public repository is accessible but has no $SITE_BRANCH branch; initializing it"
			git init --initial-branch "$SITE_BRANCH" "$SITE_DIR"
			git -C "$SITE_DIR" remote add origin "$remote"
			;;
		*) fail "Cannot read $APT_SITE_REPOSITORY (git ls-remote exit status $status). See the preceding Git output; verify the repository URL and public access." ;;
	esac
	git -C "$SITE_DIR" config user.name "github-actions[bot]"
	git -C "$SITE_DIR" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
}

sync_public_files() {
	local keyring_tmp="$SITE_DIR/$KEYRING_NAME.gpg.tmp" index_tmp site_url_replacement
	[ -s "$PUBLIC_KEY" ] || fail "Missing public signing key $PUBLIC_KEY"
	[ -f "$REPO_ROOT/site-config/index.html" ] || fail "Missing public landing page site-config/index.html"
	index_tmp="$(mktemp "$SITE_DIR/.index.html.XXXXXX")"
	site_url_replacement="$(printf '%s' "$APT_SITE_URL" | escape_sed_replacement)"
	sed "s|@APT_SITE_URL@|$site_url_replacement|g" "$REPO_ROOT/site-config/index.html" > "$index_tmp"
	if [ ! -f "$SITE_DIR/index.html" ] || ! cmp -s "$index_tmp" "$SITE_DIR/index.html"; then
		mv "$index_tmp" "$SITE_DIR/index.html"
		CHANGED=1
	else
		rm -f "$index_tmp"
	fi
	if [ ! -f "$SITE_DIR/$KEYRING_NAME.asc" ] || ! cmp -s "$PUBLIC_KEY" "$SITE_DIR/$KEYRING_NAME.asc"; then
		cp "$PUBLIC_KEY" "$SITE_DIR/$KEYRING_NAME.asc"
		CHANGED=1
	fi
	gpg --batch --yes --dearmor --output "$keyring_tmp" "$PUBLIC_KEY"
	if [ ! -f "$SITE_DIR/$KEYRING_NAME.gpg" ] || ! cmp -s "$keyring_tmp" "$SITE_DIR/$KEYRING_NAME.gpg"; then
		mv "$keyring_tmp" "$SITE_DIR/$KEYRING_NAME.gpg"
		CHANGED=1
	else
		rm -f "$keyring_tmp"
	fi
	if [ "$SITE_USES_DEFAULT_GITHUB_PAGES" = yes ]; then
		if [ -e "$SITE_DIR/CNAME" ] || [ -L "$SITE_DIR/CNAME" ]; then
			log_info "Removing stale CNAME for GitHub Pages default host $SITE_HOST"
			rm -f "$SITE_DIR/CNAME"
			CHANGED=1
		fi
	elif [ "$(cat "$SITE_DIR/CNAME" 2>/dev/null)" != "$SITE_HOST" ]; then
		log_info "Setting GitHub Pages custom domain to $SITE_HOST"
		printf '%s\n' "$SITE_HOST" > "$SITE_DIR/CNAME"
		CHANGED=1
	fi
	if [ ! -f "$SITE_DIR/.nojekyll" ]; then
		touch "$SITE_DIR/.nojekyll"
		CHANGED=1
	fi
}

add_deb() {
	local suite="$1" deb="$2" package version architecture target
	package="$(dpkg-deb --field "$deb" Package)"
	version="$(dpkg-deb --field "$deb" Version)"
	architecture="$(dpkg-deb --field "$deb" Architecture)"
	case "$package" in
		*-dkms|sferalabs-archive-keyring) ;;
		*) fail "$deb: unexpected package name $package" ;;
	esac
	[ "$architecture" = all ] || fail "$deb: expected Architecture: all, got $architecture"
	target="$SITE_DIR/pool/$suite/$package/${package}_${version}_${architecture}.deb"
	if [ -e "$target" ]; then
		cmp -s "$deb" "$target" || fail "$package $version already exists in $suite with different bytes; increment its Debian revision"
		return
	fi
	mkdir -p "$(dirname "$target")"
	cp "$deb" "$target"
	CHANGED=1
}

import_signing_key() {
	[ -z "$SIGNING_FPR" ] || return
	[ -s "$PUBLIC_KEY" ] || fail "Missing public signing key $PUBLIC_KEY"
	GNUPGHOME="$(mktemp -d)"
	export GNUPGHOME
	gpg --batch --quiet --import <<<"${APT_SIGNING_KEY:?APT_SIGNING_KEY is not set}"
	SIGNING_FPR="$(gpg --list-secret-keys --with-colons | primary_fingerprint)"
	[ -n "$SIGNING_FPR" ] || fail "APT_SIGNING_KEY contains no signing key"
	gpg --show-keys --with-colons "$PUBLIC_KEY" | awk -F: '$1 == "fpr" { print $10 }' | grep -Fxq "$SIGNING_FPR" \
		|| fail "Signing key does not match $PUBLIC_KEY"
}

gpg_sign() {
	local passphrase="${APT_SIGNING_KEY_PASSPHRASE:-}"
	if [ -n "$passphrase" ]; then
		gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 --digest-algo SHA512 \
			--local-user "$SIGNING_FPR" "$@" 3<<<"$passphrase"
	else
		gpg --batch --yes --pinentry-mode loopback --digest-algo SHA512 \
			--local-user "$SIGNING_FPR" "$@"
	fi
}

index_suite() {
	local suite="$1" dist="dists/$suite" arch
	import_signing_key
	(
		cd "$SITE_DIR"
		mkdir -p "pool/$suite"
		for arch in $INDEX_ARCHITECTURES; do
			mkdir -p "$dist/main/binary-$arch"
			apt-ftparchive packages "pool/$suite" > "$dist/main/binary-$arch/Packages"
			gzip -9 -n -c "$dist/main/binary-$arch/Packages" > "$dist/main/binary-$arch/Packages.gz"
		done
		apt-ftparchive \
			-o "APT::FTPArchive::Release::Origin=Sfera Labs" \
			-o "APT::FTPArchive::Release::Label=Sfera Labs" \
			-o "APT::FTPArchive::Release::Suite=$suite" \
			-o "APT::FTPArchive::Release::Codename=$suite" \
			-o "APT::FTPArchive::Release::Architectures=$INDEX_ARCHITECTURES" \
			-o "APT::FTPArchive::Release::Components=main" \
			-o "APT::FTPArchive::Release::Description=Sfera Labs kernel modules ($suite)" \
			release "$dist" > "$dist/Release.new"
		mv "$dist/Release.new" "$dist/Release"
		gpg_sign --clearsign -o "$dist/InRelease" "$dist/Release"
		gpg_sign --armor --detach-sign -o "$dist/Release.gpg" "$dist/Release"
		gpgv --quiet --keyring "$PWD/$KEYRING_NAME.gpg" "$dist/InRelease"
		gpgv --quiet --keyring "$PWD/$KEYRING_NAME.gpg" "$dist/Release.gpg" "$dist/Release"
	)
}

push_site() {
	git -C "$SITE_DIR" add -A
	git -C "$SITE_DIR" commit -m "$1"
	git_site -C "$SITE_DIR" push origin "$SITE_BRANCH"
}

commit_site() {
	local suite="$1" message="$2"
	sync_public_files
	if [ "$CHANGED" = 0 ]; then
		echo "No repository changes"
		return
	fi
	index_suite "$suite"
	push_site "$message"
}

module_repository_supported() {
	local candidate
	while IFS= read -r candidate; do
		[ "$candidate" = "$1" ] && return 0
	done <<< "$MODULE_CHOICES"
	return 1
}

module_choices_from_workflow() {
	local workflow="$REPO_ROOT/.github/workflows/publish-packages.yml"
	[ -f "$workflow" ] || fail "Module workflow not found: $workflow"
	sed -n '/^[[:space:]]*workflow_dispatch:/,/^[[:space:]]*permissions:/p' "$workflow" |
		sed -n '/^[[:space:]]*inputs:/,/^[[:space:]]*jobs:/p' |
		sed -n '/^[[:space:]]*module:/,/^[[:space:]]*version:/p' |
		sed -n '/^[[:space:]]*options:/,/^[[:space:]]*version:/p' |
		sed -n '/^[[:space:]]*-[[:space:]]*/ {
			s/^[[:space:]]*-[[:space:]]*//
			/^all[[:space:]]*$/d
			p
		}'
}

validate_module_repository() {
	local module_repo="$1" repo_info
	repo_info="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$module_repo")" \
		|| fail "Cannot read public repository $module_repo"
	[ "$(jq -r '.owner.login' <<<"$repo_info")" = sfera-labs ] \
		&& [ "$(jq -r '.private' <<<"$repo_info")" = false ] \
		|| fail "$module_repo must be a public repository owned by sfera-labs"
	MODULE_DEFAULT_BRANCH="$(jq -r '.default_branch' <<<"$repo_info")"
	[ -n "$MODULE_DEFAULT_BRANCH" ] || fail "Cannot determine default branch for $module_repo"
}

latest_release_json() {
	local module_repo="$1" page=1 page_json count
	validate_module_repository "$module_repo"
	: > "$TMP_DIR/releases.jsonl"
	while :; do
		page_json="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
			"https://api.github.com/repos/$module_repo/releases?per_page=100&page=$page")" \
			|| fail "Cannot list releases for $module_repo"
		count="$(jq 'length' <<<"$page_json")"
		[ "$count" -gt 0 ] || break
		printf '%s\n' "$page_json" >> "$TMP_DIR/releases.jsonl"
		page=$((page + 1))
	done
	jq -s '[.[][] | select(.draft == false and .prerelease == false and .published_at != null)] | sort_by(.published_at) | last // empty' \
		"$TMP_DIR/releases.jsonl"
}

download_release_deb() {
	local module_repo="$1" requested_version="$2" output_file="$3"
	local release_json tag module_version module_name expected_package asset_count asset_url
	local package version architecture

	if [ -n "$requested_version" ]; then
		validate_module_repository "$module_repo"
		module_version="${requested_version#*:}"
		module_version="${module_version%-*}"
		tag="v$module_version"
		[[ "$tag" =~ ^v[0-9][A-Za-z0-9.+~_-]*$ ]] || fail "Cannot map Debian version $requested_version to a GitHub release tag"
		release_json="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
			"https://api.github.com/repos/$module_repo/releases/tags/$tag")" \
			|| fail "Cannot find release $tag for $module_repo"
	else
		release_json="$(latest_release_json "$module_repo")"
		[ -n "$release_json" ] || return 2
	fi

	[ "$(jq -r '.draft' <<<"$release_json")" = false ] \
		&& [ "$(jq -r '.prerelease' <<<"$release_json")" = false ] \
		&& [ -n "$(jq -r '.published_at' <<<"$release_json")" ] \
		|| fail "$module_repo release is not published, non-prerelease, and non-draft"
	tag="$(jq -r '.tag_name' <<<"$release_json")"
	[[ "$tag" =~ ^v[0-9][A-Za-z0-9.+~_-]*$ ]] || fail "Release tag must use v<VERSION> format, got $tag"
	module_name="$(curl -fsSL "https://raw.githubusercontent.com/$module_repo/$tag/MODULE_NAME" | tr -d '[:space:]')" \
		|| fail "Cannot read MODULE_NAME from $module_repo@$tag"
	[[ "$module_name" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "Invalid MODULE_NAME in $module_repo@$tag: $module_name"
	expected_package="${module_name}-dkms"
	asset_count="$(jq '[.assets[] | select(.name | endswith(".deb"))] | length' <<<"$release_json")"
	[ "$asset_count" -eq 1 ] || fail "$module_repo@$tag must contain exactly one .deb asset, found $asset_count"
	asset_url="$(jq -r '[.assets[] | select(.name | endswith(".deb"))][0].browser_download_url' <<<"$release_json")"
	curl -fsSL --retry 3 "$asset_url" -o "$output_file" || fail "Cannot download the .deb asset from $module_repo@$tag"
	package="$(dpkg-deb --field "$output_file" Package)"
	version="$(dpkg-deb --field "$output_file" Version)"
	architecture="$(dpkg-deb --field "$output_file" Architecture)"
	[ "$package" = "$expected_package" ] || fail "Unexpected package $package from $module_repo; expected $expected_package"
	[ "$architecture" = all ] || fail "Expected Architecture: all in $output_file"
	if [ -n "$requested_version" ] && [ "$version" != "$requested_version" ]; then
		fail "$module_repo@$tag contains Debian version $version, not requested $requested_version"
	fi
	log_info "Selected $package $version from $module_repo@$tag"
}

module_package_name() {
	local module_repo="$1" module_name
	validate_module_repository "$module_repo"
	module_name="$(curl -fsSL "https://raw.githubusercontent.com/$module_repo/$MODULE_DEFAULT_BRANCH/MODULE_NAME" | tr -d '[:space:]')" \
		|| fail "Cannot read MODULE_NAME from $module_repo@$MODULE_DEFAULT_BRANCH"
	[[ "$module_name" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "Invalid MODULE_NAME in $module_repo@$MODULE_DEFAULT_BRANCH: $module_name"
	printf '%s-dkms' "$module_name"
}

latest_testing_deb() {
	local package="$1" candidate version latest_version="" latest_deb=""
	for candidate in "$SITE_DIR/pool/testing/$package/"*_all.deb; do
		[ -f "$candidate" ] || continue
		version="$(dpkg-deb --field "$candidate" Version)"
		if [ -z "$latest_deb" ] || dpkg --compare-versions "$version" gt "$latest_version"; then
			latest_version="$version"
			latest_deb="$candidate"
		fi
	done
	[ -n "$latest_deb" ] || return 1
	printf '%s' "$latest_deb"
}

add_deb_if_unpublished() {
	local suite="$1" deb="$2" package version target
	package="$(dpkg-deb --field "$deb" Package)"
	version="$(dpkg-deb --field "$deb" Version)"
	target="$SITE_DIR/pool/$suite/$package/${package}_${version}_all.deb"
	if [ -e "$target" ]; then
		if cmp -s "$deb" "$target"; then
			log_info "Skipping $package $version: already published in $suite"
		else
			log_info "Skipping $package $version: already published in $suite with different bytes; existing package retained"
		fi
		return 0
	fi
	add_deb "$suite" "$deb"
}

publish_selection() {
	local module="$1" requested_version="$2" requested_suite="$3"
	local module_repo module_short deb package source selected=0 result
	local -a selected_modules=()
	MODULE_CHOICES="$(module_choices_from_workflow)" || fail "Cannot read module choices from publish-packages.yml"
	[ -n "$MODULE_CHOICES" ] || fail "No module choices found in publish-packages.yml"

	case "$requested_suite" in
		testing|stable) ;;
		*) fail "Suite must be testing or stable, got $requested_suite" ;;
	esac
	if [ -n "$requested_version" ]; then
		dpkg --validate-version "$requested_version" || fail "Invalid Debian package version: $requested_version"
	fi
	if [ "$module" = all ]; then
		[ -z "$requested_version" ] || fail "An exact version cannot be combined with module=all"
		while IFS= read -r module_short; do
			[ -n "$module_short" ] || continue
			selected_modules+=("sfera-labs/$module_short")
		done <<< "$MODULE_CHOICES"
	else
		module_repository_supported "$module" || fail "Unsupported module: $module"
		selected_modules+=("sfera-labs/$module")
	fi

	TMP_DIR="$(mktemp -d)"
	open_site
	for module_repo in "${selected_modules[@]}"; do
		module_short="${module_repo#sfera-labs/}"
		if [ "$requested_suite" = testing ]; then
			deb="$TMP_DIR/${module_short}.deb"
			if download_release_deb "$module_repo" "$requested_version" "$deb"; then
				:
			else
				result=$?
				if [ "$result" -eq 2 ] && [ "$module" = all ]; then
					log_info "Skipping $module_repo: no published non-prerelease release"
					continue
				fi
				fail "$module_repo has no eligible release"
			fi
			add_deb_if_unpublished testing "$deb"
		else
			package="$(module_package_name "$module_repo")"
			if [ -n "$requested_version" ]; then
				source="$SITE_DIR/pool/stable/$package/${package}_${requested_version}_all.deb"
				if [ -e "$source" ]; then
					log_info "Skipping $package $requested_version: already published in stable"
					selected=$((selected + 1))
					continue
				fi
				source="$SITE_DIR/pool/testing/$package/${package}_${requested_version}_all.deb"
			else
				source="$(latest_testing_deb "$package" || true)"
			fi
			if [ -z "$source" ] || [ ! -f "$source" ]; then
				if [ "$module" = all ]; then
					log_info "Skipping $module_repo: no package available in testing"
					continue
				fi
				fail "$package ${requested_version:-<latest>} is not available in testing"
			fi
			add_deb_if_unpublished stable "$source"
		fi
		selected=$((selected + 1))
	done
	commit_site "$requested_suite" "Publish selected module packages to $requested_suite"
	log_info "Processed $selected module package selection(s) for $requested_suite"
}

publish_keyring() {
	local output_dir version target existing_version deb
	output_dir="$(mktemp -d)"
	TMP_DIR="$output_dir"
	bash "$REPO_ROOT/scripts/build-keyring-deb.sh" "$output_dir"
	shopt -s nullglob
	deb=("$output_dir"/*.deb)
	[ "${#deb[@]}" -eq 1 ] || fail "Expected exactly one keyring .deb from builder"
	version="$(dpkg-deb --field "${deb[0]}" Version)"
	add_deb stable "${deb[0]}"
	mkdir -p "$SITE_DIR/bootstrap"
	target="$SITE_DIR/bootstrap/sferalabs-archive-keyring_all.deb"
	if [ -f "$target" ]; then
		existing_version="$(dpkg-deb --field "$target" Version)"
		dpkg --compare-versions "$version" ge "$existing_version" \
			|| fail "Refusing to point keyring bootstrap at older version $version (currently $existing_version)"
	fi
	if [ ! -e "$target" ] || ! cmp -s "${deb[0]}" "$target"; then
		cp "${deb[0]}" "$target"
		CHANGED=1
	fi
	commit_site stable "Publish archive keyring $version"
}

resign_suites() {
	local suite indexed=0
	open_site
	sync_public_files
	for suite in testing stable; do
		[ -d "$SITE_DIR/dists/$suite" ] || continue
		index_suite "$suite"
		indexed=1
	done
	if [ "$CHANGED" = 0 ] && [ "$indexed" = 0 ]; then
		echo "No repository suites or public files to update"
		return
	fi
	push_site "Re-sign apt repository suites"
}

case "${1:-}" in
	publish-selection) [ "$#" -eq 4 ] || fail "Usage: apt-site.sh publish-selection <module|all> <debian-version|empty> <testing|stable>"; publish_selection "$2" "$3" "$4" ;;
	publish-keyring) [ "$#" -eq 1 ] || fail "Usage: apt-site.sh publish-keyring"; open_site; publish_keyring ;;
	resign) [ "$#" -eq 1 ] || fail "Usage: apt-site.sh resign"; resign_suites ;;
	*) usage ;;
esac
