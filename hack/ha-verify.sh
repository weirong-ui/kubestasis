#!/usr/bin/env bash
# 双副本选主、接管与"不重复执行"的实测脚本。
# 协议（判定线、判废规则、不验证什么）见 docs/ha-verification.md。
#
# 用法：
#   bash hack/ha-verify.sh
#   NS=kubestasis-ha IMG=kubestasis:ha1 CYCLES=2 bash hack/ha-verify.sh
#
# 前提：本机 kubectl 指向一个真集群（kind / Docker Desktop 都行），镜像已构建。
# 脚本会拒绝在"还有别的 KubeStasis manager 在跑"的集群上执行——那些 manager 会
# 抢同一个 App，扩容事件归不到被测的两个副本头上。
set -uo pipefail

NS=${NS:-kubestasis-ha}
RELEASE=${RELEASE:-ha}
APP=${APP:-ha-app}
IMG=${IMG:-kubestasis:ha1}
HELM=${HELM:-helm}
PROM_QPS=${PROM_QPS:-105}
TARGET_QPS=${TARGET_QPS:-100}
TAKEOVER_LIMIT=${TAKEOVER_LIMIT:-45}
CYCLES=${CYCLES:-2}
OUT=${OUT:-docs/lab/ha-$(date +%Y%m%d-%H%M%S)}
PYTHON=${PYTHON:-python}

REPO=${IMG%:*}
TAG=${IMG##*:}

mkdir -p "$OUT" || exit 1
OUT=$(cd "$OUT" && pwd)

say() { printf '==> %s\n' "$*"; }
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

now_ms() { date +%s%3N; }

# ---------- 0. 预检 ----------
say "预检"
[ -n "$("$HELM" version --short 2>/dev/null)" ] || die "没找到 helm（HELM=/path/to/helm 指定）"
kubectl version --request-timeout=10s >/dev/null 2>&1 || die "kubectl 连不上集群"

others=$(kubectl get deploy -A -l control-plane=controller-manager \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.spec.replicas}{"\n"}{end}' 2>/dev/null |
  awk '$2+0 > 0 {print $1}' | grep -v "^$NS/" | grep -v '^$' || true)
if [ -n "$others" ]; then
  echo "集群里还有别的 KubeStasis manager 在跑：" >&2
  echo "$others" | sed 's/^/  /' >&2
  die "先缩到 0（kubectl -n <ns> scale deploy <name> --replicas=0），跑完再恢复"
fi

{
  echo "time=$(date -Iseconds)"
  echo "cluster=$(kubectl config current-context)"
  echo "server=$(kubectl version -o json 2>/dev/null | "$PYTHON" -c 'import json,sys;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null || echo unknown)"
  echo "nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  echo "image=$IMG"
  echo "image_id=$(docker image inspect "$IMG" --format '{{.Id}}' 2>/dev/null || echo unknown)"
  echo "commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "cycles=$CYCLES takeover_limit=${TAKEOVER_LIMIT}s"
} > "$OUT/env.txt"

# ---------- 1. 假 Prometheus ----------
say "部署假 Prometheus（固定 QPS=$PROM_QPS）"
kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# 假 Prometheus 用 nginx 静态返回同一个 JSON：省掉再拉一个镜像，进程也没有状态。
# /api/v1/query 的查询串被 nginx 忽略，任何 PromQL 都得到同一个数。
cat > "$OUT/fakeprom.conf" <<EOF
server {
  listen 9090;
  location / {
    default_type application/json;
    return 200 '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1764000000,"$PROM_QPS"]}]}}';
  }
  location = /healthz { return 200 "ok"; }
}
EOF

kubectl -n "$NS" create configmap fakeprom --from-file=default.conf="$OUT/fakeprom.conf" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<'EOF' | kubectl -n "$NS" apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fakeprom
spec:
  replicas: 1
  selector:
    matchLabels: {app: fakeprom}
  template:
    metadata:
      labels: {app: fakeprom}
    spec:
      containers:
        - name: fakeprom
          image: nginx:1.27-alpine
          ports: [{name: http, containerPort: 9090}]
          readinessProbe:
            httpGet: {path: /healthz, port: http}
            periodSeconds: 2
          volumeMounts:
            - {name: conf, mountPath: /etc/nginx/conf.d}
      volumes:
        - name: conf
          configMap: {name: fakeprom}
---
apiVersion: v1
kind: Service
metadata:
  name: fakeprom
spec:
  selector: {app: fakeprom}
  ports: [{name: http, port: 9090, targetPort: http}]
EOF
kubectl -n "$NS" rollout status deploy/fakeprom --timeout=180s >/dev/null || die "fakeprom 没起来"

# ---------- 2. 装双副本 manager ----------
say "安装 chart：replicaCount=2, leaderElection=true"
"$HELM" upgrade --install "$RELEASE" charts/kubestasis -n "$NS" \
  --set replicaCount=2 \
  --set leaderElection=true \
  --set image.repository="$REPO" \
  --set image.tag="$TAG" \
  --set image.pullPolicy=IfNotPresent \
  --set prometheus.url="http://fakeprom.$NS.svc:9090" \
  --set prometheus.window=1m \
  --set metrics.service.enabled=false >/dev/null || die "helm 安装失败"

kubectl -n "$NS" rollout status "deploy/$RELEASE-kubestasis" --timeout=240s >/dev/null ||
  die "manager 没有两个副本同时 Ready"
kubectl -n "$NS" get deploy,pods,pdb -o wide > "$OUT/workload.txt" 2>&1

# ---------- 3. App ----------
say "清理上一轮残留"
kubectl -n "$NS" delete app "$APP" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1
kubectl -n "$NS" delete events --field-selector "involvedObject.name=$APP" --ignore-not-found >/dev/null 2>&1

say "创建被测 App（目标 QPS=$TARGET_QPS，期望副本恒为 2）"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: kubestasis.io/v1alpha1
kind: App
metadata:
  name: $APP
  namespace: $NS
spec:
  image: kubestasis-demoapp:v1
  replicas: 1
  port: 8080
  readiness:
    type: HTTPGet
    path: /
  scaling:
    minReplicas: 1
    maxReplicas: 6
    cooldownSeconds: 0
    hysteresisPercent: 0
    scaleDownStabilizationSeconds: 0
    metrics:
      - type: QPS
        target: "$TARGET_QPS"
EOF
kubectl -n "$NS" wait --for=condition=Available "app/$APP" --timeout=180s >/dev/null ||
  die "App 没有 Available"

# ---------- 4. 采样 ----------
samples="$OUT/samples.csv"
metrics="$OUT/metrics.csv"
echo "ts_ms,holder_pod,holder_exists,replicas,current_replicas,pods" > "$samples"
echo "ts_ms,pod,decisions_total,scaleup_total" > "$metrics"

sampler_pid=""
metrics_pid=""
stop_samplers() {
  [ -n "$sampler_pid" ] && kill "$sampler_pid" 2>/dev/null
  [ -n "$metrics_pid" ] && kill "$metrics_pid" 2>/dev/null
  wait 2>/dev/null
}
trap 'stop_samplers' EXIT

( while :; do
    ts=$(now_ms)
    holder=$(kubectl -n "$NS" get lease kubestasis.io -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || echo "")
    pod=${holder%%_*}
    exists=no
    if [ -n "$pod" ] && kubectl -n "$NS" get pod "$pod" >/dev/null 2>&1; then exists=yes; fi
    read -r rep cur < <(kubectl -n "$NS" get app "$APP" -o jsonpath='{.spec.replicas} {.status.currentReplicas}' 2>/dev/null || echo "? ?")
    pods=$(kubectl -n "$NS" get pods -l "app.kubernetes.io/instance=$RELEASE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "$ts,$pod,$exists,${rep:-?},${cur:-?},${pods:-?}" >> "$samples"
    sleep 1
  done ) &
sampler_pid=$!

( while :; do
    ts=$(now_ms)
    for p in $(kubectl -n "$NS" get pods -l "app.kubernetes.io/instance=$RELEASE" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
      body=$(kubectl get --raw "/api/v1/namespaces/$NS/pods/$p:8080/proxy/metrics" 2>/dev/null)
      # 只统计被测 App 自己的决策：同一个 manager 还管着集群里别的 App，
      # 不带 app/namespace 标签会把别人的扩容算进来。
      total=$(printf '%s\n' "$body" | awk -v a="$APP" -v n="$NS" '
        /^kubestasis_scaling_decisions_total\{/ && index($0, "app=\"" a "\"") && index($0, "namespace=\"" n "\"") {s += $2}
        END {printf "%d", s+0}')
      up=$(printf '%s\n' "$body" | awk -v a="$APP" -v n="$NS" '
        /^kubestasis_scaling_decisions_total\{/ && index($0, "app=\"" a "\"") && index($0, "namespace=\"" n "\"") && index($0, "action=\"ScaleUp\"") {s += $2}
        END {printf "%d", s+0}')
      echo "$ts,$p,${total:-0},${up:-0}" >> "$metrics"
    done
    sleep 5
  done ) &
metrics_pid=$!

# ---------- 5. 判定用的等待 ----------
# status 落地：observedGeneration 追上 generation。扩容事件刚出现就复位会被
# 控制器随后的 spec 回写覆盖掉（实测踩过，1 被写回 2，一条事件都不产生）。
wait_settled() { # $1=超时秒
  local start
  start=$(now_ms)
  while :; do
    read -r gen obs < <(kubectl -n "$NS" get app "$APP" \
      -o jsonpath='{.metadata.generation} {.status.observedGeneration}' 2>/dev/null || echo "0 0")
    [ -n "${gen:-}" ] && [ "${gen:-0}" = "${obs:-0}" ] && return 0
    [ $(( $(now_ms) - start )) -gt $(( $1 * 1000 )) ] && return 1
    sleep 2
  done
}

# 复位后等控制器把副本数拉回 2。不看事件：EventRecorder 会把内容相同的
# 事件聚合成一条（count 递增），拿事件条数当"扩容发生了几次"会永远只看到 1。
wait_two() { # $1=超时秒
  local start
  start=$(now_ms)
  while :; do
    read -r spec cur < <(kubectl -n "$NS" get app "$APP" \
      -o jsonpath='{.spec.replicas} {.status.currentReplicas}' 2>/dev/null || echo "0 0")
    [ "${spec:-0}" = "2" ] && [ "${cur:-0}" = "2" ] && return 0
    [ $(( $(now_ms) - start )) -gt $(( $1 * 1000 )) ] && return 1
    sleep 2
  done
}

say "等第一次扩容到 2"
wait_two 180 || die "App 没扩到 2：指标源或 App 配置有问题，先别做接管测试"
wait_settled 90 || die "首次扩容后 status 没落地"
echo "initial=ok" >> "$OUT/cycles.txt"

# ---------- 6. 杀 leader，测接管 ----------
for i in $(seq 1 "$CYCLES"); do
  say "第 $i 轮：复位 replicas=1 触发扩容，然后删掉 leader"
  wait_settled 60 || die "第 $i 轮开始前 status 没落地"

  kubectl -n "$NS" patch app "$APP" --type=merge -p '{"spec":{"replicas":1}}' >/dev/null ||
    die "复位 replicas 失败"
  wait_two 120 || die "第 $i 轮复位后没有再次扩容（H4 前置失败）"
  wait_settled 60 || die "第 $i 轮扩容后 status 没落地"

  leader=$(kubectl -n "$NS" get lease kubestasis.io -o jsonpath='{.spec.holderIdentity}')
  leader=${leader%%_*}
  [ -n "$leader" ] || die "lease 里没有 holder"

  t0=$(now_ms)
  echo "cycle=$i leader_before=$leader kill_at=$t0" >> "$OUT/cycles.txt"
  # 被删的 Pod 日志随后就取不到了，先留一份
  { echo "----- $leader (deleted in cycle $i)"; kubectl -n "$NS" logs "$leader" --tail=200; } \
    >> "$OUT/pods-deleted.txt" 2>&1
  kubectl -n "$NS" delete pod "$leader" --wait=false >/dev/null 2>&1 || die "删不掉 leader $leader"

  new=""
  while :; do
    new=$(kubectl -n "$NS" get lease kubestasis.io -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || echo "")
    new=${new%%_*}
    [ -n "$new" ] && [ "$new" != "$leader" ] && break
    [ $(( $(now_ms) - t0 )) -gt 120000 ] && die "120s 内没有接管"
    sleep 1
  done
  t1=$(now_ms)
  takeover=$(( (t1 - t0) / 1000 ))
  echo "cycle=$i leader_after=$new takeover_s=$takeover" >> "$OUT/cycles.txt"
  say "接管完成：$leader -> $new，用时 ${takeover}s"

  wait_two 90 || die "第 $i 轮接管后副本没回到 2（新 leader 没在干活）"
  sleep 3
done

# ---------- 7. H4：接管后还能继续伸缩 ----------
say "H4：新 leader 上再复位一次，看还能不能扩"
wait_settled 60 || true
kubectl -n "$NS" patch app "$APP" --type=merge -p '{"spec":{"replicas":1}}' >/dev/null
h4=ok
wait_two 90 || h4=fail
echo "h4_after_takeover=$h4" >> "$OUT/cycles.txt"
sleep 5

stop_samplers
trap - EXIT

kubectl -n "$NS" get events --field-selector "involvedObject.name=$APP,involvedObject.kind=App" \
  --sort-by=.lastTimestamp -o custom-columns='TIME:.lastTimestamp,REASON:.reason,MSG:.message' \
  > "$OUT/events.txt" 2>&1
for p in $(kubectl -n "$NS" get pods -l "app.kubernetes.io/instance=$RELEASE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  { echo "----- $p"; kubectl -n "$NS" logs "$p" --tail=200; } >> "$OUT/pods.txt" 2>&1
done
kubectl -n "$NS" get leases -o yaml > "$OUT/lease.txt" 2>&1

# ---------- 8. 判定 ----------
"$PYTHON" - "$OUT" "$TAKEOVER_LIMIT" "$CYCLES" <<'PY'
import csv, pathlib, re, sys

out = pathlib.Path(sys.argv[1])
limit = int(sys.argv[2])
cycles = int(sys.argv[3])
fails, notes = [], []

rows = list(csv.DictReader((out / "samples.csv").open(encoding="utf-8")))
if not rows:
    print("FAIL: samples.csv 是空的")
    sys.exit(1)

holders = []
for r in rows:
    if r["holder_pod"] and (not holders or holders[-1] != r["holder_pod"]):
        holders.append(r["holder_pod"])

# lease 过期前仍指着一个刚被删的 Pod，这是接管的正常前奏，不是故障。
# 它必须被 H2 的接管时延兜住：孤儿区间比接管时延长，说明 lease 没被放开。
spans, cur = [], None
for r in rows:
    if r["holder_exists"] == "no" and r["holder_pod"]:
        cur = cur or int(r["ts_ms"])
    elif cur is not None:
        spans.append(int(r["ts_ms"]) - cur)
        cur = None
if cur is not None:
    spans.append(int(rows[-1]["ts_ms"]) - cur)
if len(spans) != cycles:
    fails.append(f"H1: 孤儿 lease 区间 {len(spans)} 段，期望 {cycles} 段（每次接管一段）")
for s in spans:
    if s > limit * 1000:
        fails.append(f"H1: 有一段 lease 指向已删 Pod 达 {round(s / 1000)}s，超过接管时延 {limit}s")

reps = [int(r["replicas"]) for r in rows if r["replicas"].isdigit()]
max_rep = max(reps) if reps else -1
if max_rep > 2:
    fails.append(f"H3: replicas 冲到 {max_rep}，期望恒为 2（疑似重复扩容）")

cyc = (out / "cycles.txt").read_text(encoding="utf-8")
takeovers = [int(m) for m in re.findall(r"takeover_s=(\d+)", cyc)]
if len(takeovers) != cycles:
    fails.append(f"H2: 完成 {len(takeovers)} 轮接管，计划 {cycles} 轮")
for t in takeovers:
    if t > limit:
        fails.append(f"H2: 接管用了 {t}s，超过判定线 {limit}s")

# 决策计数按 Pod 取峰值再求和：被杀掉的 leader 计数会随 Pod 消失，但它的
# 峰值已经落进 CSV，所以总和仍是全程发生在几个副本上的决策总数。
peak = {}
seen = {}
for r in csv.DictReader((out / "metrics.csv").open(encoding="utf-8")):
    p = r["pod"]
    peak[p] = max(peak.get(p, 0), int(r["scaleup_total"] or 0))
    seen.setdefault(r["ts_ms"], {})[p] = int(r["decisions_total"] or 0)
scaleup_total = sum(peak.values())
expected = cycles + 2  # 首次 + 每轮复位 + H4
if scaleup_total != expected:
    fails.append(f"H3: ScaleUp 决策 {scaleup_total} 次，期望 {expected} 次（多出来的是重复执行）")

# 同一采样区间内只允许一个 Pod 的决策计数在涨
double = 0
prev = None
for ts in sorted(seen, key=int):
    cur = seen[ts]
    if prev:
        grew = [p for p in cur if p in prev and cur[p] > prev[p]]
        if len(grew) > 1:
            double += 1
    prev = cur
if double:
    fails.append(f"H3: {double} 个采样区间里两个 Pod 的决策计数同时增长（疑似双 leader）")

if "h4_after_takeover=fail" in cyc:
    fails.append("H4: 接管后 90s 内没有再次扩容")

if len(holders) != cycles + 1:
    fails.append(f"H1: 观察到 {len(holders)} 任 leader，期望 {cycles + 1} 任")
if len(holders) != len(set(holders)):
    fails.append(f"H1: leader 序列里有重复：{holders}")

notes.append(f"leader 序列: {' -> '.join(holders)}")
notes.append(f"孤儿 lease 区间: {[round(s / 1000, 1) for s in spans]} s")
notes.append(f"接管时延: {takeovers} s（判定线 {limit}s）")
notes.append(f"ScaleUp 决策: {scaleup_total} 次 / 期望 {expected} 次")
notes.append(f"replicas 峰值: {max_rep}")
notes.append(f"两 Pod 同时增长的采样区间: {double}")
notes.append(f"采样点: {len(rows)}，覆盖 {round((int(rows[-1]['ts_ms']) - int(rows[0]['ts_ms'])) / 1000)}s")

summary = ["PASS" if not fails else "FAIL"] + fails + notes
(out / "summary.txt").write_text("\n".join(summary) + "\n", encoding="utf-8")
print("\n".join(summary))
sys.exit(0 if not fails else 1)
PY

rc=$?
say "证据在 $OUT"
[ "$rc" -eq 0 ] || die "判定未通过，看 summary.txt"
say "四条假设全部通过"
