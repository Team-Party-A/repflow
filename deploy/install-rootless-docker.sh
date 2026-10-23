#!/bin/sh
set -eu
if [ "$(id -u)" = 0 ]; then printf 'Run as the SSH user with sudo, not root.\n' >&2; exit 1; fi
. /etc/os-release
if [ "$ID/$VERSION_ID/$(dpkg --print-architecture)" != ubuntu/26.04/amd64 ]; then
    printf 'This installer is reviewed for Ubuntu 26.04 amd64 only.\n' >&2; exit 1
fi
for service_name in docker.service docker.socket containerd.service; do
    if systemctl is-active --quiet "$service_name"; then
        printf 'Existing system service %s is active; review it before installation.\n' "$service_name" >&2
        exit 1
    fi
done
scratch_dir=$(mktemp -d)
trap 'rm -rf "$scratch_dir"' EXIT
trap 'exit 130' HUP INT TERM
apt_get() {
    sudo apt-get -o APT::Update::Error-Mode=any -o Acquire::Retries=3 \
        -o Acquire::https::Pipeline-Depth=0 -o Acquire::https::User-Agent=curl "$@"
}
apt_get update
apt_get install -y --no-install-recommends ca-certificates curl uidmap dbus-user-session slirp4netns
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$scratch_dir/docker.asc"
cat > "$scratch_dir/docker.sources" <<'SOURCE'
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: resolute
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
SOURCE
sudo install -d -m 0755 /etc/apt/keyrings
sudo install -m 0644 "$scratch_dir/docker.asc" /etc/apt/keyrings/docker.asc
sudo install -m 0644 "$scratch_dir/docker.sources" /etc/apt/sources.list.d/docker.sources
# 软件包安装可能启动系统服务，提前屏蔽，只运行所选的用户级 Docker。
sudo systemctl mask docker.service docker.socket containerd.service
apt_get update
engine_version='5:29.9.2-1~ubuntu.26.04~resolute'
apt_get install -y --no-install-recommends \
    "docker-ce=$engine_version" "docker-ce-cli=$engine_version" \
    "docker-ce-rootless-extras=$engine_version" \
    'containerd.io=2.4.2-3~ubuntu.26.04~resolute' \
    'docker-buildx-plugin=0.38.1-1~ubuntu.26.04~resolute' \
    'docker-compose-plugin=5.6.1-1~ubuntu.26.04~resolute'
sudo apt-mark hold docker-ce docker-ce-cli docker-ce-rootless-extras \
    containerd.io docker-buildx-plugin docker-compose-plugin
dockerd-rootless-setuptool.sh install
systemctl --user enable --now docker
sudo loginctl enable-linger "$(id -un)"
docker --context rootless info --format 'Engine={{.ServerVersion}} Security={{json .SecurityOptions}}'
docker --context rootless compose version
docker --context rootless buildx version
