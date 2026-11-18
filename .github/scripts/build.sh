#!/usr/bin/env bash
set -euo pipefail
mode=${1:-release}
case "$mode" in check|release) ;; *) echo 'Usage: build.sh [check|release]' >&2; exit 2 ;; esac
phase_started=$SECONDS
timing() {
  printf '::notice title=CI timing::%s: %ss\n' "$1" "$((SECONDS - phase_started))"
  phase_started=$SECONDS
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
prefix="${CI_NATIVE_PREFIX:-$PWD/.ci-cache/native}"
mkdir -p "$work/src" "$prefix/lib"
nghttp2_version=1.71.0
unibilium_version=2.1.4
native_target="$(uname -s)-$(uname -m)"
if [[ ! -f "$prefix/lib/libnghttp2.a" || ! -f "$prefix/.nghttp2-version" ]] ||
    [[ $(cat "$prefix/.nghttp2-version") != "$nghttp2_version-$native_target" ]]; then
  url="https://github.com/nghttp2/nghttp2/releases/download/v$nghttp2_version/nghttp2-$nghttp2_version.tar.xz"
  curl -fsSL --retry 3 "$url" -o "$work/nghttp2.tar.xz"
  tar -xJf "$work/nghttp2.tar.xz" -C "$work/src" --strip-components=1
  cmake -S "$work/src" -B "$work/build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_INSTALL_LIBDIR=lib -DENABLE_LIB_ONLY=ON \
    -DBUILD_STATIC_LIBS=ON -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF -DENABLE_FAILMALLOC=OFF -DENABLE_DOC=OFF
  cmake --build "$work/build" --parallel
  cmake --install "$work/build"
  test -f "$prefix/lib/libnghttp2.a"
  printf '%s\n' "$nghttp2_version-$native_target" > "$prefix/.nghttp2-version"
fi
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
export CRYSTAL_LIBRARY_PATH="$prefix/lib"
flags=(--release --no-debug -Dwithout_readline)
if [[ $(uname -s) == Darwin ]]; then
  platform=macos
  for dependency in openssl:libssl.a openssl:libcrypto.a bdw-gc:libgc.a \
    pcre2:libpcre2-8.a libyaml:libyaml.a unibilium:libunibilium.a; do
    formula=$(brew --prefix "${dependency%%:*}")
    install -m 644 "$formula/lib/${dependency#*:}" "$prefix/lib/"
    export PKG_CONFIG_PATH="$PKG_CONFIG_PATH:$formula/lib/pkgconfig"
  done
  flags+=(--link-flags=-Wl,-search_paths_first)
else
  platform=linux
  # Alpine's unibilium can still have the old 4 KiB terminfo limit.
  if [[ ! -f "$prefix/lib/libunibilium.a" || ! -f "$prefix/.unibilium-version" ]] ||
      [[ $(cat "$prefix/.unibilium-version") != "$unibilium_version-$native_target" ]]; then
    url="https://github.com/neovim/unibilium/archive/refs/tags/v$unibilium_version.tar.gz"
    mkdir -p "$work/unibilium"
    curl -fsSL --retry 3 "$url" -o "$work/unibilium.tar.gz"
    tar -xzf "$work/unibilium.tar.gz" -C "$work/unibilium" --strip-components=1
    cmake -S "$work/unibilium" -B "$work/unibilium-build" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
      -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF \
      -DBUILD_MAN_PAGES=OFF -DBUILD_TESTS=OFF -DBUILD_TOOLS=OFF
    cmake --build "$work/unibilium-build" --parallel
    cmake --install "$work/unibilium-build"
    test -f "$prefix/lib/libunibilium.a"
    printf '%s\n' "$unibilium_version-$native_target" > "$prefix/.unibilium-version"
  fi
  flags+=(--static)
fi
timing 'Native libraries'
shards install --frozen
timing 'Shards'
crystal tool format --check src spec tools
if [[ "$platform" == macos ]]; then ameba src spec tools; fi
bash spec/test_runner_spec.sh
timing 'Format, lint and test-runner cache checks'
bash tools/test.sh --profile
timing 'Test compilation and execution'
if [[ "$mode" == check ]]; then
  echo 'Checks passed; release packaging is reserved for tags or manual builds.'
  exit 0
fi
arch=$(uname -m)
[[ "$arch" != arm64 ]] || arch=aarch64
name="minknow-tui-$platform-$arch"
mkdir -p "dist/$name"
binary="dist/$name/minknow-tui"
crystal build src/main.cr "${flags[@]}" -o "$binary"
timing 'Release compilation'
if [[ "$platform" == linux ]]; then
  readelf -h "$binary" >/dev/null
  headers=$(readelf -l "$binary")
  dependencies=$(readelf -d "$binary")
  [[ "$headers" != *INTERP* && "$dependencies" != *NEEDED* ]]
else
  otool -L "$binary"
  while read -r library; do
    case "$library" in
      /usr/lib/*|/System/Library/*) ;;
      *) echo "Nonportable library: $library" >&2; exit 1 ;;
    esac
  done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
fi
"$binary" --version
"$binary" --help
CRYSTERM_DUMP="$work/demo.dump" TERM=xterm-256color "$binary" --demo
grep -q minknow-tui "$work/demo.dump"
cp README.md shard.yml shard.lock "dist/$name/"
{ crystal --version; shards --version; pkg-config --modversion libnghttp2; } > "dist/$name/BUILD-INFO.txt"
tar -czf "dist/$name.tar.gz" -C dist "$name"
timing 'Linkage, startup and packaging'
