#!/usr/bin/env bash
# 实验 7：L3 回滚需要什么前置，回滚到底改的是谁
#
# 边界：只操作 lab-exp7 一个临时命名空间。
#       不碰 bench（压测基线）、不碰 kubestasis-hv（控制器）、不重建镜像、不改仓库代码。
#
# 用法：
#   bash exp7.sh           完整跑 + 自动清理
#   bash exp7.sh --keep    保留命名空间看现场（看完手动 kubectl delete ns lab-exp7）
#
# 前置为什么必须"两次 apply"：
#   Rollback（internal/healer/engine.go:386）列的是带 app=<名字> 标签的 ReplicaSet，
#   按 deployment.kubernetes.io/revision 注解挑"镜像和当前不同"的最大 revision。
#   一个从创建就用 crash 镜像的 App 只有 rev1，排除当前镜像后 best==nil，
#   直接返回 0 —— 这就是实验 8 里那句 "no action available" 的来源。
#
set -uo pipefail

NS=lab-exp7

# 守卫：命名空间白名单 + context 检查（见 hack/lab/lib.sh）
. "$(dirname "$0")/lib.sh"
lab_guard "$NS"
APP=exp7
GOOD_IMAGE=kubestasis-demoapp:v1
BAD_IMAGE=kubestasis-demoapp:v2-crash
REPLICAS=3
OBSERVE=${OBSERVE:-180}
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
    say "${R}✗${N} ${NS} 还在，手动执行: kubectl delete ns ${NS}"
  fi
  say "${D}原有资源复核（只读）:${N}"
  kubectl get app -A --no-headers 2>/dev/null | sed 's/^/  /'
  kubectl -n kubestasis-hv get deploy --no-headers 2>/dev/null | awk '{print "  manager: "$1" "$2" AGE "$5}'
  kubectl -n bench get deploy prometheus --no-headers 2>/dev/null | awk '{print "  prom:    "$1" "$2" AGE "$5}'
}

trap '[ "$KEEP" = "1" ] || cleanup' EXIT

rs_table() {
  kubectl -n "$NS" get rs -l "app=$APP" \
    -o custom-columns='NAME:.metadata.name,REV:.metadata.annotations.deployment\.kubernetes\.io/revision,DESIRED:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image' \
    --no-headers 2>/dev/null | sort -k2 -n | sed 's/^/  /'
}

pod_summary() {
  kubectl -n "$NS" get pod -l "app=$APP" \
    -o jsonpath='{range .items[*]}{.status.phase}/{.status.containerStatuses[0].state.waiting.reason}{" "}{end}' 2>/dev/null
}

ready_count() {
  kubectl -n "$NS" get pod -l "app=$APP" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c '^true$'
}

app_image() {
  kubectl -n "$NS" get app "$APP" -o jsonpath='{.spec.image}' 2>/dev/null
}

# ─────────────────────────────────────────────────────────────
step "阶段 0 / 前置检查"
# ─────────────────────────────────────────────────────────────
kubectl version --request-timeout=5s >/dev/null 2>&1 || die "kubectl 连不上集群"
kubectl -n kubestasis-hv get deploy ks-kubestasis >/dev/null 2>&1 \
  || die "控制器 ks-kubestasis 不在 kubestasis-hv，实验需要它处理 App"
kubectl get crd apps.kubestasis.io >/dev/null 2>&1 || die "CRD apps.kubestasis.io 不存在"

# crictl 输出是「仓库名 <空格> tag」，不是 repo:tag，要分开比对
for img in "$GOOD_IMAGE" "$BAD_IMAGE"; do
  repo="${img%:*}"; tag="${img##*:}"
  [ "$(docker exec desktop-control-plane crictl images 2>/dev/null \
    | awk -v r="$repo" -v t="$tag" '$1 ~ r && $2 == t {print "y"; exit}')" = "y" ] \
    || die "节点里没有 $img，先执行: kind load docker-image $img"
done

say "${G}✓${N} 集群 / 控制器 / CRD / 两个镜像 就绪"
say "${D}控制器参数（heal-cooldown 决定 L2→L3 升级窗口，默认 3m）:${N}"
kubectl -n kubestasis-hv get deploy ks-kubestasis \
  -o jsonpath='  {.spec.template.spec.containers[0].args}{"\n"}' 2>/dev/null

kubectl get ns "$NS" >/dev/null 2>&1 && { say "${Y}发现残留 ${NS}，先清${N}"; kubectl delete ns "$NS" --timeout=60s >/dev/null 2>&1; }

# ─────────────────────────────────────────────────────────────
step "阶段 1 / 造前置：先发布 v1，等它真的产生 rev1"
# ─────────────────────────────────────────────────────────────
kubectl create ns "$NS" >/dev/null || die "建命名空间失败"

kubectl apply -f - >/dev/null <<EOF || die "App 创建失败（webhook 是否正常？）"
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

say "${D}等 rev1 rollout 完成 —— 这一步不能省。v1 没就绪就改镜像，两次变更会被"
say "Deployment 合成一个 revision，rev1 不存在，L3 就没有回滚目标。${N}"

kubectl -n "$NS" rollout status "deploy/$APP" --timeout=120s >/dev/null 2>&1 \
  || die "v1 没 rollout 完，看看: kubectl -n ${NS} get pod"

rev1=""
for _ in $(seq 1 20); do
  rev1=$(kubectl -n "$NS" get rs -l "app=$APP" \
    -o jsonpath='{range .items[*]}{.metadata.annotations.deployment\.kubernetes\.io/revision}={.metadata.name} {end}' 2>/dev/null \
    | tr ' ' '\n' | grep '^1=' | head -1)
  [ -n "$rev1" ] && break
  sleep 2
done
[ -n "$rev1" ] || die "没找到 revision=1 的 ReplicaSet，前置没造成"
rev1_name="${rev1#1=}"

say "\n${G}✓ rev1 已存在${N}: ${rev1_name}"
say "${D}当前 RS 历史:${N}"
rs_table
say "\n${D}当前 Pod:${N} $(pod_summary)"
say "${D}App 状态:${N} $(kubectl -n "$NS" get app "$APP" -o jsonpath='phase={.status.phase} ready={.status.currentReplicas}/{.status.desiredReplicas}' 2>/dev/null)"

# ─────────────────────────────────────────────────────────────
step "阶段 2 / 发布坏镜像，观察升级路径"
# ─────────────────────────────────────────────────────────────
say "  ${B}预测（按代码推的，跑完逐条对照）${N}"
say "  ${D}t≈0-5s${N}    Deployment 模板切到 crash，rev2 建出来，只起 1 个 pod"
say "  ${D}           （maxSurge 25% 向上取整 → 1；maxUnavailable 25% 向下取整 → 0）"
say "  ${D}           所以旧 3 个 v1 pod 一个都不杀，ready 恒为 3 —— App 不会全挂${N}"
say "  ${D}t≈15-35s${N}   第一轮自愈。CrashLoop 直接把 SuggestedLevel 定成 L2，跳过 L1"
say "  ${D}           Event: L2 Isolate: deleted 1 unhealthy pod(s)${N}"
say "  ${D}t≈35-70s${N}   冷却期内复发 → level=L2+1=L3 → Rollback 挑 rev1(v1)"
say "  ${D}           写的是 App.spec.image，不是 Deployment${N}"
say "  ${D}t≈50-90s${N}   spec.image=v1 → 模板 hash 与 rev1 相同 → Deployment 复用那个 RS，"
say "  ${D}           把它的 revision 注解从 1 改成 3（不是新建 RS），rev2 归零，副本拉回 3"
say "  ${D}           三个 pod 全 Ready，App 回 Stable${N}"
say "  ${D}实测（11-17 两次）: t≈5s 起 crash pod，t≈35-45s 出 L3，t=48s spec 已回滚${N}\n"
say "  ${D}判别：L3 事件出现、且 App.spec.image 自己变回 v1（没人手工改），才算回滚写在 CR 层。${N}\n"

say "${D}patch spec.image → ${BAD_IMAGE}${N}"
kubectl -n "$NS" patch app "$APP" --type=merge \
  -p "{\"spec\":{\"image\":\"${BAD_IMAGE}\"}}" >/dev/null || die "patch 失败"

prev=""; start=$(date +%s); l2=""; l3=""; min_ready=$REPLICAS; reverted_at=""
deadline=$(( start + OBSERVE ))

while [ "$(date +%s)" -lt "$deadline" ]; do
  t=$(( $(date +%s) - start ))
  spec=$(app_image)
  deploy_img=$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  ready=$(ready_count); rc=$?
  [ -z "$ready" ] && ready=0
  [ "$ready" -lt "$min_ready" ] 2>/dev/null && min_ready=$ready
  pods=$(pod_summary)

  cur="spec=${spec} deploy=${deploy_img} ready=${ready} pods=${pods}"
  if [ "$cur" != "$prev" ]; then
    printf "  ${D}t=%03ds${N} spec=%-28s ready=%s  %s\n" "$t" "${spec:-?}" "${ready}" "${pods}"
    prev="$cur"
  fi

  [ -z "$l2" ] && l2=$(kubectl -n "$NS" get events --field-selector reason=KubeStasisHealAction \
    -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep -m1 "L2 Isolate")
  [ -z "$l3" ] && l3=$(kubectl -n "$NS" get events --field-selector reason=KubeStasisHealAction \
    -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep -m1 "L3 Rollback")

  if [ -n "$l3" ] && [ -z "$reverted_at" ] && [ "$spec" = "$GOOD_IMAGE" ]; then
    reverted_at=$t
    say "  ${G}→ t=${t}s spec.image 已被改回 ${GOOD_IMAGE}，再等 30 秒看 POD 收尾${N}"
    sleep 30
    break
  fi
  sleep 3
done

[ -n "$l2" ] || die "${OBSERVE} 秒内没等到 L2。查: kubectl -n ${NS} get events --sort-by=.lastTimestamp"

# ─────────────────────────────────────────────────────────────
step "证据 1 / 自愈事件流（Reason 全部是 KubeStasisHealAction）"
# ─────────────────────────────────────────────────────────────
kubectl -n "$NS" get events --field-selector reason=KubeStasisHealAction \
  -o jsonpath='{range .items[*]}{.lastTimestamp}  {.message}{"\n"}{end}' 2>/dev/null \
  | cut -c1-150 | sed 's/^/  /'

step "证据 2 / ReplicaSet 历史（回滚有没有造出新 revision）"
rs_table
rs_now=$(kubectl -n "$NS" get rs -l "app=$APP" \
  -o jsonpath='{range .items[*]}{.metadata.annotations.deployment\.kubernetes\.io/revision}={.metadata.name} {end}' 2>/dev/null \
  | tr ' ' '\n' | grep '^3=' | head -1)

say "\n  ${D}布场时的 rev1 RS: ${rev1_name}${N}"
say "  ${D}回滚后的 rev3 RS: ${rs_now#3=}${N}"
if [ -n "$rs_now" ] && [ "${rs_now#3=}" = "$rev1_name" ]; then
  say "  ${G}→ 同一个对象${N}：Deployment 按 pod-template-hash 复用了旧 RS，只把 revision"
  say "    注解从 1 改成 3。所以列表里查不到 revision=1，但它就是发布 v1 时那个 RS。"
elif [ -n "$rs_now" ]; then
  say "  ${Y}→ 不是同一个对象${N}：模板有差异，Deployment 新建了 RS。"
  say "    diff 两个 RS 的 spec.template 能定位差在哪（探针、资源、env 都可能）。"
else
  say "  ${Y}→ 没看到 revision=3 的 RS${N}，回滚可能没走完，检查 spec.image 与 Pod 状态。"
fi
say "  ${D}结论：「回滚到 revision 1」不是把旧 RS 复制回来，而是把期望值改回去，"
say "  让 Deployment 自己按模板 hash 挑。复用还是新建，由 hash 决定，不由代码决定。${N}"

step "证据 3 / 到底谁被改了"
say "  App.spec.image      = ${B}$(app_image)${N}"
say "  Deployment 模板镜像 = ${B}$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)${N}"
say "  status.rollbackRevision = $(kubectl -n "$NS" get app "$APP" -o jsonpath='{.status.rollbackRevision}' 2>/dev/null)"
lvl=$(kubectl -n "$NS" get app "$APP" -o jsonpath='{.status.lastHealLevel}' 2>/dev/null)
case "$lvl" in
  0) lvlname="L1 扩容" ;;
  1) lvlname="L2 摘除" ;;
  2) lvlname="L3 回滚" ;;
  *) lvlname="未记录" ;;
esac
say "  status.lastHealLevel    = ${lvl:-空}（枚举 0 基: 0=L1 1=L2 2=L3，所以 2 就是 L3）${D} ← ${lvlname}${N}"
say "  status.lastHealAction   = $(kubectl -n "$NS" get app "$APP" -o jsonpath='{.status.lastHealAction}' 2>/dev/null)"
say "  status.phase            = $(kubectl -n "$NS" get app "$APP" -o jsonpath='{.status.phase}' 2>/dev/null)"
say "  status.currentImage     = $(kubectl -n "$NS" get app "$APP" -o jsonpath='{.status.currentImage}' 2>/dev/null)"
say ""
say "  ${D}两个空字段都是真实现象，不是脚本没读到:${N}"
say "  ${D}· lastHealAction 为空：收敛后 updateStatus 会主动清空它（app_controller.go:454，"
say "    phase=Stable 且 ready>=desired 时），所以它只保留「最后一次未恢复的动作」。${N}"
say "  ${D}· rollbackRevision 为空：这个字段只有金丝雀回滚那条路径才写（:158），"
say "    自愈 L3 回滚不写。也就是说回滚到哪一版只留在 Events 里，status 查不到。${N}"
say ""
say "  ${D}可用性最低点: ready=${min_ready} / 期望 ${REPLICAS}（全程未归零 = 旧 RS 一直撑着）${N}"
say "  ${D}Pod 现状:${N} $(pod_summary)"

final=$(app_image)
if [ "$final" = "$GOOD_IMAGE" ]; then
  say "\n  ${G}✓ 断言通过${N}：L3 把 spec.image 改回了 ${GOOD_IMAGE}，走的是 CR 层而不是直接改 Deployment"
else
  say "\n  ${Y}? 断言未通过${N}：spec.image 仍是 ${final}，检查 L3 事件与 RS 历史"
fi

# ─────────────────────────────────────────────────────────────
step "阶段 4 / 清理"
# ─────────────────────────────────────────────────────────────
if [ "$KEEP" = "1" ]; then
  say "${Y}--keep 已指定，保留 ${NS}${N}"
  say "${D}看完执行: kubectl delete ns ${NS}${N}"
else
  cleanup
fi

cat <<'NOTE'

── 这个实验证明了什么 ──────────────────────────────────
1. L3 的前置是「历史上存在另一个镜像的 ReplicaSet」。回滚读的是
   ReplicaSet 的 revision 注解，不是 git、不是镜像 tag 列表。
   实验 8 那个 App 从创建就是 crash 镜像，只有 rev1，排除当前镜像
   后没有候选，所以永远 "no action available"。两个实验互为正反面。

2. 回滚写的是 App.spec.image，不是 Deployment。events 里出现
   L3 Rollback 之后，spec 自己变回去，而没人手工改过 —— 这是它
   走 CR 层的直接证据。好处是回滚和正常发布共用一条收敛路径。

3. 坏镜像不会造成全站不可用。默认滚动策略 maxUnavailable 向下
   取整为 0，新 RS 先起 1 个，旧副本一个不杀。所以你看到的是
   「3 Ready + 1 CrashLoopBackOff」，不是「0 Ready」。

4. 升级是时间驱动的，不是次数驱动的。冷却期内（heal-cooldown=3m）
   同 level 复发才 +1，所以 L2 之后约 15~30 秒就会到 L3，而不是
   等三次。

── 两个容易讲错的地方 ──────────────────────────────────
· 不要说「回滚到上一个 ReplicaSet」。选版逻辑是「排掉当前镜像和
  坏镜像后 revision 最大的那个」，跳版是可能的。
· 不要说「回滚后能看到 revision=1 的 RS」。Deployment 复用了同一个
  RS，只把注解从 1 改成 3，所以列表里 revision=1 消失了。日志写
  "revision 1" 指的是回滚目标的修订号，不是当前存在的对象。
· status.lastHealLevel 是 0 基枚举：0=L1、1=L2、2=L3。看到 2 别
  以为停在 L2。而且 lastHealAction 收敛后会被清空，排障只能看 Events。

── 一个可以改的点（面试可主动提）─────────────────────
自愈 L3 回滚不写 status.rollbackRevision，只有金丝雀回滚写。结果是
「回滚到哪一版」只在 Events 里留痕，status 永远为空。补一行
statusPatch{rolledBack: true, rollbackRevision: rev} 就能对齐，还能
顺带让 lastImageChangeAt 在自愈回滚时被正确关闭。
NOTE
