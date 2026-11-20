# vLLM 推理信号实测记录（2026-11-20）

一次真实的、付费的、单卡 GPU 上的实测。目的只有一个：确认 `QueueDepth` / `TTFT` /
`KVCacheUsage` 这三个信号**在真实 vLLM 指标上能驱动 KubeStasis 的伸缩决策**。
开工清单见 [vllm-inference.md](vllm-inference.md)。

## 结论先说

三条信号里有两条独立越线（QueueDepth、TTFT），KubeStasis 在 15 秒内把副本从 1 扩到 3；
负载撤掉后按稳定窗口逐步缩回 1。**`KVCacheUsage` 全程没到阈值**，见 §4。

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
- **KVCacheUsage 没触发。** 峰值 0.274，离 0.85 很远。原因很直接：1.5B 模型配 2048
  上下文，KV 池有 309k token，500 并发、256 token 输出也只填到四分之一。要让这条信号
  越线，得把上下文拉到 8k 以上或换成更大的模型——那会超出 T4 16G 的余量。所以三条信号
  里实际起作用的是 QueueDepth 和 TTFT 两条。
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
