#!/usr/bin/env bash
# 实验脚本的公共守卫。被 hack/lab/*.sh 源码引用，不单独执行。
#
# 为什么要有这个文件：
#   2026-11-18 做实验时踩过两次，都不是操作失误，是设计失误——
#   1. "停掉 Prometheus 看会怎样"：Prometheus 只挂 config、没有 PVC，TSDB 在
#      容器可写层，停一次等于删掉十几天的压测历史。后来改成"换一个命名空间，
#      让它天然查不到指标"，代码路径一样，代价为零。
#   2. "关掉 webhook 提交非法配置"：恢复准入后，控制器摘 finalizer 的那次 UPDATE
#      也被拒，App 卡死、命名空间停在 Terminating。
# 两次的共同点是：危险来自"能碰到全局对象"。所以这里把它变成代码约束，
# 而不是每个脚本开头写一句"请注意不要碰 bench"。

# 只允许 lab-* 命名空间。名字本身就是声明：这个脚本只在自己的沙盒里写。
LAB_NS_PATTERN='^lab-[a-z0-9-]*$'

# 受保护对象：压测基线、控制器自身、集群基础命名空间。
LAB_PROTECTED_NS='bench kubestasis-system kubestasis-hv kube-system kube-public kube-node-lease default'

lab_say() { printf '%s\n' "$*"; }

lab_die() {
	printf '\033[31m✗ %s\033[0m\n' "$*" >&2
	exit 1
}

# lab_guard <namespace>
#
# 三条硬检查，任一不满足直接退出：
#   1. 命名空间名必须匹配 lab-*（防止手滑写成 bench）
#   2. 不能是受保护命名空间（哪怕有人把 lab_ 前缀放宽）
#   3. 当前 kube context 必须是 kind——实验会改 CRD、改 webhook、重启控制器，
#      这些动作不该发生在任何共享集群里。确实要在别处跑时显式设
#      LAB_ALLOW_ANY_CONTEXT=1，让"我知道自己在做什么"留下痕迹。
#
# LAB_GUARD_ONLY=1 时只做检查然后退出：用来在 CI 里验证守卫本身，
# 不需要真集群，也不会写任何对象。
lab_guard() {
	local ns="${1:-}"

	[ -n "$ns" ] || lab_die "lab_guard 需要命名空间参数"
	[[ "$ns" =~ $LAB_NS_PATTERN ]] || lab_die "命名空间 '$ns' 不在白名单内（只允许 lab-*）"

	local p
	for p in $LAB_PROTECTED_NS; do
		[ "$ns" = "$p" ] && lab_die "拒绝操作受保护命名空间: $p"
	done

	command -v kubectl >/dev/null 2>&1 || lab_die "找不到 kubectl"

	if [ "${LAB_GUARD_ONLY:-0}" = "1" ]; then
		lab_say "✓ 守卫通过: ns=$ns（仅检查，未连集群）"
		exit 0
	fi

	kubectl cluster-info >/dev/null 2>&1 || lab_die "集群连不上，先确认 kubectl 能工作"

	local ctx
	ctx=$(kubectl config current-context 2>/dev/null || echo "")
	# 只允许本地集群：实验会改 CRD、改 webhook、重启控制器，这些动作不该落在
	# 任何共享集群上。docker-desktop 也是本地的（它底层就是 kind），别把
	# 平台名当成环境性质来判——这条正是"守卫写太死会挡住正常用法"的例子。
	case "$ctx" in
	*kind* | *docker-desktop* | *docker-for-desktop* | *minikube* | *rancher-desktop*) ;;
	*)
		[ "${LAB_ALLOW_ANY_CONTEXT:-0}" = "1" ] ||
			lab_die "当前 context '$ctx' 不是本地集群（kind/docker-desktop/minikube）；确认无误后设 LAB_ALLOW_ANY_CONTEXT=1 再跑"
		;;
	esac
}

# lab_cleanup_ns <namespace>：删命名空间并等到它真的消失。
# 只认 lab-*，删错对象的代价太高，这里再判一次。
lab_cleanup_ns() {
	local ns="${1:-}"
	[[ "$ns" =~ $LAB_NS_PATTERN ]] || lab_die "拒绝删除非实验命名空间: '$ns'"
	kubectl delete ns "$ns" --ignore-not-found --timeout=90s >/dev/null 2>&1 || true
	local left
	left=$(kubectl get ns "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
	[ "$left" = "0" ] && lab_say "✓ $ns 已回收" || lab_say "! $ns 仍在删除中（Terminating），检查 finalizer"
}

# lab_apply_stdin：从标准输入读清单，先服务端 dry-run 再真正写入。
#
# dry-run 会跑完整套准入（CRD schema + webhook），但不落库，所以能在
# "已经改了集群"之前发现清单本身的问题。stdin 只能读一次，先落临时文件。
#
# 负向用例（故意提交非法配置来验证准入）不要用它——那种场景要的正是"被拒绝"。
lab_apply_stdin() {
	local tmp
	tmp=$(mktemp)
	cat >"$tmp"

	if ! kubectl apply --dry-run=server -f "$tmp" >/dev/null 2>&1; then
		lab_say "✗ dry-run 未通过，清单没有写入："
		kubectl apply --dry-run=server -f "$tmp" 2>&1 | tail -3 | sed 's/^/  /'
		rm -f "$tmp"
		return 1
	fi

	kubectl apply -f "$tmp"
	local rc=$?
	rm -f "$tmp"
	return $rc
}
