#!/usr/bin/env bash
# 实验 6：冷却窗口短于故障探测周期，升级条件还成立吗
#
# 边界：改的是 manager 的启动参数（集群侧），不改仓库代码、不重建镜像。
#       参数在清理时还原，命名空间 lab-exp6 跑完删除。
#
# 用法：
#   bash exp6.sh           完整跑 + 自动还原参数与清理
#   bash exp6.sh --keep    保留 lab-exp6 看现场（参数仍会还原）
#
# 原设计的预测有错，已按代码重写：
#   文档原来写「反复出现 L1 扩容，副本越扩越多」。但 crash 镜像的等待原因是
#   CrashLoopBackOff，Diagnose 直接把 SuggestedLevel 定成 L2，第一轮动作就是
#   L2 而不是 L1。所以短冷却下的现象是「反复 L2 删 Pod，永远不升级到 L3」。
#
# 判别设计：同一份清单、同一个 App，只改冷却窗口，跑两段。
#   第一段 5s  → 期望只有 L2，没有 L3
#   第二段 3m  → 期望 L3 出现，spec 回滚
#   唯一变量是冷却窗口，所以结论能落到「升级依赖时间窗口」这一条上。
#
set -uo pipefail

NS=lab-exp6

# 守卫：命名空间白名单 + context 检查（见 hack/lab/lib.sh）
. "$(dirname "$0")/lib.sh"
lab_guard "$NS"
APP=exp6
GOOD_IMAGE=kubestasis-demoapp:v1
BAD_IMAGE=kubestasis-demoapp:v2-crash
REPLICAS=3
DEPLOY=ks-kubestasis
DEPLOY_NS=kubestasis-hv
SHORT_COOLDOWN=5s
OBSERVE_SHORT=${OBSERVE_SHORT:-120}
OBSERVE_RESTORE=${OBSERVE_RESTORE:-90}
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

B="\033[1m"; D="\033[2m"; R="\033[31m"; G="\033[32m"; Y="\033[33m"; N="\033[0m"
say()  { printf "%b\n" "$*"; }
step() { printf "\n%b%s%b\n" "$B$Y" "$*" "$N"; }
die()  { say "${R}✗ $*${N}"; exit 1; }

CLEANED=0
ORIG_ARG=""
ARG_IDX=-1
PATCHED=0

# ─────────────────────────────────────────────────────────────
# 清理：先还原 manager 参数（集群级），再删命名空间。
# ─────────────────────────────────────────────────────────────
cleanup() {
  [ "$CLEANED" = "1" ] && return
  CLEANED=1

  if [ "$PATCHED" = "1" ] && [ -n "$ORIG_ARG" ] && [ "$ARG_IDX" -ge 0 ]; then
    kubectl -n "$DEPLOY_NS" patch deploy "$DEPLOY" --type=json \
      -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/${ARG_IDX}\",\"value\":\"${ORIG_ARG}\"}]" \
      >/dev/null 2>&1
    kubectl -n "$DEPLOY_NS" rollout status "deploy/$DEPLOY" --timeout=180s >/dev/null 2>&1
  fi

  kubectl delete ns "$NS" --ignore-not-found --timeout=90s >/dev/null 2>&1

  local now
  now=$(kubectl -n "$DEPLOY_NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null)
  if printf '%s' "$now" | grep -q -- '--heal-cooldown=3m'; then
    say "${G}✓${N} manager 参数已还原: --heal-cooldown=3m"
  else
    say "${R}✗${N} manager 参数没还原干净，当前: ${now}"
    say "  手动: kubectl -n ${DEPLOY_NS} patch deploy ${DEPLOY} --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/${ARG_IDX}\",\"value\":\"--heal-cooldown=3m\"}]'"
  fi
  kubectl -n "$DEPLOY_NS" rollout status "deploy/$DEPLOY" --timeout=180s >/dev/null 2>&1 \
    && say "${G}✓${N} manager 已就绪"

  say "${D}原有资源复核（只读）:${N}"
  kubectl get app -A --no-headers 2>/dev/null | sed 's/^/  /'
}

trap '[ "$KEEP" = "1" ] || cleanup' EXIT

args_json() {
  kubectl -n "$DEPLOY_NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null
}

cooldown_arg() {
  printf '%s' "$(args_json)" | tr ',' '\n' | tr -d '"[]' | grep -- '--heal-cooldown=' | head -1
}

find_arg_idx() {
  local i=0 a
  for a in $(printf '%s' "$(args_json)" | sed 's/^\[//; s/\]$//; s/","/\n/g; s/"//g'); do
    case "$a" in
      --heal-cooldown=*) ARG_IDX=$i; ORIG_ARG="$a" ;;
    esac
    i=$((i+1))
  done
}

set_cooldown() {
  kubectl -n "$DEPLOY_NS" patch deploy "$DEPLOY" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/${ARG_IDX}\",\"value\":\"--heal-cooldown=$1\"}]" \
    >/dev/null || die "改 manager 参数失败"
  PATCHED=1
  kubectl -n "$DEPLOY_NS" rollout status "deploy/$DEPLOY" --timeout=180s >/dev/null 2>&1 \
    || die "manager 没在 180 秒内就绪，检查: kubectl -n ${DEPLOY_NS} get pod"
}

wait_deploy() {  # App 创建后 Deployment 要等控制器建出来，否则 rollout status 直接报 NotFound
  local i
  for i in $(seq 1 45); do
    kubectl -n "$NS" get deploy "$APP" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

wait_app_ready() {  # 等 manager 就绪：webhook 在重建期间不可用，写 App 会被拒
  local i
  for i in $(seq 1 45); do
    [ "$(kubectl -n "$DEPLOY_NS" get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "1" ] && return 0
    sleep 2
  done
  return 1
}

l2_count() {
  kubectl -n "$NS" get events --field-selector reason=KubeStasisHealAction \
    -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep -c "L2 Isolate"
}

has_l3() {
  kubectl -n "$NS" get events --field-selector reason=KubeStasisHealAction \
    -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep -m1 "L3 Rollback"
}

# ─────────────────────────────────────────────────────────────
step "阶段 0 / 前置检查"
# ─────────────────────────────────────────────────────────────
kubectl version --request-timeout=5s >/dev/null 2>&1 || die "kubectl 连不上集群"
kubectl -n "$DEPLOY_NS" get deploy "$DEPLOY" >/dev/null 2>&1 || die "manager 不在 ${DEPLOY_NS}"

for img in "$GOOD_IMAGE" "$BAD_IMAGE"; do
  repo="${img%:*}"; tag="${img##*:}"
  [ "$(docker exec desktop-control-plane crictl images 2>/dev/null \
    | awk -v r="$repo" -v t="$tag" '$1 ~ r && $2 == t {print "y"; exit}')" = "y" ] \
    || die "节点里没有 $img，先执行: kind load docker-image $img"
done

find_arg_idx
[ "$ARG_IDX" -ge 0 ] || die "manager 的 args 里没有 --heal-cooldown，脚本假设不成立"
say "${G}✓${N} 集群 / manager / 镜像 就绪"
say "${D}原始参数: ${ORIG_ARG}（在 args 第 ${ARG_IDX} 位，清理时按原位还原）${N}"

kubectl get ns "$NS" >/dev/null 2>&1 && { say "${Y}发现残留 ${NS}，先清${N}"; kubectl delete ns "$NS" --timeout=60s >/dev/null 2>&1; }

# ─────────────────────────────────────────────────────────────
step "阶段 1 / 预测（跑之前先定死）"
# ─────────────────────────────────────────────────────────────
say "  ${B}第一段 cooldown=${SHORT_COOLDOWN}${N}"
say "    升级条件是 ${D}now - lastHealAt < cooldown 且 level <= lastHealLevel${N}。"
say "    一轮探测约 15 秒，5 秒窗口永远等不到，所以只有 L2 反复，没有 L3。"
say "    期望：${OBSERVE_SHORT}s 内 2 次以上 L2，0 次 L3，spec.image 一直是 crash，"
say "         status.lastHealLevel=1（枚举 0 基，1=L2）"
say ""
say "  ${B}第二段还原 cooldown=3m，同一故障不重建${N}"
say "    距上次动作只有十几秒，落在 3 分钟内，升级条件成立。"
say "    期望：30 秒内出现 L3，spec.image 自动变回 v1"
say ""

# ─────────────────────────────────────────────────────────────
step "阶段 2 / 布场：先 v1 就绪，再换 crash（保证 L3 有回滚目标）"
# ─────────────────────────────────────────────────────────────
set_cooldown "$SHORT_COOLDOWN"
[ "$(cooldown_arg)" = "--heal-cooldown=${SHORT_COOLDOWN}" ] || die "参数没生效"
wait_app_ready || die "manager 重建后一直没 ready"
say "${G}✓${N} manager 已用 ${SHORT_COOLDOWN} 重启完成: $(cooldown_arg)"
say "  ${D}注意 AGE: $(kubectl -n "$DEPLOY_NS" get deploy "$DEPLOY" --no-headers | awk '{print $4}')（刚重建过，这是预期代价）${N}"

kubectl create ns "$NS" >/dev/null || die "建命名空间失败"

kubectl apply -f - >/dev/null <<EOF || die "App 创建失败"
apiVersion: kubestasis.io/v1alpha1
kind: App
metadata:
  name: ${APP}
  namespace: ${NS}
spec:
  image: ${GOOD_IMAGE}
  replicas: ${REPLICAS}
  port: 8080
  health:
    strategy: graduated
EOF

wait_deploy || die "控制器没在 90 秒内创建 Deployment，查: kubectl -n ${DEPLOY_NS} logs deploy/${DEPLOY} --tail=30"
out=$(kubectl -n "$NS" rollout status "deploy/$APP" --timeout=150s 2>&1) || die "v1 没就绪: ${out}"
say "${G}✓${N} v1 就绪，rev1 已产生: $(kubectl -n "$NS" get rs -l "app=$APP" -o jsonpath='{range .items[*]}{.metadata.annotations.deployment\.kubernetes\.io/revision}{" "}{end}')"

kubectl -n "$NS" patch app "$APP" --type=merge -p "{\"spec\":{\"image\":\"${BAD_IMAGE}\"}}" >/dev/null \
  || die "patch 镜像失败"
say "${D}已换成 crash 镜像，开始第一段观察${N}"

# ─────────────────────────────────────────────────────────────
step "阶段 3 / 第一段观察 ${OBSERVE_SHORT}s（cooldown=${SHORT_COOLDOWN}）"
# ─────────────────────────────────────────────────────────────
start=$(date +%s); prev=""; l3_seen=""
while [ $(( $(date +%s) - start )) -lt "$OBSERVE_SHORT" ]; do
  t=$(( $(date +%s) - start ))
  c=$(l2_count)
  spec=$(kubectl -n "$NS" get app "$APP" -o jsonpath='{.spec.image}' 2>/dev/null)
  pods=$(kubectl -n "$NS" get pod -l "app=$APP" \
    -o jsonpath='{range .items[*]}{.status.phase}/{.status.containerStatuses[0].state.waiting.reason}{" "}{end}' 2>/dev/null)
  cur="L2=${c} spec=${spec##*:} ${pods}"
  [ "$cur" != "$prev" ] && { printf "  ${D}t=%03ds${N} L2次数=%s  spec=%s  %s\n" "$t" "$c" "${spec##*:}" "$pods"; prev="$cur"; }

  l3_seen=$(has_l3)
  [ -n "$l3_seen" ] && break
  sleep 3
done

c_short=$(l2_count)
say ""
say "  第一段统计: L2 = ${B}${c_short}${N} 次，L3 = ${B}$([ -n "$l3_seen" ] && echo 出现 || echo 0)${N}"
say "  spec.image = $(kubectl -n "$NS" get app "$APP" -o jsonpath='{.spec.image}' 2>/dev/null)"
say "  status.lastHealLevel = $(kubectl -n "$NS" get app "$APP" -o jsonpath='{.status.lastHealLevel}' 2>/dev/null)${D}（0 基枚举，1=L2）${N}"

if [ -n "$l3_seen" ]; then
  say "  ${Y}? 5 秒窗口下仍然出现了 L3${N}：${l3_seen}"
  say "  ${D}那说明升级不只依赖冷却窗口，我的模型有缺，得回代码里找别的时间来源。${N}"
elif [ "$c_short" -ge 2 ]; then
  say "  ${G}✓ 符合预测${N}：同一级动作反复执行，升级从未触发"
else
  say "  ${Y}? L2 只有 ${c_short} 次，观察窗口可能不够，先别下结论${N}"
fi

# ─────────────────────────────────────────────────────────────
step "阶段 4 / 恢复 cooldown=3m，看同一故障会不会立刻升级"
# ─────────────────────────────────────────────────────────────
restore="${ORIG_ARG#--heal-cooldown=}"
set_cooldown "$restore"
[ "$(cooldown_arg)" = "--heal-cooldown=${restore}" ] || die "恢复失败"
PATCHED=0
say "${G}✓${N} manager 已恢复 ${restore}"

start=$(date +%s); l3_after=""; prev=""
while [ $(( $(date +%s) - start )) -lt "$OBSERVE_RESTORE" ]; do
  t=$(( $(date +%s) - start ))
  c=$(l2_count)
  spec=$(kubectl -n "$NS" get app "$APP" -o jsonpath='{.spec.image}' 2>/dev/null)
  cur="L2=${c} spec=${spec##*:}"
  [ "$cur" != "$prev" ] && { printf "  ${D}t=%03ds${N} L2次数=%s  spec=%s\n" "$t" "$c" "${spec##*:}"; prev="$cur"; }

  l3_after=$(has_l3)
  [ -n "$l3_after" ] && break
  sleep 3
done

say ""
if [ -n "$l3_after" ]; then
  say "  ${G}✓ 升级恢复${N}: ${l3_after}"
else
  say "  ${Y}? ${OBSERVE_RESTORE}s 内没等到 L3${N}，可能已到 L3 观察期或 Pod 正好不在 CrashLoop 状态"
fi

step "证据 / 完整事件流"
kubectl -n "$NS" get events --field-selector reason=KubeStasisHealAction \
  -o jsonpath='{range .items[*]}{.lastTimestamp}  {.message}{"\n"}{end}' 2>/dev/null \
  | cut -c1-140 | sed 's/^/  /'

say ""
say "  ReplicaSet: "
kubectl -n "$NS" get rs -l "app=$APP" \
  -o custom-columns='NAME:.metadata.name,REV:.metadata.annotations.deployment\.kubernetes\.io/revision,DESIRED:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image' \
  --no-headers 2>/dev/null | sort -k2 -n | sed 's/^/    /'

# ─────────────────────────────────────────────────────────────
step "阶段 5 / 清理"
# ─────────────────────────────────────────────────────────────
if [ "$KEEP" = "1" ]; then
  say "${Y}--keep 已指定，保留 ${NS}（manager 参数已还原）${N}"
  say "${D}看完执行: kubectl delete ns ${NS}${N}"
else
  cleanup
fi

cat <<'NOTE'

── 这个实验证明了什么 ──────────────────────────────────
1. 升级不是「故障次数」驱动的，是「时间窗口」驱动的。Apply 里的条件
   是 `now - lastHealAt < cooldown && level <= lastHealLevel`。冷却窗口
   比探测周期短，这个条件永远不成立，等级就永远停在 SuggestedLevel。

2. 后果是同一级动作无限重复：crash 镜像下表现为每隔十几秒删一次 Pod，
   删了重建、建了再删，问题一点没往前走。这和「自愈生效了」在事件流上
   看起来很像，都是 L2 Isolate。

3. 恢复 3 分钟的同一轮里立刻升到 L3，说明变量确实是冷却窗口，不是别的。

── 原设计为什么错 ────────────────────────────────────
文档原来预测「L1 扩容，副本越扩越多」。但 L1 的前提是故障建议 L1
（OOMKilled / HighRestarts）。crash 镜像的等待原因是 CrashLoopBackOff，
Diagnose 直接给 L2，第一轮就不会走 L1。要复现 L1 那一版，得有一个
「反复重启但不进 CrashLoopBackOff」或「OOM 但不崩」的镜像，demoapp
没有这个模式，所以这次只做了 L2 版本。

── 代价 ──────────────────────────────────────────────
改 manager 的 args 会重建 Pod，AGE 从 13d 变成几分钟。webhook 在重建
期间不可用（failurePolicy=Fail），任何 App 写入都会被拒，所以脚本里
先等 ready 再建对象。
NOTE
