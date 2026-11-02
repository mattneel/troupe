#!/usr/bin/env sh
# Cooks Troupe for the browser into playground/out.
#
# Popcorn 1.0's WebAssembly VM runs OTP 29, and `mix popcorn.cook` requires
# the same OTP major on the host. The project itself builds and tests on its
# usual toolchain; only this step switches to OTP 29 (via mise by default).
# The dedicated `wasm` Mix environment keeps these OTP 29 artifacts apart
# (_build/wasm and deps/*/_build/wasm) and, like prod, excludes dev/test-only
# dependencies from the bundle.
#
# Override the toolchain wrapper with TROUPE_OTP29, e.g.
#   TROUPE_OTP29="" ./playground/build.sh      # already on OTP 29
set -eu
cd "$(dirname "$0")/.."

wrapper=${TROUPE_OTP29-"mise exec erlang@29 elixir@1.20.2-otp-29 --"}

MIX_ENV=wasm $wrapper mix popcorn.cook --out-dir playground/out
