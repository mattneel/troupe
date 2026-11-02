#!/usr/bin/env sh
# Vendors Monaco (the VS Code editor) into playground/vendor/monaco.
#
# The playground is cross-origin isolated (COOP/COEP, needed by Popcorn), so
# the editor and its web workers must be served from the same origin rather
# than a CDN. Only the prebuilt `min/vs` tree of the npm package is kept.
set -eu
cd "$(dirname "$0")"

version=0.57.0
target=vendor/monaco

if [ -f "$target/VERSION" ] && [ "$(cat "$target/VERSION")" = "$version" ]; then
  echo "monaco-editor $version already vendored"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

(cd "$work" && npm pack "monaco-editor@$version" --silent >/dev/null)
tar -xzf "$work"/monaco-editor-"$version".tgz -C "$work" package/min/vs

rm -rf "$target"
mkdir -p "$target"
mv "$work/package/min/vs" "$target/vs"
echo "$version" >"$target/VERSION"
echo "vendored monaco-editor $version into playground/$target"
