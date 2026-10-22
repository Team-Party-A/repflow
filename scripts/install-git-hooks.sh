#!/bin/sh
set -eu

version=8.30.1
marker='# RepFlow managed gitleaks hook'
fail() { printf '%s\n' "$*" >&2; exit 1; }

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
if git config --get core.hooksPath >/dev/null; then
    fail '检测到 core.hooksPath，自定义钩子保持不变；请先与维护者协调。'
fi
common_dir=$(git rev-parse --git-common-dir)
case "$common_dir" in /*) ;; *) common_dir="$repo_root/$common_dir" ;; esac
hook_path=$(git rev-parse --git-path hooks/pre-commit)
if [ -L "$hook_path" ]; then
    fail 'pre-commit 是符号链接，停止安装以免覆盖。'
fi
if [ -e "$hook_path" ] && ! grep -Fxq "$marker" "$hook_path"; then
    fail '已有其他 pre-commit 钩子，停止安装以免覆盖。'
fi

case "$(uname -s)" in
    Darwin) platform=darwin ;;
    Linux) platform=linux ;;
    *) fail '仅支持 macOS/Linux；Windows 请在 WSL 中执行。' ;;
esac
case "$(uname -m)" in
    arm64|aarch64) architecture=arm64 ;;
    x86_64|amd64) architecture=x64 ;;
    *) fail '仅支持 ARM64/x64。' ;;
esac

tool_dir="$common_dir/repflow-tools/gitleaks/$version"
tool_path="$tool_dir/gitleaks"
download_dir=$(mktemp -d "${TMPDIR:-/tmp}/repflow-gitleaks.XXXXXX")
trap 'rm -rf "$download_dir"' EXIT
trap 'exit 1' HUP INT TERM
if [ ! -x "$tool_path" ]; then
    printf '%s\n' "正在下载并校验 gitleaks ${version}（${platform}/${architecture}）。"
    archive="gitleaks_${version}_${platform}_${architecture}.tar.gz"
    release_url="https://github.com/gitleaks/gitleaks/releases/download/v$version"
    for file in "$archive" "gitleaks_${version}_checksums.txt"; do
        curl --fail --silent --show-error --location --retry 3 \
            --connect-timeout 15 --max-time 600 \
            "$release_url/$file" --output "$download_dir/$file"
    done
    expected=$(awk -v file="$archive" '$2 == file {print $1}' \
        "$download_dir/gitleaks_${version}_checksums.txt")
    [ "${#expected}" -eq 64 ] || fail '官方校验清单缺少有效 SHA-256，停止安装。'
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$download_dir/$archive" | awk '{print $1}')
    else
        actual=$(shasum -a 256 "$download_dir/$archive" | awk '{print $1}')
    fi
    [ "$actual" = "$expected" ] || fail 'gitleaks 下载文件 SHA-256 不匹配，停止安装。'
    tar -xzf "$download_dir/$archive" -C "$download_dir" gitleaks
    mkdir -p "$tool_dir"
    cp "$download_dir/gitleaks" "$tool_path"
    chmod 755 "$tool_path"
fi
[ "$("$tool_path" version)" = "$version" ] || fail '缓存工具版本不匹配，停止安装。'

# 每次提交重新定位仓库，避免把本机绝对路径写入可共享的钩子。
cat > "$download_dir/pre-commit" <<'HOOK'
#!/bin/sh
# RepFlow managed gitleaks hook
set -eu
repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
common_dir=$(git rev-parse --git-common-dir)
case "$common_dir" in /*) ;; *) common_dir="$repo_root/$common_dir" ;; esac
tool_path="$common_dir/repflow-tools/gitleaks/8.30.1/gitleaks"
if [ ! -x "$tool_path" ]; then
    printf '%s\n' '缺少 gitleaks；请执行 sh scripts/install-git-hooks.sh。' >&2
    exit 1
fi
exec "$tool_path" git --pre-commit --staged --redact=100 --verbose \
    --config "$repo_root/.gitleaks.toml" "$repo_root"
HOOK
mkdir -p "$(dirname "$hook_path")"
chmod 755 "$download_dir/pre-commit"
mv "$download_dir/pre-commit" "$hook_path"
printf '%s\n' "已安装 gitleaks $version 和暂存区提交检查。"
