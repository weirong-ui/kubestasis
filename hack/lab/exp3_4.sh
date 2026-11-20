#!/usr/bin/env bash
# 实验 3 + 4（合并）：冷却窗口制造固定间隔 / 稳定窗口的计时能否跨重启
#
# 边界：只操作 lab-exp3、lab-exp4 两个临时命名空间，跑完自动删除。
#       不改仓库任何文件，不改 manager 启动参数，不换镜像。
#       唯一的环境改动：阶段 2 会 rollout restart 一次 manager（参数不变，
#       只是重建 Pod，AGE 会变小）。这是实验 4 的必要条件。
#
# 为什么不需要 Prometheus：
#   两个实验都不需要真实负载，只需要「持续存在缩容候选」。
#   Prometheus 的 kubernetes_sd 只抓 bench，lab-* 里的 App 查不到任何序列
#   → 信号全弃权 → desired 停在 minReplicas → 持续低于 current。同 exp5。
#
# 关于运行中的镜像（2026-11-18 实测修正）：
#   不要用 commit 时间推断镜像里有什么。p9 的构建时间比「缩容稳定窗口」
#   那个提交早 8 分钟，但它的行为里明明有稳定窗口（status.belowTargetSince
#   会被写、Deployment 带 readinessProbe）——说明它是拿当时未提交的工作区
#   构建的。判断依据只能是运行时能观测到的东西，不是 tag，也不是提交时间。
#
# 用法：
#   bash exp3_4.sh           完整跑 + 自动清理（约 6 分钟）
#   bash exp3_4.sh --keep    保留命名空间看现场
#
set -uo pipefail

NS3=lab-exp3
NS4=lab-exp4
# 守卫：命名空间白名单 + context 检查（见 hack/lab/lib.sh）
. "$(dirname "$0")/lib.sh"
lab_guard "$NS3"
lab_guard "$NS4"
IMAGE=kubestasis-demoapp:v1
DEPLOY_NS=kubestasis-hv
DEPLOY=ks-kubestasis
OBSERVE=${OBSERVE:-150}      # 阶段 1 观察秒数
RESTART_AT=25                # 阶段 2：稳住计时起点后第几秒重启 manager
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
  local ns
  for ns in "$NS3" "$NS4"; do
    kubectl delete ns "$ns" --ignore-not-found --timeout=90s >/dev/null 2>&1
    if [ "$(kubectl get ns "$ns" --no-headers 2>/dev/null | wc -l)" -eq 0 ]; then
      say "${G}✓${N} ${ns} 已删除（残留 0）"
    else
      say "${R}✗${N} ${ns} 还在，手动: kubectl delete ns ${ns}"
    fi
  done
  say "${D}原有资源复核（bench 应保持 Stable）:${N}"
  kubectl -n bench get app --no-headers 2>/dev/null | sed 's/^/  /'
  say "${D}manager: $(kubectl -n "$DEPLOY_NS" get deploy "$DEPLOY" \
      -o jsonpath='{.spec.template.spec.containers[0].image} {.status.readyReplicas}/1 就绪' 2>/dev/null)${N}"
  say "${D}注：阶段 2 重启过 manager，镜像和参数都未变，只是 Pod 重建了一次${N}"
}
trap '[ "$KEEP" = "1" ] || cleanup' EXIT

apply_app() {  # name ns replicas min cooldown stab
  local name=$1 ns=$2 rep=$3 min=$4 cool=$5 stab=$6
  kubectl apply -f - >/dev/null <<EOF || return 1
apiVersion: kubestasis.io/v1alpha1
kind: App
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  image: ${IMAGE}
  replicas: ${rep}
  port: 8080
  scaling:
    minReplicas: ${min}
    maxReplicas: 10
    cooldownSeconds: ${cool}
    scaleDownStabilizationSeconds: ${stab}
    scaleDownStepPercent: 20
    metrics:
      - type: QPS
        target: "500"
EOF
}

ev_first() {  # ns app -> 第一条缩容事件时间
  kubectl -n "$1" get events \
    --field-selector "involvedObject.name=$2,reason=KubeStasisScaleDown" \
    -o jsonpath='{.items[0].lastTimestamp}' 2>/dev/null
}

# ─────────────────────────────────────────────────────────────
step "阶段 0 / 前置检查"
# ─────────────────────────────────────────────────────────────
kubectl -n "$DEPLOY_NS" get deploy "$DEPLOY" >/dev/null 2>&1 || die "控制器不在 ${DEPLOY_NS}"
kubectl get crd apps.kubestasis.io >/dev/null 2>&1 || die "CRD 不存在"

img_repo="${IMAGE%:*}"; img_tag="${IMAGE##*:}"
[ "$(docker exec desktop-control-plane crictl images 2>/dev/null \
  | awk -v r="$img_repo" -v t="$img_tag" '$1 ~ r && $2 == t {print "y"; exit}')" = "y" ] \
  || die "节点里没有 $IMAGE"

RUNNING_IMG=$(kubectl -n "$DEPLOY_NS" get deploy "$DEPLOY" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
say "${G}✓${N} 控制器 / CRD / 镜像 就绪"
say "${D}运行中的 manager 镜像: ${RUNNING_IMG}${N}"
say "${D}阶段 1 的第三组会顺便验证它的能力，不靠 tag 也不靠提交时间${N}"

for ns in "$NS3" "$NS4"; do
  kubectl get ns "$ns" >/dev/null 2>&1 && kubectl delete ns "$ns" --timeout=60s >/dev/null 2>&1
  kubectl create ns "$ns" >/dev/null || die "建命名空间 $ns 失败"
done

snapshot() {
  kubectl -n "$NS3" get app -o jsonpath='{range .items[*]}{.metadata.name}={.spec.replicas}/{.status.currentReplicas} {end}' 2>/dev/null
}

# ─────────────────────────────────────────────────────────────
step "阶段 1 / 冷却与稳定窗口是两个东西：三组并行"
# ─────────────────────────────────────────────────────────────
apply_app exp3-cool120 "$NS3" 3 1 120 0 || die "创建 cool120 失败（webhook？）"
apply_app exp3-cool0   "$NS3" 3 1 0   0 || die "创建 cool0 失败"
apply_app exp3-stab120 "$NS3" 3 1 0   120 || die "创建 stab120 失败"
T0=$(date +%s)

say "${G}✓${N} 三组已创建，均从 3 副本起、min=1、无指标"
say "    exp3-cool120   cooldown=120  stab=0"
say "    exp3-cool0     cooldown=0    stab=0"
say "    exp3-stab120   cooldown=0    stab=120"
say ""
say "${D}预测（跑之前写下，2026-11-18 第二次实跑的版本）：${N}"
say "  ${D}· cool120：首缩 t≈0，第二步必须等满 120 秒 → 间隔 120 秒${N}"
say "  ${D}· cool0  ：首缩 t≈0，第二步在同一秒内完成 → 间隔 0 秒${N}"
say "  ${D}            这一点我第一次预测错了，以为会隔一个巡检周期 15 秒。${N}"
say "  ${D}            实际上是：写 status 立刻触发下一轮，15 秒只是兜底下限，不是间隔。${N}"
say "  ${D}· stab120：首缩被推迟到 t≈120（稳定窗口），且窗口到期后剩余的步进${N}"
say "  ${D}            会连锁完成，因为计时起点没被重新武装${N}"

say "\n${D}开始采样（每 2 秒一次，只在副本数变化时打印）...${N}\n"
printf "  ${D}%-7s %-14s %-14s %-14s${N}\n" "t" "cool120" "cool0" "stab120"
prev=""
for i in $(seq 1 $(( OBSERVE / 2 ))); do
  s=$(snapshot)
  if [ "$s" != "$prev" ]; then
    t=$(( $(date +%s) - T0 ))
    v1=$(printf '%s' "$s" | tr ' ' '\n' | grep '^exp3-cool120=' | cut -d= -f2)
    v2=$(printf '%s' "$s" | tr ' ' '\n' | grep '^exp3-cool0=' | cut -d= -f2)
    v3=$(printf '%s' "$s" | tr ' ' '\n' | grep '^exp3-stab120=' | cut -d= -f2)
    printf "  %-7s %-14s %-14s %-14s\n" "${t}s" "${v1:-?}" "${v2:-?}" "${v3:-?}"
    prev="$s"
  fi
  sleep 2
done

# ─────────────────────────────────────────────────────────────
step "阶段 1 结论 / 用 Events 的时间戳算，不看采样"
# ─────────────────────────────────────────────────────────────
report() {  # app label
  local app=$1 label=$2
  local -a ts=()
  mapfile -t ts < <(kubectl -n "$NS3" get events \
      --field-selector "involvedObject.name=${app},reason=KubeStasisScaleDown" \
      -o jsonpath='{range .items[*]}{.lastTimestamp}{"\n"}{end}' 2>/dev/null | grep -v '^$' | sort)
  local n=${#ts[@]}
  if [ "$n" -lt 1 ]; then
    say "  ${R}✗${N} ${app}: 没有缩容事件（${label}）"; return
  fi
  local first_s delay gaps="" i g a b
  first_s=$(date -d "${ts[0]}" +%s 2>/dev/null)
  delay=$(( first_s - T0 ))
  for (( i=1; i<n; i++ )); do
    a=$(date -d "${ts[$((i-1))]}" +%s 2>/dev/null)
    b=$(date -d "${ts[$i]}" +%s 2>/dev/null)
    [ -z "$a" ] || [ -z "$b" ] && continue
    g=$(( b - a )); gaps="${gaps}${g}s "
  done
  say "  ${B}${app}${N}  ${D}(${label})${N}"
  say "    缩容 ${n} 次，首次距创建 ${delay} 秒，相邻间隔: ${gaps:-（只一次）}"
}

report exp3-cool120 "期望：间隔 120 秒"
say ""
report exp3-cool0   "期望：首缩立即，间隔 0 秒"
say ""
report exp3-stab120 "期望：首缩推迟约 120 秒，之后连锁"

say "\n${D}两组窗口的差别，一句话：${N}"
say "  ${D}冷却挡的是「这一步之后的所有步」，每一步都要重新等满窗口；${N}"
say "  ${D}稳定窗口挡的是「第一次」，窗口到期后就把剩余的步一次走完。${N}"
say "  ${D}同为 120 秒，一个把 3→2→1 拆成 120 秒两段，一个把它们挤在同一秒。${N}"

# ─────────────────────────────────────────────────────────────
step "阶段 2 / 稳定窗口的计时能否跨重启（实验 4 本体）"
# ─────────────────────────────────────────────────────────────
# 命题（代码注释原话）：
#   "计时状态放在 status 里而不是内存里——控制器会重启，内存计时一重启
#    就清零，恰好在滚动发布时给出一次『窗口已满』的假信号。"
say "${D}做法：stab=120 的 App 起好后，等 status.belowTargetSince 出现，${N}"
say "${D}在第 ${RESTART_AT} 秒重启 manager，看计时起点有没有被重置、缩容在第几秒发生。${N}"
say ""
say "${D}预测：${N}"
say "  ${D}· 计时在 status → belowTargetSince 重启前后完全一致，缩容仍在 t≈120${N}"
say "  ${D}· 计时在内存 → 重启后重新计时，缩容推迟到 t≈${RESTART_AT}+120${N}，或立刻发生${N}"

apply_app exp4-stab "$NS4" 3 1 0 120 || die "创建 exp4-stab 失败"
say "\n${G}✓${N} exp4-stab 已创建（3 副本，min=1，cooldown=0，stab=120）"

BTS=""
for i in $(seq 1 40); do
  BTS=$(kubectl -n "$NS4" get app exp4-stab -o jsonpath='{.status.belowTargetSince}' 2>/dev/null)
  [ -n "$BTS" ] && break
  sleep 1
done
if [ -z "$BTS" ]; then
  say "${Y}!${N} 40 秒内 status.belowTargetSince 没有出现"
  say "${Y}!${N} 说明运行中的控制器没有实现稳定窗口，阶段 2 无法进行（阶段 1 的 stab120 组会印证）"
  exit 0
fi
say "${G}✓${N} 计时起点已写入 status: ${BTS}"

say "\n${D}等 ${RESTART_AT} 秒后重启 manager...${N}"
sleep "$RESTART_AT"
say "${D}执行 kubectl rollout restart（不改镜像、不改 args）${N}"
kubectl -n "$DEPLOY_NS" rollout restart deploy "$DEPLOY" >/dev/null || die "重启失败"
kubectl -n "$DEPLOY_NS" rollout status deploy "$DEPLOY" --timeout=120s >/dev/null 2>&1 \
  || say "${Y}!${N} manager 未在 120 秒内就绪，下面的时序可能被拖慢"
AFTER=$(kubectl -n "$NS4" get app exp4-stab -o jsonpath='{.status.belowTargetSince}' 2>/dev/null)
say "${G}✓${N} manager 已重新就绪，image 仍是 $(kubectl -n "$DEPLOY_NS" get deploy "$DEPLOY" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
say "  重启后 belowTargetSince = ${AFTER:-—}"

say "\n${D}继续观察，直到计时起点后 160 秒...${N}\n"
bts_s=$(date -d "$BTS" +%s)
while true; do
  now=$(date +%s); el=$(( now - bts_s ))
  [ "$el" -ge 160 ] && break
  r=$(kubectl -n "$NS4" get app exp4-stab -o jsonpath='{.spec.replicas}' 2>/dev/null)
  printf "\r  ${D}距计时起点 %3ss  副本=%s${N}   " "$el" "${r:-?}"
  [ "$r" = "1" ] && break
  sleep 3
done
printf "\n"

# ─────────────────────────────────────────────────────────────
step "阶段 2 结论"
# ─────────────────────────────────────────────────────────────
local_ts=()
mapfile -t local_ts < <(kubectl -n "$NS4" get events \
    --field-selector "involvedObject.name=exp4-stab,reason=KubeStasisScaleDown" \
    -o jsonpath='{range .items[*]}{.lastTimestamp}{"\n"}{end}' 2>/dev/null | grep -v '^$' | sort)

say "  缩容事件时间轴:"
for t in "${local_ts[@]}"; do say "    $t"; done

n=${#local_ts[@]}
if [ "$n" -ge 1 ]; then
  s1=$(date -d "${local_ts[0]}" +%s)
  first_el=$(( s1 - bts_s ))
  say ""
  say "  首次缩容发生在计时起点后 ${first_el} 秒（窗口 120 秒 + 最多一个巡检周期）"
  say ""
  if [ "$AFTER" = "$BTS" ] && [ "$first_el" -ge 110 ]; then
    say "  ${G}✓ 计时在 status 里，跨重启存活。${N}"
    say "  重启前后 belowTargetSince 完全一致，说明它是从 etcd 读回来的，"
    say "  不是进程内存变量。滚动发布不会给出「窗口已满」的假信号，"
    say "  engine.go 那句设计主张在这一条路径上成立。"
  elif [ "$AFTER" != "$BTS" ]; then
    say "  ${Y}! 重启后计时起点变了（${BTS} → ${AFTER}），说明重启触发了重新计时。${N}"
    say "  去 app_controller.go 查 belowTargetSince 的写入点，看是不是每轮无条件覆盖。"
  else
    say "  ${Y}? 计时起点没变，但首缩比窗口早了 ${first_el} 秒，看时间轴自己判断。${N}"
  fi
  if [ "$n" -ge 2 ]; then
    s2=$(date -d "${local_ts[1]}" +%s)
    say ""
    say "  第二次缩容距第一次 $(( s2 - s1 )) 秒 —— 这就是「窗口只挡第一次」的直接证据。"
  fi
fi

# ─────────────────────────────────────────────────────────────
step "阶段 3 / 清理"
# ─────────────────────────────────────────────────────────────
if [ "$KEEP" = "1" ]; then
  say "${Y}--keep：保留 ${NS3} / ${NS4}，看完执行 kubectl delete ns ${NS3} ${NS4}${N}"
else
  cleanup
fi

cat <<'NOTE'

── 这两个实验分别证明了什么 ────────────────────────────
实验 3（冷却）：冷却在事件流里制造的是固定 120 秒间隔，每一步都要重等。
关掉它，间隔塌缩到 0 秒——不是 15 秒。因为写 status 会立刻触发下一轮
reconcile，15 秒那个 RequeueAfter 只是兜底下限，不是实际节奏。

实验 4（稳定窗口）：它挡的是"第一次缩容"，计时起点是信号首次低于目标的
时刻，记在 status.belowTargetSince 里。窗口一旦到期，剩余的步进会连锁
完成，因为起点没有被重新武装。所以 120 秒的稳定窗口把 3→2、2→1 挤在
同一秒，而 120 秒的冷却把它们拆成两段。

同一个数字，两种语义，效果完全不同。这就是"两个窗口不是一回事"的实证。

实验 4 的第二层：重启 manager 不重置计时。belowTargetSince 在重启前后
一模一样，说明它从 etcd 读回。这一条单元测试做不到——单元测试里 status
是测试自己赋的内存变量，"重启"在模型里不存在。

── 关于镜像的那个教训 ──────────────────────────────────
不要用 commit 时间推断镜像里有什么。p9 的构建时间比稳定窗口那个提交
早 8 分钟，行为里却有这个功能：它是拿当时未提交的工作区构建的。
判断一个运行中的控制器有什么能力，看 status 里出现什么字段、
看它建出来的 Deployment 有没有探针，不看 tag、不看提交时间。
NOTE
