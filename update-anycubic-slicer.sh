#!/usr/bin/env bash
# Updates version/srcPath/srcHash in flake.nix from Anycubic's APT repo.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
flake_nix="$repo_root/flake.nix"

repo_base="https://cdn-universe-slicer.anycubic.com/prod"
packages_url="$repo_base/dists/noble/main/binary-amd64/Packages"

echo "Fetching $packages_url ..."
packages="$(curl -fsSL "$packages_url")"

version="$(echo "$packages" | grep -m1 '^Version:' | sed 's/^Version: *//')"
filename="$(echo "$packages" | grep -m1 '^Filename:' | sed 's/^Filename: *//')"

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
