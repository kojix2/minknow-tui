#!/usr/bin/env bash
set -euo pipefail
work=$(mktemp -d)
prefix="$work/native"
mkdir -p "$work/src" "$prefix/lib"
url=$(curl -fsSL --retry 3 https://api.github.com/repos/nghttp2/nghttp2/releases/latest |
  jq -er '[.assets[] | select(.name | test("^nghttp2-[0-9.]+\\.tar\\.xz$"))][0].browser_download_url')
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
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
export CRYSTAL_LIBRARY_PATH="$prefix/lib"
flags=(--release --no-debug -Dwithout_readline)
if [[ $(uname -s) == Darwin ]]; then
  platform=macos
  for dependency in openssl:libssl.a openssl:libcrypto.a bdw-gc:libgc.a \
    pcre2:libpcre2-8.a libyaml:libyaml.a unibilium:libunibilium.a; do
    formula=$(brew --prefix "${dependency%%:*}")
    cp "$formula/lib/${dependency#*:}" "$prefix/lib/"
    export PKG_CONFIG_PATH="$PKG_CONFIG_PATH:$formula/lib/pkgconfig"
  done
  flags+=(--link-flags=-Wl,-search_paths_first)
else
  platform=linux
  # Alpine's unibilium can still have the old 4 KiB terminfo limit.
  url=$(curl -fsSL --retry 3 https://api.github.com/repos/neovim/unibilium/releases/latest |
    jq -er .tarball_url)
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
  flags+=(--static)
fi
shards install --frozen
crystal tool format --check src spec tools
if [[ "$platform" == macos ]]; then ameba src spec tools; fi
crystal spec -Dwithout_readline
arch=$(uname -m)
[[ "$arch" != arm64 ]] || arch=aarch64
name="minknow-tui-$platform-$arch"
mkdir -p "dist/$name"
binary="dist/$name/minknow-tui"
crystal build src/main.cr "${flags[@]}" -o "$binary"
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
cd dist
if [[ "$platform" == macos ]]; then
  shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256"
else
  sha256sum "$name.tar.gz" > "$name.tar.gz.sha256"
fi
