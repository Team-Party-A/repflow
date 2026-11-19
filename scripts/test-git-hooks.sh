#!/bin/sh
set -eu

source_root=$(git rev-parse --show-toplevel)
common_dir=$(git rev-parse --git-common-dir)
case "$common_dir" in /*) ;; *) common_dir="$source_root/$common_dir" ;; esac
scanner="$common_dir/repflow-tools/gitleaks/8.30.1/gitleaks"
[ -x "$scanner" ] || { printf '%s\n' '请先安装本地钩子。' >&2; exit 1; }
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/repflow-hook-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
trap 'exit 1' HUP INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
commit() { git -c user.name='RepFlow hook tests' -c user.email='test@example.invalid' \
    -c commit.gpgsign=false commit -qm "$1"; }
blocked_commit() {
    before=$(git rev-parse HEAD)
    if commit "$1" > "$test_dir/commit.log" 2>&1; then fail "$1 被错误接受"; fi
    [ "$(git rev-parse HEAD)" = "$before" ] || fail "$1 改变了 HEAD"
}

# 独立仓库与合成值避免触碰开发者的暂存区和实际凭据。
mkdir "$test_dir/repo with spaces"
cd "$test_dir/repo with spaces"
git init -q
printf '%s\n' 'clean baseline' > README.md
git add README.md
commit baseline
cp "$source_root/.gitleaks.toml" .
mkdir -p scripts .git/repflow-tools/gitleaks/8.30.1
cp "$source_root/scripts/install-git-hooks.sh" scripts/
cp "$scanner" .git/repflow-tools/gitleaks/8.30.1/gitleaks
sh scripts/install-git-hooks.sh >/dev/null
cp .git/hooks/pre-commit "$test_dir/managed-hook"
sh scripts/install-git-hooks.sh >/dev/null
cmp .git/hooks/pre-commit "$test_dir/managed-hook" || fail '重复安装改变钩子'
pass '带空格路径安装与幂等性'

printf '%s\n' 'clean change' > README.md
git add README.md
commit clean > "$test_dir/commit.log" 2>&1
pass '干净提交通过'

synthetic=$(openssl rand -hex 32)
printf 'api_key = "%s"\n' "$synthetic" > sample.txt
git add sample.txt
printf '%s\n' 'worktree is clean, index is not' > sample.txt
blocked_commit 'staged synthetic value'
grep -q 'generic-api-key' "$test_dir/commit.log" || fail '未命中预期规则'
if grep -Fq "$synthetic" "$test_dir/commit.log"; then fail '日志未完全脱敏'; fi
pass '暂存区假密钥被拦截且日志脱敏'

git add sample.txt
printf 'api_key = "%s"\n' "$synthetic" > sample.txt
commit 'clean index only' > "$test_dir/commit.log" 2>&1
pass '只扫描暂存区，不把未暂存内容混进提交'
git restore sample.txt

printf '%s\n' 'pending clean content' > sample.txt
git add sample.txt
mv .git/repflow-tools/gitleaks/8.30.1/gitleaks "$test_dir/scanner"
blocked_commit 'missing scanner'
grep -q '缺少 gitleaks' "$test_dir/commit.log" || fail '缺少工具时未给出恢复命令'
mv "$test_dir/scanner" .git/repflow-tools/gitleaks/8.30.1/gitleaks
pass '缺少工具时阻止提交'

printf '%s\n' 'this is invalid TOML [' > .gitleaks.toml
blocked_commit 'invalid config'
cp "$source_root/.gitleaks.toml" .
pass '扫描执行失败时阻止提交'

printf '#!/bin/sh\nexit 0\n' > .git/hooks/pre-commit
cp .git/hooks/pre-commit "$test_dir/other-hook"
if sh scripts/install-git-hooks.sh > "$test_dir/install.log" 2>&1; then
    fail '覆盖了已有钩子'
fi
cmp .git/hooks/pre-commit "$test_dir/other-hook" || fail '已有钩子被改写'
cp "$test_dir/managed-hook" .git/hooks/pre-commit
git config core.hooksPath "$test_dir/custom-hooks"
if sh scripts/install-git-hooks.sh > "$test_dir/install.log" 2>&1; then
    fail '忽略了自定义 hooksPath'
fi
git config --unset core.hooksPath
pass '保留已有钩子和自定义 hooksPath'

# 历史扫描必须发现已从当前文件删除的值。
mkdir "$test_dir/history"
cd "$test_dir/history"
git init -qb main
printf '%s\n' 'baseline' > README.md
git add README.md
commit baseline
printf 'api_key = "%s"\n' "$synthetic" > sample.txt
git add sample.txt
commit 'add synthetic value'
leak_commit=$(git rev-parse HEAD)
git rm -q sample.txt
commit 'remove synthetic value'
if "$scanner" git --config "$source_root/.gitleaks.toml" --redact=100 --verbose \
    --log-opts='--full-history -m HEAD' . > "$test_dir/history.log" 2>&1; then
    fail '漏掉中间提交中的假密钥'
fi
grep -q "$leak_commit" "$test_dir/history.log" || fail '未定位中间提交'
if grep -Fq "$synthetic" "$test_dir/history.log"; then fail '历史日志未脱敏'; fi
pass '历史扫描发现先提交后删除的假密钥'

mkdir "$test_dir/merge"
cd "$test_dir/merge"
git init -qb main
printf '%s\n' 'baseline' > README.md
git add README.md
commit baseline
git checkout -qb side
printf '%s\n' 'side change' > side.txt
git add side.txt
commit side
git checkout -q main
git -c user.name='RepFlow hook tests' -c user.email='test@example.invalid' \
    merge --no-ff --no-commit side > "$test_dir/merge.log" 2>&1
printf 'api_key = "%s"\n' "$synthetic" > merge-only.txt
git add merge-only.txt
commit 'merge with synthetic value'
merge_commit=$(git rev-parse HEAD)
if "$scanner" git --config "$source_root/.gitleaks.toml" --redact=100 --verbose \
    --log-opts='--full-history -m HEAD' . > "$test_dir/merge-scan.log" 2>&1; then
    fail '漏掉只在合并提交中出现的假密钥'
fi
grep -q "$merge_commit" "$test_dir/merge-scan.log" || fail '未定位合并提交'
pass '历史扫描覆盖合并提交新增内容'
