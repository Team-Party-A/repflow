#!/bin/sh
set -eu
# 只在可丢弃的 Linux CI runner 安装；服务器使用 apt 软件包。
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64)
        buildx_arch=amd64 compose_arch=x86_64
        buildx_sha=e25d5cd675092bb5d1d03632fdc46cdf3fede7b514dc5f023a105e00d3ce5ad4
        compose_sha=47737f4236e6d3ccea7291995203f8f018058783b4c3a9469119811a0b5db8c0 ;;
    Linux/aarch64)
        buildx_arch=arm64 compose_arch=aarch64
        buildx_sha=3b83b3731916ba433feccaaa689fe5bcdc81c641d92c8e6c2ea865dfa141c97a
        compose_sha=42cfa75f51ad0ccf290bad37899e0038a8c10a0069e85233ecc1d53e3ff1347d ;;
    *) printf 'This installer requires a Linux amd64/arm64 CI runner.\n' >&2; exit 1 ;;
esac
: "${CI:?This installer is only for CI}"
scratch_dir=$(mktemp -d)
trap 'rm -rf "$scratch_dir"' EXIT
trap 'exit 130' HUP INT TERM
curl -fsSL --retry 3 "https://github.com/docker/buildx/releases/download/v0.38.1/buildx-v0.38.1.linux-$buildx_arch" -o "$scratch_dir/docker-buildx"
curl -fsSL --retry 3 "https://github.com/docker/compose/releases/download/v5.6.1/docker-compose-linux-$compose_arch" -o "$scratch_dir/docker-compose"
printf '%s  %s\n' "$buildx_sha" "$scratch_dir/docker-buildx" "$compose_sha" "$scratch_dir/docker-compose" | sha256sum -c -
plugin_dir="$HOME/.docker/cli-plugins"
mkdir -p "$plugin_dir"
install -m 0755 "$scratch_dir/docker-buildx" "$plugin_dir/docker-buildx"
install -m 0755 "$scratch_dir/docker-compose" "$plugin_dir/docker-compose"
docker buildx version
docker compose version
