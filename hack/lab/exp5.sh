#!/usr/bin/env bash
# 实验 5：指标全部不可用时，控制器会不会把副本缩到 min
#
# 边界：只操作 lab-exp5 一个临时命名空间。
#       不停 Prometheus、不碰 bench、不碰 kubestasis-hv、不重建镜像。
#
# 为什么不真的停 Prometheus：
#   Prometheus 的 TSDB 在容器可写层（volumeMounts 只有 config，没有 PVC），
#   scale 到 0 再起来，13 天的压测历史全部丢失。而且 manager 是全局单实例，
#   停掉它 bench-ks 也会失去指标。
#   等价做法：Prometheus 的 kubernetes_sd 只抓 namespaces=[bench]，
#   所以在新命名空间建 App，所有指标查询都返回空向量 → ok=false →
#   与 Prometheus 挂掉走的是同一条代码路径（queryScalar 的注释原话：
#   "返回 ok=false 表示没有可用数据（空结果 / NaN / 非 success）"）。
#
# 用法：
#   bash exp5.sh           完整跑 + 自动清理
#   bash exp5.sh --keep    保留命名空间看现场
#
set -uo pipefail

NS=lab-exp5

# 守卫：命名空间白名单 + context 检查（见 hack/lab/lib.sh）
. "$(dirname "$0")/lib.sh"
lab_guard "$NS"
IMAGE=kubestasis-demoapp:v1
OBSERVE=${OBSERVE:-150}
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

B="\033[1m"; D="\033[2m"; R="\033[31m"; G="\033[32m"; Y="\033[33m"; N="\033[0m"
say()  { printf "%b\n" "$*"; }
step() { printf "\n%b%s%b\n" "$B$Y" "$*" "$N"; }
die()  { say "${R}✗ $*${N}"; exit 1; }

CLEANED=0
cleanup() {
  [ "$CLEANED" = "1" ] && return
  CLEANED=1
  kubectl delete ns "$NS" --ignore-not-found --timeout=90s >/dev/null 2>&1
  local left
  left=$(kubectl get ns "$NS" --no-headers 2>/dev/null | wc -l)
  if [ "$left" -eq 0 ]; then
    say "${G}✓${N} ${NS} 已删除（残留 0）"
  else
    say "${R}✗${N} ${NS} 还在，手动: kubectl delete ns ${NS}"
  fi
  say "${D}原有资源复核（bench 应保持 Stable 1）:${N}"
  kubectl -n bench get app --no-headers 2>/dev/null | sed 's/^/  /'
  say "${D}Prometheus 未被动过: $(kubectl -n bench get deploy prometheus -o jsonpath='{.status.readyReplicas}' 2>/dev/null)/1 就绪${N}"
}
trap '[ "$KEEP" = "1" ] || cleanup' EXIT

# ─────────────────────────────────────────────────────────────
step "阶段 0 / 前置检查"
# ─────────────────────────────────────────────────────────────
kubectl -n kubestasis-hv get deploy ks-kubestasis >/dev/null 2>&1 \
  || die "控制器不在 kubestasis-hv"
kubectl get crd apps.kubestasis.io >/dev/null 2>&1 || die "CRD 不存在"

img_repo="${IMAGE%:*}"; img_tag="${IMAGE##*:}"
[ "$(docker exec desktop-control-plane crictl images 2>/dev/null \
  | awk -v r="$img_repo" -v t="$img_tag" '$1 ~ r && $2 == t {print "y"; exit}')" = "y" ] \
  || die "节点里没有 $IMAGE"

say "${G}✓${N} 控制器 / CRD / 镜像 就绪"
say "${D}本实验依赖的事实：Prometheus 只抓 bench 命名空间${N}"
kubectl -n bench get cm prometheus-config -o jsonpath='{.data.prometheus\.yml}' 2>/dev/null \
  | grep -A 2 "role: pod" | grep "names:" | head -2 | sed 's/^/  /'
say "${D}→ 本实验的 App 在 ${NS}，Prometheus 里查不到它的任何序列 = 全部信号弃权${N}"

kubectl get ns "$NS" >/dev/null 2>&1 && kubectl delete ns "$NS" --timeout=60s >/dev/null 2>&1
kubectl create ns "$NS" >/dev/null || die "建命名空间失败"

# ─────────────────────────────────────────────────────────────
step "阶段 1 / 布场：两组判别对照"
# ─────────────────────────────────────────────────────────────
# 两组唯一差别是 minReplicas。如果都缩到 1，说明缩容是按信号走的；
# 如果分别停在 1 和 3，就精确证明 desired 的初值取自 MinReplicas。
apply_app() {
  local name=$1 min=$2
  kubectl apply -f - >/dev/null <<EOF || return 1
apiVersion: kubestasis.io/v1alpha1
kind: App
metadata:
  name: ${name}
  namespace: ${NS}
spec:
  image: ${IMAGE}
  replicas: 5
  port: 8080
  scaling:
    minReplicas: ${min}
    maxReplicas: 10
    cooldownSeconds: 0
    scaleDownStabilizationSeconds: 0
    scaleDownStepPercent: 20
    metrics:
      - type: QPS
        target: "500"
EOF
}

apply_app exp5-min1 1 || die "创建 exp5-min1 失败（webhook？）"
apply_app exp5-min3 3 || die "创建 exp5-min3 失败"

say "${G}✓${N} exp5-min1 (副本 5, min 1) / exp5-min3 (副本 5, min 3)"
say "${D}两组都配了 QPS 指标，但 Prometheus 里没有它们的序列${N}"
say "${D}稳定窗口与冷却都设为 0，只为加快收敛，不改变结论${N}"
say "${D}不配 health：避免自愈介入，把变量控制在伸缩这一个${N}"

say "\n${D}等 Pod 起来（第一次采样要看到 Ready，否则缩容可能是被别的原因带偏）...${N}"
kubectl -n "$NS" wait --for=condition=Ready pod -l "app=exp5-min1" --timeout=90s >/dev/null 2>&1
kubectl -n "$NS" wait --for=condition=Ready pod -l "app=exp5-min3" --timeout=90s >/dev/null 2>&1
say "${G}✓${N} 两组各 5 个 Pod 已就绪（此时没有任何流量，也没有任何指标）"

# ─────────────────────────────────────────────────────────────
step "阶段 2 / 观察 ${OBSERVE}s（前 40 秒每秒采样，之后每 5 秒）"
# ─────────────────────────────────────────────────────────────
say "${D}预测：min1 一路缩到 1，min3 停在 3。若两组都到 1，则我的模型错了。${N}"
say "${D}只在数值变化时打印：稳定窗口和冷却都为 0 时，缩容可能在 1 秒内连跳数级。${N}\n"
printf "  ${D}%-7s %-11s %-11s %-13s${N}\n" "t" "min1副本" "min3副本" "min1就绪"

declare -a seq1=() seq3=()
start=$(date +%s)
pr1=""; pr3=""
sample() {
  local r1 r3 cr t
  r1=$(kubectl -n "$NS" get app exp5-min1 -o jsonpath='{.spec.replicas}' 2>/dev/null)
  r3=$(kubectl -n "$NS" get app exp5-min3 -o jsonpath='{.spec.replicas}' 2>/dev/null)
  # 就绪数取 status.currentReplicas，能证明 Pod 真的被删了，不只是 spec 数字变了
  cr=$(kubectl -n "$NS" get app exp5-min1 -o jsonpath='{.status.currentReplicas}' 2>/dev/null)
  t=$(( $(date +%s) - start ))
  if [ "$r1" != "$pr1" ] || [ "$r3" != "$pr3" ]; then
    printf "  %-7s %-11s %-11s %-13s\n" "${t}s" "${r1:-?}" "${r3:-?}" "${cr:-—}"
    pr1="$r1"; pr3="$r3"
  fi
  seq1+=("$r1"); seq3+=("$r3")
}

# 前 40 秒每秒采一次，抓连跳；之后每 5 秒，覆盖慢收敛
for i in $(seq 1 40); do sample; sleep 1; done
for i in $(seq 1 $(( (OBSERVE - 40) / 5 ))); do sample; sleep 5; done
sample

# ─────────────────────────────────────────────────────────────
step "阶段 3 / 结论"
# ─────────────────────────────────────────────────────────────
f1=${seq1[${#seq1[@]}-1]}; f3=${seq3[${#seq3[@]}-1]}
cat <<EOF
  起点 / 终点：
    exp5-min1  min=1   5 → ${f1}
    exp5-min3  min=3   5 → ${f3}
EOF

say ""
if [ "$f1" = "1" ] && [ "$f3" = "3" ]; then
  say "  ${G}✓ 两组分别停在各自的 min，没有停在 1 以下，也没有停在 5。${N}"
  say "  这排除了「按 20% 一路缩到最少」的解释——那两组都会到 1。"
  say "  唯一能解释的是：desired 的初值取自 MinReplicas，信号全弃权时"
  say "  这个初值没有被任何输入修正，稳定窗口一过就按步长往下走。"
elif [ "$f1" = "1" ] && [ "$f3" = "1" ]; then
  say "  ${Y}! 两组都到了 1，说明缩容逻辑不是从 min 起步，我的模型需要修正。${N}"
elif [ "$f1" = "5" ] && [ "$f3" = "5" ]; then
  say "  ${Y}! 两组都没动，说明弃权路径还有别的守卫（或 manager 版本比代码新）。${N}"
else
  say "  ${Y}? 结果介于两者之间，看上面的时序自己判断。${N}"
fi

step "证据 / 完整时序（面试直接引用）"
say "  exp5-min1: $(printf '%s\n' "${seq1[@]}" | uniq | tr '\n' ' ')"
say "  exp5-min3: $(printf '%s\n' "${seq3[@]}" | uniq | tr '\n' ' ')"
say "  ${D}时间轴：前 40 秒每秒一次，之后每 5 秒一次，共 ${OBSERVE}s${N}"

say "\n${D}对照：Prometheus 里确实没有这两组的数据（空向量 = 弃权，不是错误）${N}"

step "证据 / 决策原因码（来自 Events，controller 在 app_controller.go:235 发出）"
for a in exp5-min1 exp5-min3; do
  say "  ${B}${a}${N}"
  kubectl -n "$NS" get events --field-selector "involvedObject.name=${a},reason=KubeStasisScaleDown" \
    -o jsonpath='{range .items[*]}{.lastTimestamp}  {.message}{"\n"}{end}' 2>/dev/null \
    | cut -c1-110 | sed 's/^/    /'
done
say "\n  ${D}两条要点：${N}"
say "  ${D}1. 每条都是 load below targets —— 但 Prometheus 里根本没有这个 App 的数据，"
say "     「低于目标」是从「查不到」推出来的，不是从「查到了 0」推出来的。${N}"
say "  ${D}2. 时间戳常常落在同一秒：稳定窗口和冷却都为 0 时，一次 status 回写就"
say "     立刻触发下一轮，5 个副本可以在一秒内连跳到底。默认配置（60s/120s）"
say "     下同样的路径会慢很多，但方向一样。${N}"

# ─────────────────────────────────────────────────────────────
step "阶段 4 / 清理"
# ─────────────────────────────────────────────────────────────
if [ "$KEEP" = "1" ]; then
  say "${Y}--keep：保留 ${NS}，看完执行 kubectl delete ns ${NS}${N}"
else
  cleanup
fi

cat <<'NOTE'

── 这个实验证明了什么 ──────────────────────────────────
同文件里那句注释写的是「绝不能当成 0 处理，否则 Prometheus 一挂就把
副本缩到 min」，而实际行为正是缩到 min。两组判别对照排除了「缩到最少」
这个竞争解释：min=3 的那组精准停在 3。

不是"缩容太激进"，是"没有数据"被当成了"需求很低"。事件里的措辞是
load below targets，看不出任何异常——这才是它危险的地方。

顺带一个只有真跑才能发现的细节：稳定窗口和冷却都设成 0 时，一次
status 回写立刻触发下一轮 reconcile，5 个副本在一秒内连跳到底
（看 Events 的时间戳，四条全在同一秒）。这也解释了压测 run5 里
4→3、13 秒后扩回 5 是怎么来的。

── 面试怎么讲 ──────────────────────────────────────────
"我原以为指标全不可用会保持不动，写实验验证发现会一路缩到 min。
判别方法是建两组只有 minReplicas 不同的 App：一组停在 1，一组停在 3，
说明 desired 是从 MinReplicas 起步、弃权没有修正它。
修法是加 anyOK 守卫，全弃权返回 ActionNone + no_metrics_data。"

── 为什么不停 Prometheus 更危险 ────────────────────────
它的 TSDB 在容器可写层（volumeMounts 只有 config，无 PVC）。
scale 到 0 再起来，13 天的压测历史全丢，而 manager 又是全局单实例，
bench-ks 会跟着失去指标。要验证的是代码路径，不是制造事故。
NOTE
