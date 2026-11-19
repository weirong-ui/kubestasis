# vLLM 推理信号实测：开工清单

> **状态：尚未执行。** 本文是清单，不是报告。所有结果栏在真正跑完之前保持空白；
> 不许填"预期值"，不许把计划写成结论。跑完实测值填进来，同时把这一行的状态改掉。
>
> **口径声明（先读这一条）**：单卡只能跑一个 vLLM。`1→3→1` 里多出来的两个副本
> **不承接流量、不提供算力**，只是 Deployment 对象里的装饰对象。真实发生的是：
> 控制器从真实 Prometheus 读到真实 vLLM 指标 → 算出期望副本 →
> `Deployment.spec.replicas` 真的被改写。所以本文能支持的措辞只有
> "三信号在真实 vLLM 指标上触发过决策"，**不能**写成
> "AI 推理弹性已在真集群端到端验证"，也不能写"扩容改善了延迟"。
>
> 与 [d2a-protocol.md](d2a-protocol.md) 正交：那份是同机 A/B 重复实验，验 −12.5%；
> 这份是单臂决策链验证，不做统计推断、不进任何判定线、不复用那边的判废规则。
> 原始 CSV 归 [hpa-vs-kubestasis.md](hpa-vs-kubestasis.md) 同目录，schema 独立。

## 0. 开工前必须解决的三件事

### 0.1 指标名先核对，别假设

`internal/scaler/prometheus.go:48-50` 默认对齐 vLLM 的 `/metrics`：

| 信号 | 默认 PromQL 里的指标名 | 目标值格式（CRD） |
|---|---|---|
| `QueueDepth` | `vllm:num_requests_waiting` | `"2"`（每 Pod 排队数，>0） |
| `TTFT` | `vllm:time_to_first_token_seconds_bucket` | `"1s"`（支持 `200ms` / `0.2` / `1s`） |
| `KVCacheUsage` | `vllm:gpu_cache_usage_perc` | `"0.85"`（必须落在 (0,1)） |

不同 vLLM 版本（尤其 V1 引擎）会改名或移除指标。开工第一步是
`curl -s localhost:8000/metrics | grep -E '^vllm:' | head -30`，把真实名字抄进 §7。
名字不一致时**用 recording rule 做别名**（§3.3 附），不要改 Go 源码默认值去迁就一套私有名字——
源码注释第 35 行写明了默认值不该为某个环境让路。

### 0.2 label 对齐：不满足会静默失败，比报错难查

三条默认查询都带 `{app="{app}",namespace="{namespace}"}`，占位符由 App CR 的
`metadata.name` / `metadata.namespace` 填充（`prometheus.go:227`）。demoapp 能查到，
是因为控制器给它注入了 `APP_NAME` / `POD_NAMESPACE`，程序自己把这两个 label 打在指标上
（`cmd/demoapp/main.go:59-63`）。**vLLM 不会带这两个 label。**

后果链条：查询返回空向量 → `queryScalar` 返回 `ok=false` → 每个信号都"弃权" →
副本数永远不动，日志里也没有错误。这类静默失败会把半天时间耗在"是不是 vLLM 没暴露指标"上。

CRD 的 `MetricTarget` 只有 `Type` / `Target`，**没有 PromQL 覆盖字段**；
`WithQuery` 只存在于 Go 侧；chart 只暴露 `prometheus.url` / `prometheus.window`。
所以唯一出路是从抓取配置补 label（§3.3），`app` / `namespace` 的值必须与 App CR 逐字相同。

### 0.3 5m 窗口会让短压测拿不到 TTFT

`histogram_quantile(rate(...[5m]))` 在样本不足时返回 NaN，而 `queryScalar` 把 NaN
当作"无数据"返回 `ok=false`（`prometheus.go:285-288`）——同样是弃权。
用 `PROMETHEUS_WINDOW=1m`（或 `--prometheus-window`），并让打流持续 ≥3 分钟，
别用 30 秒的脉冲流量。`QueueDepth` 是 `sum()` 不带 rate，不受这条影响。

## 1. 环境与分工

| 组件 | 跑在哪 | 说明 |
|---|---|---|
| vLLM（Qwen2.5-1.5B，`:8000`） | GPU 机 | 单卡 24G，`--max-model-len 2048`，`--gpu-memory-utilization` 留余量 |
| Prometheus（`:9090`） | GPU 机，docker | 抓 vLLM，补 `app` / `namespace` label |
| loadgen | GPU 机 | 本机打 `localhost:8000`，不用把 8000 也转出来 |
| KubeStasis manager | **本地宿主机进程**（`go run ./cmd`） | 直连当前 kubeconfig，避开"容器内访问宿主机"的网络坑 |
| Kubernetes | 本地 docker-desktop v1.36.1 | `kubectl` 1.36.1 / Docker 29.9.2 已就绪；本机没有 `make` / `kind` / `helm`，用等价命令 |
| SSH 隧道 | 本地 | `-L 9090:127.0.0.1:9090`，manager 连 `127.0.0.1:9090` |

**备选 B**：如果 SSH 隧道在沙箱里不通，把整套搬到 GPU 机上（k3s + in-cluster manager
+ 同机 Prometheus），代价是要在那台机器上装 k3s、且跨容器访问宿主机端口要显式配
`host.docker.internal`。主线不成立时再切，别一上来两头都搭。

需要账号本人的只有两件：**租机 / 付款** 和 **用完释放实例**。其余步骤都可脚本化。

## 2. 前置自检（开工第一条命令）

```bash
# A. 隧道是否通（不通就切备选 B，或改成逐条命令手工执行）
ssh -o BatchMode=yes -p <PORT> <USER>@<HOST> 'echo ok'

# B. 真实指标名（抄进 §7）
ssh -p <PORT> <USER>@<HOST> 'curl -s localhost:8000/metrics | grep -E "^vllm:" | head -30'

# C. 本地集群
kubectl get nodes
```

A 不通就先停，不要往下跑；B 里三条指标缺任何一条，按 §6 中止。

## 3. 步骤

### 3.1 起 vLLM（GPU 机）

```bash
vllm serve Qwen/Qwen2.5-1.5B --port 8000 --max-model-len 2048 \
  --gpu-memory-utilization 0.85 --host 0.0.0.0
curl -s localhost:8000/v1/models            # 确认服务起来
```

`--gpu-memory-utilization` 默认 0.9，24G 卡上容易挤爆；0.85 是保守起点，按实际显存调。

### 3.2 写 `prom.yml`（GPU 机）

```yaml
global:
  scrape_interval: 5s
  evaluation_interval: 5s

rule_files:
  - /etc/prometheus/alias.yml      # 仅当 §0.1 的真实指标名与默认值不一致时需要

scrape_configs:
  - job_name: vllm
    static_configs:
      - targets: ['host.docker.internal:8000']
        labels:
          app: vllm                 # 必须逐字等于 App CR 的 metadata.name
          namespace: vllm           # 必须逐字等于 App CR 所在的 namespace
```

Linux 上 docker 容器访问宿主机，起容器时要带
`--add-host=host.docker.internal:host-gateway`。

### 3.3 起 Prometheus（GPU 机）

```bash
docker run -d --name prom -p 9090:9090 \
  --add-host=host.docker.internal:host-gateway \
  -v "$(pwd)/prom.yml:/etc/prometheus/prometheus.yml" \
  -v "$(pwd)/alias.yml:/etc/prometheus/alias.yml" \
  prom/prometheus --web.enable-lifecycle
```

指标名不一致时的 `alias.yml`（把真实指标映射成默认名，不改 Go）：

```yaml
groups:
  - name: vllm-alias
    rules:
      - record: vllm:gpu_cache_usage_perc
        expr: vllm:kv_cache_usage_perc      # 换成 §2.B 查到的真实名字
```

**验收**：`curl -s 'http://localhost:9090/api/v1/query?query=vllm:num_requests_waiting{app="vllm",namespace="vllm"}'`
必须返回非空 `result`。这一步不过，后面全部白跑。

### 3.4 隧道（本地，保持后台）

```bash
ssh -N -L 9090:127.0.0.1:9090 -p <PORT> <USER>@<HOST>
curl -s 'http://127.0.0.1:9090/api/v1/query?query=up' | head -c 200
```

### 3.5 起 controller（本地）

```bash
kubectl apply -k config/crd
kubectl create namespace vllm --dry-run=client -o yaml | kubectl apply -f -
PROMETHEUS_URL=http://127.0.0.1:9090 PROMETHEUS_WINDOW=1m \
  go run ./cmd --enable-webhook=false
```

不启 webhook：这次不测准入，省掉自签证书那套。`go run` 跑在宿主机，
`127.0.0.1:9090` 就是隧道，没有容器网络问题。

### 3.6 建 App（本地，另开终端）

`image` 用轻量镜像即可——它只是被改 `replicas` 的对象，不承接推理流量（见口径声明）。

```yaml
apiVersion: kubestasis.io/v1alpha1
kind: App
metadata:
  name: vllm
  namespace: vllm
spec:
  image: nginx:1.27-alpine
  replicas: 1
  port: 80
  readiness:
    type: HTTPGet
    path: /
  scaling:
    minReplicas: 1
    maxReplicas: 3
    cooldownSeconds: 15
    scaleDownStabilizationSeconds: 10
    metrics:
      - type: QueueDepth
        target: "2"
      - type: TTFT
        target: "1s"
      - type: KVCacheUsage
        target: "0.85"
  health:
    strategy: graduated
    canary:
      enabled: false
```

`cooldownSeconds` / `scaleDownStabilizationSeconds` 调小是为了让 `1→3→1` 在一小时内看完；
正式压测的默认值是 120 / 60，别把这个配置写回主报告的参数表。

### 3.7 打流（GPU 机）

持续 ≥3 分钟，让 `num_requests_waiting` 稳定超过 2；并发从 4 起步逐步加到 32，
每档停 30 秒。用 `/v1/completions`，`max_tokens` 给到 128 以上，否则 TTFT 和
KV cache 都难越过阈值。记录每档的并发数与起止时刻，填进 §7。

### 3.8 观测与收数（本地）

```bash
kubectl get deploy -n vllm -w
kubectl get app vllm -n vllm -o yaml | grep -A6 status
kubectl logs -f deploy/kubestasis-controller-manager -n kubestasis-system 2>/dev/null || true
```

manager 是 `go run` 时日志就在它的终端里，直接从那里拷 Reason 行。

### 3.9 收尾

删 App、停 manager、关隧道，**然后到 AutoDL 控制台释放实例**。
关机不等于停计费，这一步漏了会一直扣钱。

## 4. 验收清单（跑完才打勾，现在全部留空）

- [ ] 三条指标在 Prometheus `/api/v1/query` 返回非空（`app` / `namespace` label 对齐）
- [ ] 决策记录里出现对应 Reason，且与当时指标值能对上
- [ ] `Deployment.spec.replicas` 观察到 `1→3→1`
- [ ] `docs/benchmark/vllm-inference.csv` 落盘，列同 §7
- [ ] 截图存 `docs/assets/`，本文状态行改掉、结果栏填实测值
- [ ] `docs/STATUS.md` 第 50 行的 ⚠️ 改成实测结论，**措辞受口径声明约束**
- [ ] 本文首屏的口径声明保留，不因为"结果好看"而删

## 5. 中止与判废（防止硬跑凑数）

| 情况 | 处理 |
|---|---|
| §3.3 的查询返回空 | 停。回去查 label / 指标名，不打流 |
| 三条指标缺任一 | 停。记录原因，不算一次"失败的实测" |
| 副本数没变化 | 如实记为未触发，写清哪个信号弃权；**不改目标值重跑凑一次成功** |
| 只跑了部分信号 | 只写跑通的那几条，其余留空并注明 |
| 只跑一次 | 不做统计推断、不写"显著"、不进 D2 判定线 |

## 6. 成本与止损

租机 2–3 小时 + 写文档 1 小时，约 20–50 元。公网别直接暴露 9090，用 §3.4 的隧道。
**单卡 24G 上 KV cache 占用率未必能推到 0.85**——1.5B 模型配 2048 上下文，KV 池很大。
如果它始终不越阈值，就如实写"KVCacheUsage 未触发"，不要为了凑齐三信号把目标值改到 0.1。
三条里能坐实两条，也比编一条强。

## 7. 收数表（跑完填 `vllm-inference.csv`）

| 列 | 含义 |
|---|---|
| `ts` | 采样时刻（ISO 8601，带时区） |
| `signal` | `QueueDepth` / `TTFT` / `KVCacheUsage` |
| `metric_name` | §2.B 抄来的真实指标名 |
| `value` | Prometheus 查询到的瞬时值 |
| `desired` | 该信号算出的期望副本（弃权记空） |
| `replicas` | 同时刻 `Deployment.spec.replicas` |
| `reason` | 决策记录里的 Reason |
| `concurrency` | 当时 loadgen 并发档位 |
| `note` | 异常、弃权原因、人工观察 |

允许的结论只有一句：**"三信号中 N 条在真实 vLLM 指标上触发了副本变更决策，副本数从 1 变到 X 再回到 1"**。
任何关于延迟、吞吐、容量改善的说法，都不在这份实验能支持的范围里。
