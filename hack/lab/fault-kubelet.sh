#!/usr/bin/env bash
# 故障 1：节点失联（kill kubelet），看 Pod 会被怎样处理
#
# ⚠ 这个脚本没有在你的机器上实跑过（其余 exp*.sh 都跑过）。原因不是懒：
#   它会让节点真的进入 NotReady，在单节点 Docker Desktop 上做，等于把开发
#   环境本身变成故障现场。所以它自己建一个一次性 kind 集群，跑完删掉。
#
# 三道保险，任一条不满足就退出：
#   1. context 必须正好是 kind-lab-fault（不认 docker-desktop，也不认其它 kind）
#   2. 集群由本脚本创建，名字固定，跑完 `kind delete cluster`
#   3. 只操作自建的命名空间 lab-fault
#
# 前置：kind（brew install kind / choco install kind）、docker
#
# 观察什么：
#   · t+0s      kill kubelet
#   · t≈40s     节点变 NotReady（node-monitor-grace-period 默认 40s）
#   · t≈300s    Pod 进入 Terminating（默认容忍 not-ready 300s）
#   · t≈300s+   Deployment 在另一台 worker 上补出新 Pod
# 这三个数字是 Kubernetes 默认值，不是实测值——跑完把它们换成你看到的。

set -uo pipefail

CLUSTER=lab-fault
CTX=kind-$CLUSTER
NS=lab-fault
WORKER=$CLUSTER-worker

. "$(dirname "$0")/lib.sh"

die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
step() { printf '\n\033[36m── %s ─────────────────────────────\033[0m\n' "$*"; }

command -v kind >/dev/null 2>&1 || die "没装 kind。这个实验必须用一次性集群：https://kind.sigs.k8s.io"
command -v docker >/dev/null 2>&1 || die "docker 不可用"

# 你现有集群是 docker-desktop，这里显式拦住，防止手滑在它上面跑
cur=$(kubectl config current-context 2>/dev/null || echo "")
[ "$cur" = "$CTX" ] || [ -z "$(kind get clusters 2>/dev/null | grep -x "$CLUSTER")" ] ||
	die "已存在同名集群但当前 context 是 '$cur'。先 kubectl config use-context $CTX"

created=""
cleanup() {
	if [ -n "$created" ]; then
		say "回收：删除一次性集群 $CLUSTER"
		kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
		say "✓ 已删除（你原来的 docker-desktop 集群没被动过）"
	fi
}
trap cleanup EXIT

step "阶段 1 / 建一次性集群（1 控制面 + 2 worker）"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
	say "复用已存在的 $CLUSTER"
else
	cat <<EOF | kind create cluster --name "$CLUSTER" --config - >/dev/null || die "建集群失败"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF
	created=yes
	say "✓ 集群就绪"
fi
kubectl config use-context "$CTX" >/dev/null || die "切 context 失败"

kubectl create ns "$NS" >/dev/null 2>&1 || true

step "阶段 2 / 布场：2 副本，锁在其中一台 worker 上"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probe
  namespace: $NS
spec:
  replicas: 2
  selector:
    matchLabels: {app: probe}
  template:
    metadata:
      labels: {app: probe}
    spec:
      # 故意钉在一台节点：不钉的话调度器可能把两个副本分散到两台 worker，
      # 杀掉一台看不出"整个工作负载失联"的效果
      nodeSelector:
        kubernetes.io/hostname: $WORKER
      containers:
        - name: probe
          image: registry.k8s.io/pause:3.9
EOF
kubectl -n "$NS" rollout status deploy/probe --timeout=120s >/dev/null || die "Pod 没起来"
kubectl -n "$NS" get pods -o wide

step "阶段 3 / 杀 kubelet，按秒记录"
say "预测：40s 左右 NotReady；300s 左右 Pod 进 Terminating；之后在另一台 worker 补出新 Pod"
kubectl -n "$NS" get pods -o wide --no-headers | sed 's/^/  初始: /'

start=$(date +%s)
docker exec "$WORKER" pkill -9 kubelet >/dev/null 2>&1 || die "杀 kubelet 失败（容器名可能不是 $WORKER）"

for i in $(seq 1 40); do
	t=$(( $(date +%s) - start ))
	node=$(kubectl get node "$WORKER" --no-headers 2>/dev/null | awk '{print $2}')
	running=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -c Running)
	term=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -c Terminating)
	printf "  t=%-4s node=%-12s Running=%s Terminating=%s\n" "${t}s" "${node:-?}" "$running" "$term"
	[ "$term" -gt 0 ] || [ "$running" -lt 2 ] && break
	sleep 10
done

step "阶段 4 / 证据"
kubectl get node "$WORKER" -o wide || true
kubectl -n "$NS" get pods -o wide || true
kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -12 || true

say ""
say "要记的不是'多久恢复'，是三个时间常量的差异："
say "  node-monitor-grace-period=40s  多久判定失联"
say "  default-not-ready-toleration-seconds=300s  多久开始驱逐"
say "  两者差 260 秒，就是'明知节点挂了但业务还在硬撑'的窗口"
say ""
say "接到你自己的项目上：这 300 秒里 App 的 status 仍是 Stable，"
say "因为 controller 看到的 Deployment 还是 2/2 Ready——Deployment 控制器"
say "和 kubelet 都认为没问题。这就是'控制面健康 ≠ 数据面健康'的具体形态。"
