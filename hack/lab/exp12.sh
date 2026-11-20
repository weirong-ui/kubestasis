#!/usr/bin/env bash
# 实验 12：CRD 默认值会不会抢先于 mutating webhook
#
# 边界：不碰仓库代码、不重建镜像、不重启 manager。
#       改的是集群里 CRD 的一个字段（spec.properties.replicas.default），
#       清理时第一件事就是把它删掉。
#
# 用法：
#   bash exp12.sh           完整跑 + 自动清理（含撤销 CRD 改动）
#   bash exp12.sh --keep    保留 lab-exp12 看现场（CRD 仍会撤销，别让它留着）
#
# 为什么不用原设计的 `make manifests`：
#   本机没有 make，也没有 controller-gen。而实验要验证的是「默认值在解码阶段
#   落进对象」这个时序，不是「kubebuilder 注解能不能生成 schema」。
#   直接给 CRD 加 default，落在同一个阶段，效果等价，且不用改一行 Go。
#
set -uo pipefail

NS=lab-exp12

# 守卫：命名空间白名单 + context 检查（见 hack/lab/lib.sh）
. "$(dirname "$0")/lib.sh"
lab_guard "$NS"
APP_A=exp12-base
APP_B=exp12-default
APP_C=exp12-explicit
IMAGE=kubestasis-demoapp:v1
MIN=3
MAX=10
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

CRD=apps.kubestasis.io
JSONPATH_REPLICAS='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.replicas}'

B="\033[1m"; D="\033[2m"; R="\033[31m"; G="\033[32m"; Y="\033[33m"; N="\033[0m"
say()  { printf "%b\n" "$*"; }
step() { printf "\n%b%s%b\n" "$B$Y" "$*" "$N"; }
die()  { say "${R}✗ $*${N}"; exit 1; }

PATCHED=0
CLEANED=0

crd_default() {
  kubectl get crd "$CRD" -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.replicas.default}' 2>/dev/null
}

# ─────────────────────────────────────────────────────────────
# 清理：先撤 CRD，再删命名空间。CRD 是集群级的，不能留着。
# ─────────────────────────────────────────────────────────────
cleanup() {
  [ "$CLEANED" = "1" ] && return
  CLEANED=1

  if [ "$PATCHED" = "1" ] || [ -n "$(crd_default)" ]; then
    kubectl patch crd "$CRD" --type=json \
      -p '[{"op":"remove","path":"/spec/versions/0/schema/openAPIV3Schema/properties/spec/properties/replicas/default"}]' \
      >/dev/null 2>&1
  fi

  kubectl delete ns "$NS" --ignore-not-found --timeout=90s >/dev/null 2>&1

  local d left
  d=$(crd_default)
  left=$(kubectl get ns "$NS" --no-headers 2>/dev/null | wc -l)
  if [ -z "$d" ]; then
    say "${G}✓${N} CRD 已恢复（replicas 无 default）"
  else
    say "${R}✗${N} CRD 还留着 default=${d}，手动撤销:"
    say "  kubectl patch crd ${CRD} --type=json -p '[{\"op\":\"remove\",\"path\":\"/spec/versions/0/schema/openAPIV3Schema/properties/spec/properties/replicas/default\"}]'"
  fi
  [ "$left" -eq 0 ] && say "${G}✓${N} ${NS} 已删除（残留 0）" \
    || say "${R}✗${N} ${NS} 还在，手动执行: kubectl delete ns ${NS}"

  say "${D}原有资源复核（只读）:${N}"
  kubectl get app -A --no-headers 2>/dev/null | sed 's/^/  /'
}

trap '[ "$KEEP" = "1" ] || cleanup' EXIT

app_yaml() {  # $1=名字  $2=可选 "replicas: N"
  cat <<EOF
apiVersion: kubestasis.io/v1alpha1
kind: App
metadata:
  name: $1
  namespace: ${NS}
spec:
  image: ${IMAGE}
  port: 8080
${2:-}  scaling:
    minReplicas: ${MIN}
    maxReplicas: ${MAX}
EOF
}

# ─────────────────────────────────────────────────────────────
step "阶段 0 / 前置检查"
# ─────────────────────────────────────────────────────────────
kubectl version --request-timeout=5s >/dev/null 2>&1 || die "kubectl 连不上集群"
kubectl get crd "$CRD" >/dev/null 2>&1 || die "CRD ${CRD} 不存在"
kubectl -n kubestasis-hv get deploy ks-kubestasis >/dev/null 2>&1 || die "manager 不在，webhook 起不来"

nver=$(kubectl get crd "$CRD" -o jsonpath='{range .spec.versions[*]}{.name}{" "}{end}' | wc -w)
[ "$nver" = "1" ] || die "CRD 有 ${nver} 个版本，脚本的 json 路径假设只有 1 个，先改脚本"

cur=$(crd_default)
[ -z "$cur" ] || die "CRD 里已经有 replicas.default=${cur}（上次没清干净？）先撤销再跑"

kubectl get validatingwebhookconfiguration ks-kubestasis-validating >/dev/null 2>&1 \
  || say "${Y}? 没找到 validating webhook 配置，本实验需要它来观察校验行为${N}"

say "${G}✓${N} 集群 / CRD（单版本）/ manager 就绪"
say "${D}CRD 当前 replicas schema: ${N}$(kubectl get crd "$CRD" -o jsonpath="$JSONPATH_REPLICAS" | head -c 90)..."
say "${D}webhook 现状: $(kubectl get validatingwebhookconfiguration ks-kubestasis-validating -o jsonpath='{.webhooks[0].failurePolicy}' 2>/dev/null) policy${N}"

kubectl get ns "$NS" >/dev/null 2>&1 && { say "${Y}发现残留 ${NS}，先清${N}"; kubectl delete ns "$NS" --timeout=60s >/dev/null 2>&1; }

# ─────────────────────────────────────────────────────────────
step "阶段 1 / 预测（跑之前先定死）"
# ─────────────────────────────────────────────────────────────
say "  ${B}A 基线（CRD 无默认值）${N}"
say "    只写 scaling.minReplicas=${MIN}、不写 replicas → mutating webhook 见到 nil，"
say "    自己填成 ${MIN}。期望：spec.replicas=${MIN}，Deployment ${MIN}/${MIN}"
say ""
say "  ${B}B 加默认值后，同一份清单${N}"
say "    期望不是「创建成功但 replicas=1」。验证器第 4 条要求 replicas ∈ [min,max]，"
say "    1 < ${MIN} 会被直接拒：${D}spec.replicas(1) 必须落在 [${MIN}, ${MAX}] 区间内${N}"
say "    这个报错本身就是证据——它说明有个东西在 webhook 之前把 1 填了进去。"
say ""
say "  ${B}C 显式写 replicas=${MIN} 的对照${N}"
say "    期望照常创建成功。用来排除「webhook 整个不工作了」这个竞争解释。"
say ""

# ─────────────────────────────────────────────────────────────
step "阶段 2 / A 基线：默认值由 webhook 注入"
# ─────────────────────────────────────────────────────────────
kubectl create ns "$NS" >/dev/null || die "建命名空间失败"
app_yaml "$APP_A" | kubectl apply -f - >/dev/null || die "A 创建失败（webhook 是否正常？）"

say "  spec.replicas      = $(kubectl -n "$NS" get app "$APP_A" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
say "  scaling.minReplicas= $(kubectl -n "$NS" get app "$APP_A" -o jsonpath='{.spec.scaling.minReplicas}' 2>/dev/null)"
kubectl -n "$NS" rollout status "deploy/$APP_A" --timeout=120s >/dev/null 2>&1 \
  || say "  ${Y}Deployment 没 rollout 完，不影响本实验的结论${N}"
say "  Deployment 副本    = $(kubectl -n "$NS" get deploy "$APP_A" -o jsonpath='{.spec.replicas}' 2>/dev/null)（就绪 $(kubectl -n "$NS" get deploy "$APP_A" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)）"

# ─────────────────────────────────────────────────────────────
step "阶段 3 / 给 CRD 加 default=1"
# ─────────────────────────────────────────────────────────────
kubectl patch crd "$CRD" --type=json \
  -p '[{"op":"add","path":"/spec/versions/0/schema/openAPIV3Schema/properties/spec/properties/replicas/default","value":1}]' \
  >/dev/null || die "CRD patch 失败"
PATCHED=1

now=$(crd_default)
[ "$now" = "1" ] || die "patch 后读到的 default 是「${now}」，不是 1"
say "${G}✓${N} CRD 现在有 replicas.default=1"
say "${D}这一步等价于在 app_types.go 上加 +kubebuilder:default=1 再 make manifests，"
say "只是跳过了 controller-gen。默认值都落在解码阶段。${N}"

# ─────────────────────────────────────────────────────────────
step "阶段 4 / B 同一份清单再 apply 一次"
# ─────────────────────────────────────────────────────────────
out=""; rc=0; created=0
for i in 1 2 3; do
  out=$(app_yaml "$APP_B" | kubectl apply -f - 2>&1); rc=$?
  [ "$rc" -ne 0 ] && break
  created=1
  say "  ${Y}第 ${i} 次被接受了${N}（默认值可能还没生效），2 秒后重试"
  kubectl -n "$NS" delete app "$APP_B" --ignore-not-found >/dev/null 2>&1
  sleep 2
done

if [ "$rc" -ne 0 ]; then
  say "  ${G}✓ 被拒绝${N}，原文:"
  printf '%s\n' "$out" | sed 's/^/    /' | head -12
else
  rb=$(kubectl -n "$NS" get app "$APP_B" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  say "  ${Y}? 三次都被接受，spec.replicas=${rb:-?}${N}"
  say "  ${D}若等于 1，说明默认值生效但校验没拦住 → 与验证器第 4 条不符，值得单独查；"
  say "  若等于 3，说明默认值没生效 → “解码早于 webhook”这个前提在你的版本上不成立。${N}"
fi

# ─────────────────────────────────────────────────────────────
step "阶段 5 / C 对照：显式 replicas 仍然可用"
# ─────────────────────────────────────────────────────────────
if app_yaml "$APP_C" $'  replicas: '"${MIN}"$'\n' | kubectl apply -f - >/dev/null 2>&1; then
  say "  ${G}✓${N} 创建成功，spec.replicas=$(kubectl -n "$NS" get app "$APP_C" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  say "  ${D}说明校验器本身没坏，也没有整体失效。被挡住的只有「省略 replicas」这一种写法。${N}"
else
  say "  ${R}✗${N} 显式 replicas 也被拒了，那 webhook 的状态有问题，先查 manager 日志"
fi

# ─────────────────────────────────────────────────────────────
step "阶段 6 / 撤销 CRD 改动并核对"
# ─────────────────────────────────────────────────────────────
kubectl patch crd "$CRD" --type=json \
  -p '[{"op":"remove","path":"/spec/versions/0/schema/openAPIV3Schema/properties/spec/properties/replicas/default"}]' \
  >/dev/null 2>&1
PATCHED=0
left=$(crd_default)
[ -z "$left" ] && say "${G}✓${N} CRD 已恢复（无 default），集群回到原状" \
  || say "${R}✗${N} CRD 仍有 default=${left}"

# ─────────────────────────────────────────────────────────────
step "阶段 7 / 清理"
# ─────────────────────────────────────────────────────────────
if [ "$KEEP" = "1" ]; then
  say "${Y}--keep 已指定，保留 ${NS}（CRD 已撤销）${N}"
  say "${D}看完执行: kubectl delete ns ${NS}${N}"
else
  cleanup
fi

cat <<'NOTE'

── 这个实验证明了什么 ──────────────────────────────────
1. CRD schema 的默认值在「解码」阶段就落进对象，早于 mutating webhook。
   所以 webhook 里 `if Replicas == nil` 那个跨字段默认永远没有机会执行。

2. 后果比「填 1 而不是 3」更硬：验证器第 4 条要求 replicas ∈ [min,max]，
   1 < minReplicas 直接被拒。也就是说这份清单根本创建不出来，而不是
   创建出来之后被伸缩器纠正。

3. 所以 app_types.go 里那句注释是对的：CRD 默认值和跨字段默认不能共存。
   要么把跨字段逻辑从 webhook 挪到控制器，要么放弃 schema 默认值。

── 两个容易讲错的地方 ──────────────────────────────────
· 不要以为「控制器会把 replicas 改回 min」。对象进不来，谈不上纠正。
· 不要用 `kubectl replace` 验证这件事。UPDATE 走的是另一条路径（存量的
  replicas 已存在），只有 CREATE 才能干净地观察「省略字段」的语义。

── 代价说明 ──────────────────────────────────────────
CRD 是集群级对象，patch 期间任何命名空间里「省略 replicas」的新 App 都会
被填 1。窗口约一分钟，只在自己机器上可接受；生产绝不能这么试。
NOTE
