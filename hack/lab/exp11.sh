#!/usr/bin/env bash
# 实验 11：绕过准入之后，控制器会不会自己兜住非法配置
#
# 边界：不动仓库代码、不重启 manager、不关 webhook。
#       只给 ValidatingWebhookConfiguration 的 namespaceSelector 加一个
#       排除项（lab-exp11），让这一个命名空间跳过校验，别处照旧受保护。
#
# 用法：
#   bash exp11.sh          完整跑 + 自动恢复选择器 + 清理
#   bash exp11.sh --keep   保留 lab-exp11 看现场（选择器仍会恢复）
#
# 为什么不用「关掉 webhook 再部署」：
#   --enable-webhook=false 只是不再提供服务，配置还在，而 failurePolicy=Fail。
#   结果是所有 App 写入被拒，不是「非法配置被接受」。要真的让校验消失，必须
#   处理配置对象本身；整个集群摘掉准入风险太大，按命名空间排除等价且安全。
#
# 这个实验会踩到一个死锁，脚本里专门复现并演示解法（阶段 5）：
#   非法对象一旦进库，恢复校验之后连「摘 finalizer」这次 UPDATE 都会被拒，
#   于是命名空间永远停在 Terminating。
#
set -uo pipefail

NS=lab-exp11

# 守卫：命名空间白名单 + context 检查（见 hack/lab/lib.sh）
. "$(dirname "$0")/lib.sh"
lab_guard "$NS"
APP=exp11-bad
BAD_IMAGE=nginx:latest
VWC=ks-kubestasis-validating
MN=3
MX=1
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

B="\033[1m"; D="\033[2m"; R="\033[31m"; G="\033[32m"; Y="\033[33m"; N="\033[0m"
say()  { printf "%b\n" "$*"; }
step() { printf "\n%b%s%b\n" "$B$Y" "$*" "$N"; }
die()  { say "${R}✗ $*${N}"; exit 1; }

CLEANED=0
BYPASSED=0
ORIG_VALS=""
BACKUP=/tmp/exp11-vwc-backup.yaml

norm() { printf '%s' "$1" | tr -d ' '; }

sel_vals() {
  kubectl get validatingwebhookconfiguration "$VWC" \
    -o jsonpath='{.webhooks[0].namespaceSelector.matchExpressions[0].values}' 2>/dev/null
}

sel_include() {  # 让 NS 跳过校验
  local v="${ORIG_VALS%]},\"${NS}\"]"
  kubectl patch validatingwebhookconfiguration "$VWC" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/webhooks/0/namespaceSelector/matchExpressions/0/values\",\"value\":${v}}]" \
    >/dev/null || return 1
  BYPASSED=1
}

sel_restore() {
  kubectl patch validatingwebhookconfiguration "$VWC" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/webhooks/0/namespaceSelector/matchExpressions/0/values\",\"value\":${ORIG_VALS}}]" \
    >/dev/null || return 1
  BYPASSED=0
}

# ─────────────────────────────────────────────────────────────
# 清理顺序很关键：先摘 finalizer（此时必须还是放行状态），再删命名空间，
# 最后恢复选择器。反过来做会卡死，阶段 5 就是这个现象的现场。
# ─────────────────────────────────────────────────────────────
cleanup() {
  [ "$CLEANED" = "1" ] && return
  CLEANED=1

  if [ "$BYPASSED" = "1" ]; then
    kubectl -n "$NS" patch app "$APP" --type=merge \
      -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
  fi
  kubectl delete ns "$NS" --ignore-not-found --timeout=60s >/dev/null 2>&1

  if kubectl get ns "$NS" >/dev/null 2>&1; then
    say "${Y}命名空间卡住了（finalizer 摘不掉），走放行通道处理${N}"
    sel_include >/dev/null 2>&1
    kubectl -n "$NS" patch app "$APP" --type=merge \
      -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
    kubectl delete ns "$NS" --ignore-not-found --timeout=90s >/dev/null 2>&1
  fi

  sel_restore >/dev/null 2>&1

  local now left
  now=$(sel_vals)
  left=$(kubectl get ns "$NS" --no-headers 2>/dev/null | wc -l)
  if [ "$(norm "$now")" = "$(norm "$ORIG_VALS")" ]; then
    say "${G}✓${N} webhook 选择器已恢复: ${now}"
  else
    say "${R}✗${N} 选择器没恢复，当前: ${now}"
    say "  手动恢复: kubectl apply -f ${BACKUP}"
  fi
  [ "$left" -eq 0 ] && say "${G}✓${N} ${NS} 已删除（残留 0）" \
    || say "${R}✗${N} ${NS} 仍在，手动: kubectl delete ns ${NS}"

  say "${D}原有资源复核（只读）:${N}"
  kubectl get app -A --no-headers 2>/dev/null | sed 's/^/  /'
}

trap '[ "$KEEP" = "1" ] || cleanup' EXIT

bad_yaml() {
  cat <<EOF
apiVersion: kubestasis.io/v1alpha1
kind: App
metadata:
  name: $1
  namespace: ${NS}
spec:
  image: ${BAD_IMAGE}
  port: 8080
  scaling:
    minReplicas: ${MN}
    maxReplicas: ${MX}
EOF
}

# ─────────────────────────────────────────────────────────────
step "阶段 0 / 前置检查"
# ─────────────────────────────────────────────────────────────
kubectl version --request-timeout=5s >/dev/null 2>&1 || die "kubectl 连不上集群"
kubectl get validatingwebhookconfiguration "$VWC" >/dev/null 2>&1 || die "${VWC} 不存在"
kubectl -n kubestasis-hv get deploy ks-kubestasis >/dev/null 2>&1 || die "manager 不在"
[ "$(kubectl -n kubestasis-hv get deploy ks-kubestasis -o jsonpath='{.status.readyReplicas}')" = "1" ] \
  || die "manager 没就绪，webhook 可能不可用"

ORIG_VALS=$(sel_vals)
[ -n "$ORIG_VALS" ] || die "读不到 namespaceSelector，脚本假设不成立"
kubectl get validatingwebhookconfiguration "$VWC" -o yaml > "$BACKUP" 2>/dev/null || die "备份失败"

say "${G}✓${N} 集群 / manager / webhook 就绪"
say "${D}原选择器: ${ORIG_VALS}${N}"
say "${D}已备份到 ${BACKUP}；failurePolicy=$(kubectl get validatingwebhookconfiguration "$VWC" -o jsonpath='{.webhooks[0].failurePolicy}')${N}"

kubectl get ns "$NS" >/dev/null 2>&1 && { say "${Y}发现残留 ${NS}，先清${N}"; kubectl delete ns "$NS" --timeout=60s >/dev/null 2>&1; }

# ─────────────────────────────────────────────────────────────
step "阶段 1 / 预测"
# ─────────────────────────────────────────────────────────────
say "  清单：image: ${BAD_IMAGE}（禁止）+ minReplicas ${MN} > maxReplicas ${MX}（跨字段非法）"
say ""
say "  ${B}控制组 1（校验生效）${N}     → 拒绝，报错里同时有 :latest、min>max、replicas 越界"
say "  ${B}绕过组（NS 被排除）${N}      → 创建成功，spec 原样落库，控制器照样建 Deployment"
say "  ${B}控制组 2（选择器恢复）${N}   → 同一份清单再被拒"
say "  ${B}收尾（恢复后摘 finalizer）${N} → 被拒，命名空间卡在 Terminating"
say ""

# ─────────────────────────────────────────────────────────────
step "阶段 2 / 控制组 1：正常情况，非法配置进不来"
# ─────────────────────────────────────────────────────────────
kubectl create ns "$NS" >/dev/null || die "建命名空间失败"

out=$(bad_yaml "$APP-a" | kubectl apply -f - 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  say "  ${G}✓ 被拒绝${N}，原文:"
  printf '%s\n' "$out" | sed 's/^/    /' | head -8
else
  say "  ${R}✗ 竟然被接受了${N}，webhook 本来就没生效，后面两步失去对照意义"
fi

# ─────────────────────────────────────────────────────────────
step "阶段 3 / 只排除 ${NS}，再看同一份清单"
# ─────────────────────────────────────────────────────────────
sel_include || die "patch 选择器失败"
now=$(sel_vals)
[ "$(norm "$now")" = "$(norm "${ORIG_VALS%]},\"${NS}\"]")" ] || die "选择器没改成预期值: ${now}"
say "${G}✓${N} 选择器现在排除 ${NS}: ${now}"
say "${D}其余命名空间照常校验，保护范围只缩小了一个${N}"

out=$(bad_yaml "$APP" | kubectl apply -f - 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  say "  ${G}✓ 被接受${N}：${out}"
else
  printf '%s\n' "$out" | sed 's/^/    /' | head -8
  die "选择器改了但没绕过，检查是否还有第二条规则"
fi

say ""
say "  ${B}落库后的 spec（没有任何纠正）${N}"
say "    image       = $(kubectl -n "$NS" get app "$APP" -o jsonpath='{.spec.image}' 2>/dev/null)"
say "    minReplicas = $(kubectl -n "$NS" get app "$APP" -o jsonpath='{.spec.scaling.minReplicas}' 2>/dev/null)"
say "    maxReplicas = $(kubectl -n "$NS" get app "$APP" -o jsonpath='{.spec.scaling.maxReplicas}' 2>/dev/null)"
say "    replicas    = $(kubectl -n "$NS" get app "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)${D}（mutating 仍在工作，把省略的 replicas 填成 min）${N}"

say "\n  ${D}等控制器处理 15 秒，看它会不会纠正${N}"
sleep 15
say "  Deployment: $(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.metadata.name} replicas={.spec.replicas} image={.spec.template.spec.containers[0].image}' 2>/dev/null || echo 未创建)"
say "  Pod: $(kubectl -n "$NS" get pod -l "app=$APP" -o jsonpath='{range .items[*]}{.status.phase}/{.status.containerStatuses[0].state.waiting.reason}{" "}{end}' 2>/dev/null)"
say "  ${D}控制器没拒绝也没纠错，它照着执行${N}"

# ─────────────────────────────────────────────────────────────
step "阶段 4 / 控制组 2：恢复选择器，同一份清单再试"
# ─────────────────────────────────────────────────────────────
sel_restore || die "恢复选择器失败"
now=$(sel_vals)
[ "$(norm "$now")" = "$(norm "$ORIG_VALS")" ] && say "${G}✓${N} 选择器已恢复: ${now}" \
  || die "恢复后读到的值不对: ${now}"

out=$(bad_yaml "$APP-b" | kubectl apply -f - 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  say "  ${G}✓ 再次被拒绝${N}，原文:"
  printf '%s\n' "$out" | sed 's/^/    /' | head -8
else
  say "  ${R}✗ 恢复后仍能创建${N}，选择器恢复没生效"
fi

# ─────────────────────────────────────────────────────────────
step "阶段 5 / 收尾时撞上的死锁：非法对象摘不掉 finalizer"
# ─────────────────────────────────────────────────────────────
say "  ${D}App 带 finalizer，删除要先摘它，而摘 finalizer 是一次 UPDATE——${N}"
say "  ${D}这次 UPDATE 同样走校验，非法对象必然被拒。${N}\n"

out=$(kubectl -n "$NS" patch app "$APP" --type=merge -p '{"metadata":{"finalizers":null}}' 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  say "  ${G}✓ 复现${N}：摘 finalizer 被拒"
  printf '%s\n' "$out" | sed 's/^/    /' | head -4
else
  say "  ${Y}? 这次居然成功了${N}，说明校验对 UPDATE 没生效，与预期不符"
fi

kubectl delete ns "$NS" --timeout=25s >/dev/null 2>&1
phase=$(kubectl get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$phase" = "Terminating" ] && say "  ${G}✓ 命名空间卡在 Terminating${N}（finalizer 还在）" \
  || say "  ${D}命名空间状态: ${phase:-已删除}${N}"

say "\n  ${B}解法${N}：先把 ${NS} 放回排除名单（此时恢复放行），摘掉 finalizer，再恢复选择器"
sel_include || die "再次放行失败"
kubectl -n "$NS" patch app "$APP" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 \
  && say "  ${G}✓${N} finalizer 已摘除（放行状态下 UPDATE 通过）" \
  || say "  ${Y}? 摘除失败，看清理阶段的兜底输出${N}"

for _ in $(seq 1 30); do kubectl get ns "$NS" >/dev/null 2>&1 || break; sleep 2; done
kubectl get ns "$NS" >/dev/null 2>&1 \
  && say "  ${Y}? 命名空间仍在（可能还在回收）${N}" \
  || say "  ${G}✓${N} 命名空间已回收"

sel_restore || die "恢复选择器失败"

# ─────────────────────────────────────────────────────────────
step "阶段 6 / 清理"
# ─────────────────────────────────────────────────────────────
if [ "$KEEP" = "1" ]; then
  say "${Y}--keep 已指定，但场景已被阶段 5 删掉，只能核对参数状态${N}"
fi
cleanup

cat <<'NOTE'

── 这个实验证明了什么 ──────────────────────────────────
1. 控制器不做二次校验。非法配置只要进了 etcd，控制器就照着执行：
   建 Deployment、按 latest 拉镜像、不纠正 min/max。准入是唯一防线。

2. 恢复校验之后，非法对象会卡住删除。摘 finalizer 是一次 UPDATE，
   校验拦 UPDATE，于是对象永远删不掉，命名空间停在 Terminating。
   这是 fail-closed 准入和 finalizer 机制的交互问题，不是本项目的
   独有 bug，但很多人答不出这个连锁反应。

   标准的修法有两种：
   · webhook 里判断 deletionTimestamp 非零就放行（删除不该被 spec 校验拦）
   · rules 里把校验限定在 CREATE，UPDATE 只做增量校验

3. 排除命名空间比「关掉整个 webhook」可控：别处保护不中断，恢复后还能
   用同一份清单做反向对照。

── 两个容易讲错的地方 ──────────────────────────────────
· 不要说「关掉 --enable-webhook 就没有校验了」。服务停了而配置还在、
  failurePolicy=Fail 时，表现是「所有写入被拒」，恰恰相反。
· 不要以为 mutating 也一起失效。它有自己的选择器，本实验只改了
  validating 那一份，所以 replicas 的默认值照旧被注入。

── 代价与恢复 ────────────────────────────────────────
窗口期内只有 lab-exp11 不受校验，约一分钟。选择器在清理阶段无条件恢复
并与备份值逐字比对；备份在 /tmp/exp11-vwc-backup.yaml。
NOTE
