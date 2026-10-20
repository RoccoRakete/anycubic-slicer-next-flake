#!/usr/bin/env bash
# Updates version/srcPath/srcHash in flake.nix from Anycubic's APT repo.
#
# Index location: <repo_base>/dists/<dist_codename>/main/binary-<deb_arch>/Packages
# The codename ("noble") comes from the vendor's APT repo layout (the dists/
# directory on the CDN), NOT from the runner OS. Change it here only if the
# vendor renames or replaces that dist.
#
# TLS verification is never disabled. If the vendor CDN serves an expired or
# invalid certificate, this script fails loudly instead of working around it.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
flake_nix="$repo_root/flake.nix"

repo_base="https://cdn-universe-slicer.anycubic.com/prod"
dist_codename="noble"
deb_arch="amd64"
package_name="anycubicslicernext"
packages_url="$repo_base/dists/$dist_codename/main/binary-$deb_arch/Packages"

# Download a URL to stdout, with retries and backoff. On failure print the curl
# exit code and HTTP status (instead of a bare "exit 60") and return non-zero.
fetch() {
  local url="$1" body_file http_code rc=0
  body_file="$(mktemp)"
  http_code="$(curl -sS --location \
    --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 20 \
    --max-time 300 -o "$body_file" -w '%{http_code}' "$url")" || rc=$?
  if [[ $rc -ne 0 || "$http_code" != 2* ]]; then
    echo "Download failed: url=$url curl_exit=$rc http_code=${http_code:-000}" >&2
    if [[ $rc -eq 60 ]]; then
      echo "curl exit 60: TLS certificate not trusted or expired on the server." >&2
    fi
    rm -f "$body_file"
    return 1
  fi
  cat "$body_file"
  rm -f "$body_file"
}

echo "Fetching $packages_url ..."
packages="$(fetch "$packages_url")"

# Pick the stanza for our package AND architecture. Stanzas are separated by
# blank lines; each match is emitted as "version<TAB>filename".
candidates="$(printf '%s\n' "$packages" | awk -v RS= -F'\n' \
  -v want_pkg="$package_name" -v want_arch="$deb_arch" '
  {
    pkg = ""; arch = ""; ver = ""; file = ""
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^Package:/)           { sub(/^Package:[ \t]*/, "", $i);      pkg = $i }
      else if ($i ~ /^Architecture:/) { sub(/^Architecture:[ \t]*/, "", $i); arch = $i }
      else if ($i ~ /^Version:/)      { sub(/^Version:[ \t]*/, "", $i);      ver = $i }
      else if ($i ~ /^Filename:/)     { sub(/^Filename:[ \t]*/, "", $i);     file = $i }
    }
    if (pkg == want_pkg && arch == want_arch) print ver "\t" file
  }')"

count=0
if [[ -n "$candidates" ]]; then
  count="$(printf '%s\n' "$candidates" | wc -l | tr -d ' ')"
fi
if [[ "$count" -ne 1 ]]; then
  echo "Expected exactly 1 '$package_name' ($deb_arch) entry in the Packages index, found $count." >&2
  if [[ -n "$candidates" ]]; then
    printf 'Candidates (version, filename):\n%s\n' "$candidates" >&2
  fi
  exit 1
fi

IFS=$'\t' read -r version filename <<<"$candidates"

if [[ -z "$version" || -z "$filename" ]]; then
  echo "Could not parse Version/Filename from Packages index" >&2
  exit 1
fi

# Filename is stored verbatim: its layout has changed between releases
# (dists/.../develop_AnycubicSlicerNext-*.deb -> pool/.../AnycubicSlicerNext_linux-*.deb).
deb_url="$repo_base/$filename"
echo "Latest version:   $version"
echo "Deb URL:          $deb_url"

echo "Prefetching $deb_url ..."
src_hash="$(nix store prefetch-file --json "$deb_url" | grep -oE '"hash":"[^"]+"' | cut -d'"' -f4)"

if [[ -z "$src_hash" ]]; then
  echo "Failed to prefetch hash for $deb_url" >&2
  exit 1
fi

echo "Hash:             $src_hash"

sed -i \
  -e "s|version = \"[^\"]*\";|version = \"$version\";|" \
  -e "s|srcPath = \"[^\"]*\";|srcPath = \"$filename\";|" \
  -e "s|srcHash = \"[^\"]*\";|srcHash = \"$src_hash\";|" \
  "$flake_nix"

echo "Updated $flake_nix to version $version."
