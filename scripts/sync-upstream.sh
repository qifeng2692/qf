#!/usr/bin/env bash
# sync-upstream.sh — 与上游 earendil-works/pi 同步 main 分支。
#
# 使用前提:
#   - bash + git >= 2.38（--check 的冲突预判使用 git merge-tree --write-tree）
#   - 完整同步模式还需 node >= 22 + npm（install/build/check 校验）
#   - 工作树干净（无未提交/暂存改动、无进行中的 merge）
#   - 能访问 https://github.com/earendil-works/pi；被墙环境先:
#       export HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890
#   - 名为 upstream 的 remote 指向上游（缺失时脚本自动添加）
#
# 用法:
#   bash scripts/sync-upstream.sh           # 完整同步: fetch -> merge -> npm install/build/check
#   bash scripts/sync-upstream.sh --check   # 仅检测落后/冲突预判，不合并；输出 JSON 摘要
#
# 退出码: 0 同步成功或无落后; 1 用法错误(工作树不干净等); 2 合并冲突已自动 abort;
#         3 合并后校验失败(附回滚命令); 10 --check 发现落后; 20 fetch 失败。
set -eu

UPSTREAM_URL="https://github.com/earendil-works/pi"
UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="main"

MODE="sync"
if [ "${1:-}" = "--check" ]; then
	MODE="check"
elif [ -n "${1:-}" ]; then
	echo "unknown argument: $1 (supported: --check)" >&2
	exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
	echo "ERROR: not inside a git repository" >&2
	exit 1
}
cd "$REPO_ROOT"

# 工作树必须干净（untracked 文件不阻塞，未提交改动会污染 merge）
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	echo "ERROR: 工作树不干净，请先提交改动:" >&2
	git status --porcelain --untracked-files=no >&2
	exit 1
fi

# upstream remote 自举
if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
	echo "==> 添加 remote $UPSTREAM_REMOTE -> $UPSTREAM_URL"
	git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
fi

echo "==> git fetch $UPSTREAM_REMOTE $UPSTREAM_BRANCH"
if ! git fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH" --no-tags; then
	echo "ERROR: fetch 失败，检查网络/代理 (HTTPS_PROXY)" >&2
	exit 20
fi

UPSTREAM_REF="FETCH_HEAD" # 刚 fetch 的正是 upstream 的 main
HEAD_SHA="$(git rev-parse HEAD)"
UPSTREAM_SHA="$(git rev-parse "$UPSTREAM_REF")"
BEHIND="$(git rev-list --count "HEAD..$UPSTREAM_REF")"
AHEAD="$(git rev-list --count "$UPSTREAM_REF..HEAD")"

# 冲突预判: trial merge，不触碰工作树。
# merge-tree 退出码: 0=无冲突; 1=有冲突(第 1 行是 tree oid，其后为冲突文件，空行结束);
# 其他=预判不可用。禁用 rebase，按仓库规约一律走 merge。
MT_OUT="$(mktemp)"
CONFLICTS="null"
set +e
git merge-tree --write-tree --name-only "$HEAD_SHA" "$UPSTREAM_SHA" >"$MT_OUT" 2>/dev/null
MT_RC=$?
set -e
if [ "$MT_RC" -eq 0 ]; then
	CONFLICTS="[]"
elif [ "$MT_RC" -eq 1 ]; then
	FILE_LIST="$(awk 'NR>1 && length($0)==0 {exit} NR>1 {print}' "$MT_OUT")"
	if [ -n "$FILE_LIST" ]; then
		CONFLICTS="$(printf '%s\n' "$FILE_LIST" |
			awk 'BEGIN{s="["} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); s=s (NR>1?",":"") "\"" $0 "\""} END{print s"]"}')"
	else
		CONFLICTS="[]"
	fi
fi
rm -f "$MT_OUT"

if [ "$MODE" = "check" ]; then
	echo "upstream=$UPSTREAM_SHA head=$HEAD_SHA ahead=$AHEAD behind=$BEHIND conflicts=$CONFLICTS"
	printf '{"ahead":%s,"behind":%s,"conflicts":%s,"head":"%s","upstream":"%s"}\n' \
		"$AHEAD" "$BEHIND" "$CONFLICTS" "$HEAD_SHA" "$UPSTREAM_SHA"
	if [ "$BEHIND" -gt 0 ]; then
		exit 10
	fi
	exit 0
fi

echo "==> ahead=$AHEAD behind=$BEHIND"
if [ "$BEHIND" -eq 0 ]; then
	echo "已是最新，无需同步。"
	exit 0
fi

if [ "$CONFLICTS" != "null" ] && [ "$CONFLICTS" != "[]" ]; then
	echo "ERROR: 预判合并会产生冲突，已中止（未执行 merge）。冲突文件: $CONFLICTS" >&2
	echo "请人工介入: 先 rebase 本地提交或手动 merge 解决冲突。" >&2
	exit 2
fi

echo "==> git merge FETCH_HEAD --no-edit"
if ! git merge --no-edit FETCH_HEAD; then
	echo "==> 合并冲突，冲突文件列表:"
	git diff --name-only --diff-filter=U | sed 's/^/  - /'
	git merge --abort
	echo "ERROR: 自动合并失败，已 abort 回到合并前状态，请人工介入。" >&2
	exit 2
fi

MERGE_SHA="$(git rev-parse HEAD)"
echo "==> merge 完成: $MERGE_SHA，开始校验: npm install / build / check"
FAIL_STEP=""
if ! npm install --ignore-scripts; then
	FAIL_STEP="npm install --ignore-scripts"
elif ! npm run build; then
	FAIL_STEP="npm run build"
elif ! npm run check; then
	FAIL_STEP="npm run check"
fi

if [ -n "$FAIL_STEP" ]; then
	cat >&2 <<EOF
ERROR: 校验失败于: $FAIL_STEP
merge commit $MERGE_SHA 已生成但不可 push。回滚命令（任选其一）:
  git reset --hard ORIG_HEAD    # 回到合并前 HEAD
  git reset --hard HEAD@{1}     # 同上，reflog 方式
EOF
	exit 3
fi

echo "==> 同步完成且校验全绿。merge commit 已在本地 main，可推送: git push origin main"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	echo "提示: npm run check 产生了自动修复，提交这些改动:"
	git status --porcelain --untracked-files=no | sed 's/^/  - /'
	echo "  git add -u && git commit --amend --no-edit   # 并入 merge commit"
fi
