#!/bin/sh
# 生成不入库的 Config/Local.xcconfig。用法：sh Config/setup-signing.sh <个人后缀> [Team ID]
# Xcode 27 的账号页不显示 Team ID，这里从 Xcode 登录后写入的偏好设置里读。
set -eu

suffix=${1:-}
case "$suffix" in
    "" | *[!a-z0-9]*)
        echo "用法：sh Config/setup-signing.sh <个人后缀，只用小写字母和数字，如 wensharre> [Team ID]" >&2
        exit 1
        ;;
esac

team=${2:-}
if [ -z "$team" ]; then
    teams=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null |
        sed -n 's/^ *teamID = \([A-Z0-9]*\);$/\1/p' | sort -u)
    count=$(printf '%s' "$teams" | grep -c . || true)
    if [ "$count" -eq 0 ]; then
        echo "没读到 Team ID：先在 Xcode → Settings → Apple Accounts 登录 Apple ID，再重跑本脚本" >&2
        exit 1
    elif [ "$count" -gt 1 ]; then
        echo "Xcode 里登录了多个 Team，请把要用的 Team ID 作为第二个参数传入：" >&2
        defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier | grep -E "teamID|teamName" >&2
        exit 1
    fi
    team=$teams
fi

cd "$(dirname "$0")"
cat > Local.xcconfig <<EOF
// 由 setup-signing.sh 生成，不入库
DEVELOPMENT_TEAM = $team
BUNDLE_ID_SUFFIX = .$suffix
EOF
echo "已生成 $(pwd)/Local.xcconfig：Team $team，Bundle ID io.github.teampartya.repflow.$suffix"
