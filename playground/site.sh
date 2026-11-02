#!/usr/bin/env sh
# Assembles the static playground site (after ./playground/build.sh and
# ./playground/vendor.sh) into DIR, ready for any static host such as
# GitHub Pages.
#
#   ./playground/site.sh _site
set -eu
cd "$(dirname "$0")"

dir=${1:?usage: playground/site.sh DIR}
case "$dir" in /*) ;; *) dir="$OLDPWD/$dir" ;; esac

if [ ! -f out/index.mjs ]; then
  echo "playground/out is missing; run ./playground/build.sh first" >&2
  exit 1
fi

if [ ! -f vendor/monaco/vs/loader.js ]; then
  echo "playground/vendor/monaco is missing; run ./playground/vendor.sh first" >&2
  exit 1
fi

rm -rf "$dir"
mkdir -p "$dir"
cp index.html app.js style.css coi-serviceworker.js "$dir/"
cp -R out "$dir/out"
cp -R vendor "$dir/vendor"
# GitHub Pages: serve files as-is (no Jekyll processing).
touch "$dir/.nojekyll"
