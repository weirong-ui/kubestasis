#!/usr/bin/env bash
# 实验 8：L2 摘除会不会绕过 PDB
#
# 边界：只操作 lab-exp8 一个临时命名空间。
#       不碰 bench（压测基线）、不碰 kubestasis-hv（控制器）、不重建镜像。
#
# 用法：
#   bash exp8.sh           完整跑 + 自动清理
#   bash exp8.sh --keep    保留命名空间看现场（看完手动 kubectl delete ns lab-exp8）
#
# 已在 2026-11-17 实跑通过：L2 于 16 秒触发，对照组 eviction 返回 429。
#
set -uo pipefail

NS=lab-exp8

# 守卫：命名空间白名单 + context 检查（见 hack/lab/lib.sh）
. "$(dirname "$0")/lib.sh"
lab_guard "$NS"
APP=exp8
IMAGE=kubestasis-demoapp:v2-crash
REPLICAS=3
PROXY_PORT=${PROXY_PORT:-18777}
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

B="\033[1m"; D="\033[2m"; R="\033[31m"; G="\033[32m"; Y="\033[33m"; N="\033[0m"
say()  { printf "%b\n" "$*"; }
step() { printf "\n%b%s%b\n" "$B$Y" "$*" "$N"; }
die()  { say "${R}✗ $*${N}"; exit 1; }

PROXY_PID=""
CLEANED=0

# ─────────────────────────────────────────────────────────────
# 清理：第一行删命名空间，随后停代理。删完不留任何东西。
# ─────────────────────────────────────────────────────────────
cleanup() {
  [ "$CLEANED" = "1" ] && return   # 阶段 4 显式调用过一次，EXIT trap 不再重复
  CLEANED=1
  kubectl delete ns "$NS" --ignore-not-found --timeout=90s >/dev/null 2>&1
  [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null

  local left
  left=$(kubectl get ns "$NS" --no-headers 2>/dev/null | wc -l)
  if [ "$left" -eq 0 ]; then
    say "${G}✓${N} ${NS} 已删除（残留 0），代理已停"
  else
    say "${R}✗${N} ${NS} 还在，手动执行: kubectl delete ns ${NS}"
  fi
  say "${D}原有资源复核:${N}"
  kubectl get app -A --no-headers 2>/dev/null | sed 's/^/  /'
}

trap '[ "$KEEP" = "1" ] || cleanup' EXIT

# ─────────────────────────────────────────────────────────────
step "阶段 0 / 前置检查"
# ─────────────────────────────────────────────────────────────
kubectl version --request-timeout=5s >/dev/null 2>&1 || die "kubectl 连不上集群"
kubectl -n kubestasis-hv get deploy ks-kubestasis >/dev/null 2>&1 \
  || die "控制器 ks-kubestasis 不在 kubestasis-hv，实验需要它处理 App"

# crictl 输出是「仓库名 <空格> tag」，不是 repo:tag，要分开比对
img_repo="${IMAGE%:*}"; img_tag="${IMAGE##*:}"
[ "$(docker exec desktop-control-plane crictl images 2>/dev/null \
  | awk -v r="$img_repo" -v t="$img_tag" '$1 ~ r && $2 == t {print "y"; exit}')" = "y" ] \
  || die "节点里没有 $IMAGE，先执行: kind load docker-image $IMAGE"

command -v curl >/dev/null 2>&1 || die "需要 curl（对照组的 eviction 探测要用）"

say "${G}✓${N} 集群 / 控制器 / 镜像 / curl 就绪"
say "${D}控制器参数（注意 heal-cooldown=3m，决定你观察的节奏）:${N}"
kubectl -n kubestasis-hv get deploy ks-kubestasis \
  -o jsonpath='  {.spec.template.spec.containers[0].args}{"\n"}' 2>/dev/null
say "${D}bench 基线快照（结束后对比是否被动过）:${N}"
kubectl -n bench get app --no-headers 2>/dev/null | sed 's/^/  /'

kubectl get ns "$NS" >/dev/null 2>&1 && { say "${Y}发现残留 ${NS}，先清${N}"; kubectl delete ns "$NS" --timeout=60s >/dev/null 2>&1; }

# ─────────────────────────────────────────────────────────────
step "阶段 1 / 布场（全部落在 ${NS}）"
# ─────────────────────────────────────────────────────────────
kubectl create ns "$NS" >/dev/null || die "建命名空间失败"

# 实验对象：3 副本 + 启动即退出的镜像，用来触发 L2
kubectl apply -f - >/dev/null <<EOF || die "App 创建失败（webhook 是否正常？）"
apiVersion: kubestasis.io/v1alpha1
kind: App
metadata:
  name: ${APP}
  namespace: ${NS}
spec:
  image: ${IMAGE}
  replicas: ${REPLICAS}
  port: 8080
  health:
    strategy: graduated
EOF

# 对照组：普通 Deployment，正常镜像，能 Ready。
# 用途是证明「PDB 本身没坏」——它拦得住 eviction，只是拦不住 L2 的 Delete。
kubectl -n "$NS" create deploy ref --image=kubestasis-demoapp:v1 --replicas=2 >/dev/null 2>&1
kubectl -n "$NS" create pdb ref --min-available=2 --selector=app=ref >/dev/null 2>&1
kubectl -n "$NS" create pdb "$APP" --min-available=2 \
  --selector="app=${APP},app.kubernetes.io/managed-by=kubestasis" >/dev/null 2>&1

say "${G}✓${N} App(${REPLICAS} 副本, crash 镜像) + 对照组 ref(2 副本, 正常镜像) + 两个 PDB"
say "${D}crash 镜像启动即 os.Exit(1)，Pod 永远不 Ready —— 这是有意的${N}"

say "\n${D}等对照组就绪...${N}"
kubectl -n "$NS" wait --for=condition=Ready pod -l app=ref --timeout=90s >/dev/null 2>&1 \
  || say "${Y}对照组未全部就绪，eviction 结果可能不准${N}"

# 记下此刻的 Pod 名单，之后和事件里的删除名单对比
pods_before=$(kubectl -n "$NS" get pod -l "app=$APP" -o jsonpath='{range .items[*]}{.metadata.name} {end}')

# ─────────────────────────────────────────────────────────────
step "阶段 2 / 对照：PDB 对 eviction 有效吗"
# ─────────────────────────────────────────────────────────────
kubectl proxy --port="$PROXY_PORT" --address=127.0.0.1 >/dev/null 2>&1 &
PROXY_PID=$!
ready=0
for _ in 1 2 3 4 5 6 7 8; do
  curl -s -m 2 -o /dev/null "http://127.0.0.1:${PROXY_PORT}/version" && { ready=1; break; }
  sleep 1
done
[ "$ready" = "1" ] || die "API 代理没起来，端口 ${PROXY_PORT} 可能被占用（换 PROXY_PORT=xxxx 重跑）"

refpod=$(kubectl -n "$NS" get pod -l app=ref -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
kubectl -n "$NS" get pdb --no-headers 2>/dev/null | sed 's/^/  /'
say ""

if [ -n "$refpod" ]; then
  code=$(curl -s -m 5 -o /tmp/ev8.json -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d "{\"apiVersion\":\"policy/v1\",\"kind\":\"Eviction\",\"metadata\":{\"name\":\"${refpod}\",\"namespace\":\"${NS}\"}}" \
    "http://127.0.0.1:${PROXY_PORT}/api/v1/namespaces/${NS}/pods/${refpod}/eviction")
  say "  对对照组 ${refpod} 发 eviction → ${B}HTTP ${code}${N}"
  if [ "$code" = "429" ]; then
    say "  ${G}✓ PDB 拦住了${N}：$(grep -o '"message": "[^"]*"' /tmp/ev8.json | head -1 | cut -c13-120)"
  else
    say "  ${Y}? 期望 429，实际 ${code}${N}"
  fi
  say "  ${D}对照组 Pod 仍在: $(kubectl -n "$NS" get pod "$refpod" -o name 2>/dev/null || echo 已消失)${N}"
fi
say "\n  ${D}这一步已经证明了 PDB 是好的。接下来看 L2 走的那条路绕不绕得过它。${N}"

# ─────────────────────────────────────────────────────────────
step "阶段 3 / 观察 L2（等控制器发现 CrashLoopBackOff）"
# ─────────────────────────────────────────────────────────────
say "${D}实测参考：约 15~20 秒触发。崩溃不同步时只删 1 个，同步时删更多。${N}\n"

prev=""; start=$(date +%s); hit=""
for _ in $(seq 1 60); do
  cur=$(kubectl -n "$NS" get pod -l "app=$APP" \
    -o custom-columns='N:.metadata.name,S:.status.phase,R:.status.containerStatuses[0].restartCount' \
    --no-headers 2>/dev/null | tr -s ' ' | tr '\n' '|')
  [ "$cur" != "$prev" ] && { printf "  ${D}t=%02ds${N} %s\n" $(( $(date +%s) - start )) "${cur//|/  }"; prev="$cur"; }

  # 从事件读，不读 status：status.lastHealAction 会被后续「无动作」轮次覆盖
  hit=$(kubectl -n "$NS" get events --field-selector reason=KubeStasisHealAction \
    -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep -m1 "L2 Isolate")
  [ -n "$hit" ] && break
  sleep 3
done

[ -n "$hit" ] || die "180 秒内没等到 L2。查: kubectl -n ${NS} get events --sort-by=.lastTimestamp"

step "证据 1 / L2 实际删了哪些 Pod"
say "  ${B}${hit}${N}"
deleted=$(printf '%s' "$hit" | grep -o 'deleted [0-9]*' | awk '{print $2}')
say "\n  ${D}布场时的 Pod: ${pods_before}${N}"
say "  ${D}本轮删除数量: ${deleted:-?} / 当时副本数 ${REPLICAS}${N}"
say "  ${D}说明：删的是这一轮 report.Pods 里全部处于 CrashLoopBackOff 的 Pod，"
say "  数量取决于几个容器同时崩。不是「永远全删」，但也没有数量上限和退避。${N}"

step "证据 2 / 同一时刻 PDB 对这条路径有没有约束力"
kubectl -n "$NS" get pdb "$APP" --no-headers 2>/dev/null | sed 's/^/  /'
say "  ${D}disruptionsAllowed=$(kubectl -n "$NS" get pdb "$APP" -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null)${D}，而上面 L2 的删除全部成功${N}"

step "证据 3 / 完整自愈事件流（面试可引用的原文）"
kubectl -n "$NS" get events --field-selector reason=KubeStasisHealAction \
  -o jsonpath='{range .items[*]}{.lastTimestamp}  {.message}{"\n"}{end}' 2>/dev/null \
  | cut -c1-140 | sed 's/^/  /'

# ─────────────────────────────────────────────────────────────
step "阶段 4 / 清理"
# ─────────────────────────────────────────────────────────────
if [ "$KEEP" = "1" ]; then
  say "${Y}--keep 已指定，保留 ${NS}${N}"
  say "${D}看完执行: kubectl delete ns ${NS}   然后 kill 掉代理: kill ${PROXY_PID}${N}"
else
  cleanup
fi

cat <<'NOTE'

── 这个实验证明了什么 ──────────────────────────────────
不是「删 Pod 会造成多久空窗」。crash 镜像从来不 Ready，空窗从
t=0 就存在，测不出 L2 的贡献。

它证明的是三件更硬的事：

1. PDB 本身没坏。对照组 disruptionsAllowed=0 时，eviction 被
   429 拒绝（Cannot evict pod as it would violate its budget）。
2. L2 走 c.Delete 直删对象，完全不经过 eviction 校验，所以同一
   时刻同样不允许中断，它照样删成功。
3. 删除范围是 isolate 里的裸 for 循环：report.Pods 里有几个就删
   几个，没有 PDB、没有逐个退避、没有数量上限。

所以「配了 PDB 就不会被删没」是错的。PDB 只管 eviction 子资源，
绕过去等于没配。

── 两个容易讲错的地方 ──────────────────────────────────
· 不要说「L2 一次删光所有副本」。实测只删了处在 CrashLoopBackOff
  的那几个，崩溃错开时就只有 1 个。说法应该是「一轮内全删，无上限」。
· status.lastHealAction 会被后续「无动作」轮次覆盖成诊断摘要，
  排障必须看 Events。这一点本身就值得在面试里提一句。
NOTE
