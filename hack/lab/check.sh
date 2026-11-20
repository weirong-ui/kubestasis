#!/usr/bin/env bash
# 实验脚本的静态门：不连集群，只检查每个脚本都装了守卫。
#
# 单独做成门的原因：守卫写在文档里就只是建议，写在脚本里也还可能被下一个脚本
# 忘掉。CI 里跑一遍，忘掉的那一个直接红。
set -uo pipefail

cd "$(dirname "$0")" || exit 1
fail=0

for f in exp*.sh; do
	[ -e "$f" ] || continue

	if ! bash -n "$f" 2>/dev/null; then
		echo "✗ $f 语法错误"
		bash -n "$f" 2>&1 | sed 's/^/  /'
		fail=1
		continue
	fi

	if ! grep -q 'lib\.sh' "$f"; then
		echo "✗ $f 没有引用 hack/lab/lib.sh（缺命名空间白名单守卫）"
		fail=1
	fi

	if ! grep -q 'lab_guard' "$f"; then
		echo "✗ $f 没有调用 lab_guard"
		fail=1
	fi

	# 受保护命名空间只允许出现在注释和只读命令里。
	# 写操作（apply/patch/delete/scale/edit）碰到 bench、kubestasis-* 一律拦下。
	if grep -nE 'kubectl .*(apply|delete|patch|scale|edit|replace)[^#]*\b(bench|kubestasis-system|kubestasis-hv)\b' "$f" |
		grep -vE '^\s*[0-9]+:\s*#' >/dev/null; then
		echo "✗ $f 对受保护命名空间发起写操作："
		grep -nE 'kubectl .*(apply|delete|patch|scale|edit|replace)[^#]*\b(bench|kubestasis-system|kubestasis-hv)\b' "$f" | sed 's/^/  /'
		fail=1
	fi
done

if [ "$fail" -ne 0 ]; then
	echo "实验脚本守卫检查失败"
	exit 1
fi
echo "✓ 实验脚本守卫齐全（$(ls exp*.sh | wc -l | tr -d ' ') 个）"
