# vLLM 推理信号实测记录（2026-11-20）

一次真实的、付费的、单卡 GPU 上的实测。目的只有一个：确认 `QueueDepth` / `TTFT` /
`KVCacheUsage` 这三个信号**在真实 vLLM 指标上能驱动 KubeStasis 的伸缩决策**。
开工清单见 [vllm-inference.md](vllm-inference.md)。

## 结论先说

首轮 QueueDepth 244 / TTFT p95 76s 越线，KubeStasis 把副本从 1 扩到 3，撤负载后按稳定
窗口逐步缩回 1。同日补跑（§6）用单信号隔离让 **`KVCacheUsage` 也越过 0.85（峰值 1.000）**
并独立驱动 `1 → 2 → 3`。至此三条信号**各自**都在真实指标上越线过、都触发过决策——
不是同一轮负载里同时越线。

## 1. 环境

| 项 | 实际值 |
|---|---|
| 实例 | 腾讯云 CVM `GN7.2XLARGE32`，上海五区，8 核 32 GiB |
| GPU | Tesla T4 16 GiB，compute capability 7.5（sm_75） |
| 系统 | Ubuntu 24.04.4 LTS，Python 3.12.3 |
| 驱动 | 580.126.20（购买页勾选「后台自动安装 GPU 驱动」自动装好） |
| vLLM | 0.34.0，torch 2.14.0+cu130 |
| 模型 | Qwen2.5-1.5B，fp16（T4 不支持 bfloat16，vLLM 自动降级） |
| KV cache | 8.26 GiB / 309,248 tokens，2048 上下文下并发上限 151 |
| 启动参数 | `--max-model-len 2048 --gpu-memory-utilization 0.85` |

Kubernetes 在本地 Docker Desktop（v1.36.1），manager 以 `go run ./cmd` 跑在宿主机，
经 SSH 隧道连 CVM 上的 Prometheus（`-L 9090:127.0.0.1:9090`）。

## 2. 配置

controller 启动参数（注意窗口是 flag，不是环境变量，见 §5）：

```bash
PROMETHEUS_URL=http://127.0.0.1:9090 \
  go run ./cmd --enable-webhook=false --prometheus-window=1m
```

App CR：`minReplicas: 1`、`maxReplicas: 3`、`cooldownSeconds: 15`、
`scaleDownStabilizationSeconds: 10`，三个指标目标 `QueueDepth=2` / `TTFT=1s` /
`KVCacheUsage=0.85`，`image` 用 `nginx:1.27-alpine`。

指标名对齐：vLLM 0.34 暴露的是 `vllm:kv_cache_usage_perc`，而代码默认查
`vllm:gpu_cache_usage_perc`，用一条 recording rule 做别名，没改 Go 代码：

```yaml
- record: vllm:gpu_cache_usage_perc
  expr: vllm:kv_cache_usage_perc
```

## 3. 过程与证据

压测工具用 500 并发、每请求 256 新 token 打 `localhost:8000/v1/completions`，
持续到信号明显越线为止。三个信号的时间序列（Prometheus 30 秒步长）：

| 时刻 | QueueDepth | KVCacheUsage | TTFT p95 |
|---|---|---|---|
| 18:24:30 | 0 | 0.0095 | 0.078s |
| 18:26:00 | 0 | 0.133 | 0.663s |
| 18:27:00 | **244** | 0.005 | 0.735s |
| 18:27:30 | 242 | 0.274 | **34.2s** |
| 18:28:30 | 243 | 0.255 | **76.4s** |
| 18:29:30 | 244 | 0.225 | 76.3s |
| 18:30:00（撤负载） | 0 | 0.237 | 77.0s |

Kubernetes 事件（UTC，原文照抄）：

```
2026-11-20T10:27:08Z  KubeStasisScaleUp    ScaleUp: 1 -> 3 (load above targets)
2026-11-20T10:27:20Z  KubeStasisReconcile  app available: 3/3 replicas ready
2026-11-20T10:31:09Z  KubeStasisScaleDown  ScaleDown: 3 -> 2 (load below targets)
2026-11-20T10:31:24Z  KubeStasisScaleDown  ScaleDown: 2 -> 1 (load below targets)
```

对应本地时间 18:27:08 扩容、18:31:09 与 18:31:24 分两步缩容。撤负载到第一次缩容
间隔约 69 秒（1m 窗口 + 10s 稳定窗口 + 决策周期），缩容是**单步**的，没有 3→1 连跳。

## 4. 边界（别把这条记录读大）

- **扩出来的副本是装饰对象。** App 的 `image` 是 `nginx:1.27-alpine`，只被改 `replicas`，
  不承接任何推理流量。这份记录证明的是「三个信号 → 决策 → 副本数」这条链路在真实
  指标上通，**不是**「扩容改善了推理延迟」。后者这个项目从未验证，也不在本次范围内。
- **首轮 KVCacheUsage 没越线，补跑才越线。** 首轮峰值 0.274，离 0.85 很远：1.5B 模型配
  2048 上下文，KV 池有 309k token，且 500 个并发请求共用同一份 prompt，被 prefix caching
  合并了 KV。补跑靠「唯一前缀破缓存 + `ignore_eos` 拉长驻留」把占用率推到 1.000，细节见
  §6。两轮合起来只能说「三条信号**各自**越线过」，不能说「同一轮里三条同时越线」——
  首轮是 QueueDepth + TTFT，补跑只配了 KVCacheUsage 一条。
- **只有一次运行，没有重复。** n=1，不构成统计结论，也别拿它算效应量。它的价值是
  「这套配置在真实 GPU 上跑得通，且决策确实发生」。

## 5. 这次撞到的坑（已回写进开工清单）

1. **`PROMETHEUS_WINDOW` 这个环境变量不存在。** 代码只认 `--prometheus-window` flag
   （`cmd/main.go:72`），环境变量写了会被静默忽略，退化成默认 5m——正好踩中文档 §0.3
   警告的「短压测拿不到 TTFT」。我第一次启动就是 5m，日志里 `"window": "5m"` 才暴露。
2. **公共镜像缺 `python3.12-dev`。** torch 的 triton 后端要即时编译 kernel，缺
   `Python.h` 会直接 `fatal error: Python.h: No such file or directory`，engine 起不来。
   装 `python3.12-dev` + `build-essential` 即可。
3. **`vllm:gpu_cache_usage_perc` 在 0.34 已改名为 `vllm:kv_cache_usage_perc`。**
   不配别名，KVCacheUsage 会一直返回空值、静默弃权。
4. **上海机器下不动 GitHub Releases。** `github.com` 本身 200，但 release 资源 404/超时，
   换清华镜像 `mirrors.tuna.tsinghua.edu.cn/github-release/` 秒下。
5. **huggingface.co 不通，hf-mirror 通但 hf-xet 会卡死。** `hf download` 走到一半
   停在 `.cache` 里不动（10 秒零增长）。改用 `modelscope` 的 `snapshot_download`，
   稳定 10–12 MB/s。
6. **FA2 不可用是正常的。** T4 只有 sm_75，而 FlashAttention 2 要求 ≥ sm_80，vLLM 会
   自动选 `TRITON_ATTN`。日志里那条 `Cannot use FA version 2` 是预期行为，不是错误。
7. **首次 reconcile 有一条 `services "vllm" already exists`。** 代码走的是
   `CreateOrUpdate`（先 Get 再 Create），报这个说明 informer 缓存还没同步到刚创建的对象，
   Get 拿到 NotFound、Create 撞上已存在。下一轮自行恢复（18:22:55 即 `1/1`），属自愈型
   竞态，不影响结论。
8. **相同 prompt 会被 prefix caching 合并，KV 压不上去。** 补跑第一版 256 并发长 prompt
   仍只有 0.268，`prefix_cache_hits_total / queries = 688704 / 806578 ≈ 85%`。每个请求在
   prompt 开头加唯一前缀即可破坏共享（修正后 hits 停止增长）。
9. **不加 `ignore_eos` 时模型会立刻收尾。** 实测 `completion_tokens=1`，KV 驻留太短压不住；
   让它跑满 `max_tokens` 后单请求约 6.6 秒，占用率才能稳住。

## 6. 补跑：让 `KVCacheUsage` 单独越线（同日 18:45–19:07）

首轮 KV 峰值 0.274，是三条信号里唯一没越线的。补跑只回答一件事：**在真实指标上把
`KVCacheUsage` 推过 0.85，并确认它能独立驱动决策**。口径与 §4 完全一致，不追求端到端弹性。

### 6.1 为什么简单加并发压不动

vLLM 的 scheduler 默认最多 256 个请求同时 running，超出的排队；而**排队请求不分配 KV
block**。首轮 500 并发时 `running=159`、KV 仍只有 0.274。补跑改用 256 并发（正好填满
running 槽）、每请求约 954 prompt token + 400 生成 token，让 256 个活跃序列同时占 KV。

但第一版仍只到 0.268：`prefix_cache_hits_total / queries = 688704 / 806578 ≈ 85%`，
256 个请求**共用同一份长 prompt**，被 prefix caching 合并成一份 KV。两处修正：

- 每个请求在 prompt **最前面**加唯一前缀 `[r-<worker>-<seq>-<uuid>] `，让首个 KV block
  就不相同，缓存无法共享（修正后 `prefix_cache_hits_total` 停止增长）；
- 加 `ignore_eos: true`。否则模型撞 EOS 立刻收尾（实测 `completion_tokens=1`），KV 驻留
  太短压不住；跑满 400 token 后单请求约 6.6 秒。

### 6.2 单信号隔离

App 的 `metrics` 只保留一条，扩容在逻辑上不可能由别的信号触发：

```yaml
metrics:
  - type: KVCacheUsage
    target: "0.85"
```

### 6.3 结果

KV 占用时间序列（Prometheus 30 秒步长，`vllm:gpu_cache_usage_perc` 别名）：

| 时刻 | KVCacheUsage | |
|---|---|---|
| 18:54:15 | 0.183 | |
| 18:54:45 | 0.537 | |
| 18:55:15 | 0.849 | 临界 |
| 18:55:45 | **0.978** | 越线 |
| 18:56:15 | **1.000** | 越线 |
| 18:56:45 | **0.921** | 越线 |
| 18:57:15 | 0.825 | 回落 |

同时 `num_requests_running=224`、`num_requests_waiting=28`、`num_preemptions_total=27`
—— KV 池确实被打满并开始抢占，不是数值凑出来的。负载脚本收尾 `ok=406, err=7`，
7 个失败来自抢占/超时，属真实内存压力。

Kubernetes 事件（UTC，原文照抄）：

```
2026-11-20T10:55:29Z  KubeStasisScaleUp  ScaleUp: 1 -> 2 (load above targets)
2026-11-20T10:55:29Z  KubeStasisScaleUp  ScaleUp: 2 -> 3 (load above targets)
```

`1 → 2 → 3` 是逐步扩到 `maxReplicas`，与 `KVCacheUsage` 按比例换算一致
（`inference_test.go` 中 `0.95/0.8 → 4×1.19 → 5` 那条）。

### 6.4 撤载后为什么没缩回去（不是 bug）

单信号配置下负载停止、KV 归零，但副本停在 3 不动。原因：KV 低于阈值时这条信号
**健康弃权**（`inference_test.go:52`「KV cache 健康弃权」），没有任何信号给出有效建议，
`Decide` 返回 `ActionNone` 保守保持现状。对照验证：把 App 恢复成三条 metric 后 32 秒内
`3/3 → 1/1`，证明 controller 正常、这只是单信号隔离配置的行为。完整缩容闭环见 §3。

### 6.5 边界不变

补跑仍是 n=1，扩出的副本依旧是 `nginx` 装饰对象、不承接推理流量。能写的是
「三条信号**各自**在真实指标上越线过、都触发过决策」；**不能**写「同一轮负载里三条
同时越线」，更不能写端到端弹性或「扩容改善延迟」。

