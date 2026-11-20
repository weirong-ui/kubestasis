#!/usr/bin/env bash
# 实验 9 + 10：Owns() 到底有没有生效
#
#   9a 手改 Deployment 副本数（下层的实际状态）→ 会被 spec 覆盖回来
#   9b 改 App.spec.replicas（上层的期望）    → Deployment 跟随，不被改回
#   10 删掉 Service                            → 自动重建
#
# 为什么不能只看「多久恢复」：
#   app_controller.go:469 有 RequeueAfter 15s 的周期巡检兜底。就算 Owns 完全
#   失效，最多 15 秒也会被拉回。所以判据是耗时量级：
#     < 5s     → watch 事件驱动（Owns 生效）
#     8~16s    → 周期巡检兜底（Owns 没起作用）
#   每次跑 3 轮，还能看方差。
#
# 边界：只操作 lab-exp9 一个临时命名空间，不碰 bench / kubestasis-hv。
#
# 用法：bash exp9_10.sh  [--keep]
#
set -uo pipefail

NS=lab-exp9

# 守卫：命名空间白名单 + context 检查（见 hack/lab/lib.sh）
. "$(dirname "$0")/lib.sh"
lab_guard "$NS"
APP=exp9
IMAGE=kubestasis-demoapp:v1
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
  [ "$left" -eq 0 ] && say "${G}✓${N} ${NS} 已删除（残留 0）" \
                    || say "${R}✗${N} ${NS} 还在，手动: kubectl delete ns ${NS}"
  say "${D}原有资源复核:${N}"
  kubectl -n bench get app --no-headers 2>/dev/null | sed 's/^/  /'
}
trap '[ "$KEEP" = "1" ] || cleanup' EXIT

now_ms() { date +%s%3N; }

# ─────────────────────────────────────────────────────────────
step "阶段 0 / 前置检查"
# ─────────────────────────────────────────────────────────────
kubectl -n kubestasis-hv get deploy ks-kubestasis >/dev/null 2>&1 || die "控制器不在 kubestasis-hv"
img_repo="${IMAGE%:*}"; img_tag="${IMAGE##*:}"
[ "$(docker exec desktop-control-plane crictl images 2>/dev/null \
  | awk -v r="$img_repo" -v t="$img_tag" '$1 ~ r && $2 == t {print "y"; exit}')" = "y" ] \
  || die "节点里没有 $IMAGE"

say "${G}✓${N} 控制器 / 镜像 就绪"
say "${D}判据：控制器在 app_controller.go:469 有 RequeueAfter 15s 兜底，${N}"
say "${D}所以恢复耗时 <5s 才算 Owns 生效，8~16s 是巡检兜底，两者要分清。${N}"

kubectl get ns "$NS" >/dev/null 2>&1 && kubectl delete ns "$NS" --timeout=60s >/dev/null 2>&1
kubectl create ns "$NS" >/dev/null || die "建命名空间失败"

# ─────────────────────────────────────────────────────────────
step "阶段 1 / 布场"
# ─────────────────────────────────────────────────────────────
# 不配 scaling：排除伸缩引擎介入
# 不配 health ：排除自愈引擎介入
# 只剩控制器自己的声明式收敛，变量才干净
kubectl apply -f - >/dev/null <<EOF || die "创建 App 失败（webhook？）"
apiVersion: kubestasis.io/v1alpha1
kind: App
metadata:
  name: ${APP}
  namespace: ${NS}
spec:
  image: ${IMAGE}
  replicas: 3
  port: 8080
EOF

kubectl -n "$NS" wait --for=condition=Ready pod -l "app=$APP" --timeout=120s >/dev/null 2>&1
ready=$(kubectl -n "$NS" get pod -l "app=$APP" --no-headers 2>/dev/null | grep -c Running)
say "${G}✓${N} App 已创建：spec.replicas=3，实际 Running ${ready} 个"
say "${D}Deployment / Service 由控制器自动创建（不需要你 apply）${N}"
kubectl -n "$NS" get deploy,svc --no-headers 2>/dev/null | sed 's/^/  /'

# ─────────────────────────────────────────────────────────────
step "阶段 2 / 实验 9a：手改 Deployment，会不会被改回"
# ─────────────────────────────────────────────────────────────
say "${D}预测：每次都在 5 秒内回到 3。若接近 15 秒，说明是巡检兜底不是 watch。${N}\n"

REVERT_MS=0
revert_probe() {
  local target=$1
  kubectl -n "$NS" scale deploy "$APP" --replicas="$target" >/dev/null 2>&1
  local t0=$(now_ms) got=""
  for _ in $(seq 1 100); do
    got=$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    if [ "$got" = "3" ]; then
      REVERT_MS=$(( $(now_ms) - t0 ))
      printf "  改成 %-2s → 回到 3  耗时 ${B}%5d ms${N}\n" "$target" "$REVERT_MS"
      return
    fi
    sleep 0.2
  done
  REVERT_MS=99999
  printf "  改成 %-2s → 20 秒内没回到 3（停在 %s）\n" "$target" "$got"
}

a1=0; a2=0; a3=0
revert_probe 6; a1=$REVERT_MS
sleep 2
revert_probe 8; a2=$REVERT_MS
sleep 2
revert_probe 4; a3=$REVERT_MS

avg=$(( (a1 + a2 + a3) / 3 ))
say ""
if [ "$avg" -lt 5000 ]; then
  say "  平均 ${avg}ms → ${G}watch 事件驱动，Owns(&Deployment) 生效${N}"
elif [ "$avg" -lt 17000 ]; then
  say "  平均 ${avg}ms → ${Y}落在巡检兜底区间（15s），Owns 可能没起作用${N}"
else
  say "  平均 ${avg}ms → ${R}完全没被改回，比预期严重${N}"
fi

# ─────────────────────────────────────────────────────────────
step "阶段 3 / 实验 9b：改 App.spec.replicas，会不会被改回"
# ─────────────────────────────────────────────────────────────
say "${D}这一组是 9a 的反面：spec 才是唯一真相源，改它应该被尊重。${N}"
say "${D}预测：Deployment 跟随到 5，且 10 秒后仍是 5（不会被\"纠正\"回 3）。${N}\n"

kubectl -n "$NS" patch app "$APP" --type=merge -p '{"spec":{"replicas":5}}' >/dev/null 2>&1 \
  || say "${Y}patch 失败，webhook 拦了？${N}"
t0=$(now_ms)
for _ in $(seq 1 100); do
  got=$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  [ "$got" = "5" ] && { say "  Deployment 跟随到 5，耗时 $(( $(now_ms) - t0 )) ms"; break; }
  sleep 0.2
done
say "  ${D}等 10 秒，确认不会被改回 3...${N}"
sleep 10
final=$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)
say "  10 秒后 Deployment = ${B}${final}${N}"
[ "$final" = "5" ] && say "  ${G}✓ 改 spec 被尊重，改实际状态被覆盖——方向是单向的${N}" \
                   || say "  ${Y}! 被改回了 ${final}，说明有别的逻辑在动 spec${N}"

# ─────────────────────────────────────────────────────────────
step "阶段 4 / 实验 10：删掉 Service，会不会重建"
# ─────────────────────────────────────────────────────────────
say "${D}预测：2~5 秒内重建，Endpoints 随之恢复。接近 15 秒则是巡检兜底。${N}\n"

for round in 1 2; do
  kubectl -n "$NS" delete svc "$APP" --ignore-not-found >/dev/null 2>&1
  t0=$(now_ms); back=""
  for _ in $(seq 1 120); do
    if kubectl -n "$NS" get svc "$APP" >/dev/null 2>&1; then
      back=$(( $(now_ms) - t0 )); break
    fi
    sleep 0.2
  done
  if [ -n "$back" ]; then
    printf "  第 %s 次：Service 重建耗时 ${B}%5d ms${N}" "$round" "$back"
  else
    printf "  第 %s 次：${R}24 秒内没重建${N}" "$round"
  fi
  # Endpoints 恢复要等就绪探针过，单独看
  for _ in $(seq 1 60); do
    ep=$(kubectl -n "$NS" get endpoints "$APP" -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null)
    [ -n "$ep" ] && { printf "，Endpoints 恢复（%s）\n" "$(echo $ep | wc -w)"; break; }
    sleep 0.5
  done
  [ -z "${ep:-}" ] && printf "，Endpoints 未恢复\n"
  sleep 2
done

step "证据 / 当前状态"
kubectl -n "$NS" get deploy,svc,endpoints --no-headers 2>/dev/null | sed 's/^/  /'
say ""
kubectl -n "$NS" get events --sort-by=.lastTimestamp \
  -o custom-columns='T:.lastTimestamp,R:.reason,O:.involvedObject.name,M:.message' --no-headers 2>/dev/null \
  | tail -8 | cut -c1-120 | sed 's/^/  /'

# ─────────────────────────────────────────────────────────────
step "阶段 5 / 清理"
# ─────────────────────────────────────────────────────────────
if [ "$KEEP" = "1" ]; then
  say "${Y}--keep：保留 ${NS}，看完 kubectl delete ns ${NS}${N}"
else
  cleanup
fi

cat <<'NOTE'

── 这两个实验证明了什么 ────────────────────────────────
9a 和 9b 不是同一个动作的两个方向，是两种「真相源」的对比：
· 改 Deployment（实际状态）会被 spec 覆盖回来
· 改 App.spec（期望状态）会被尊重并下发
所以声明式不是"系统不断把现实拉回蓝图"，而是"蓝图唯一，现实无权
反驳"。这一点讲清楚，比背 reconcile 的定义有用。

10 证明的是 Owns(&Service{}) 的实际作用。没有它，控制器只在 App
变化时动手，被删的 Service 要等 15 秒巡检才回来；有了它，秒级重建。

── 一个必须说清的判别 ──────────────────────────────────
控制器有 RequeueAfter 15s 的巡检兜底，所以"恢复了"本身不能证明
Owns 生效。判据是耗时量级和稳定性：watch 驱动是 1~3 秒且每次差不多，
巡检兜底会在 15 秒内随机落点、方差大。

如果被问到"你怎么知道是 watch 不是轮询"，答案就是这个测量，而不是
"我配了 Owns 所以它应该生效"。
NOTE
