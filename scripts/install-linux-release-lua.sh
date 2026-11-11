#!/usr/bin/env bash
set -euo pipefail

# Debian's original source archive for Lua 5.1.5. Verify before extracting or building.
source_url='https://deb.debian.org/debian/pool/main/l/lua5.1/lua5.1_5.1.5.orig.tar.gz'
source_sha256='2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333'
work_dir=$(mktemp -d "${RUNNER_TEMP:?}/statspro-lua.XXXXXX")
archive="$work_dir/lua-5.1.5.tar.gz"
bin_dir="$work_dir/bin"

curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --retry 2 --retry-max-time 65 --max-time 30 --output "$archive" "$source_url"
printf '%s  %s\n' "$source_sha256" "$archive" | sha256sum --check
tar -xzf "$archive" -C "$work_dir"

source_dir="$work_dir/lua-5.1.5/src"
make -C "$source_dir" -j2 posix
install -d "$bin_dir"
install -m 0755 "$source_dir/lua" "$bin_dir/lua5.1"
install -m 0755 "$source_dir/luac" "$bin_dir/luac5.1"
"$bin_dir/lua5.1" -v
"$bin_dir/luac5.1" -v
printf '%s\n' "$bin_dir" >> "${GITHUB_PATH:?}"
