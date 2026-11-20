# vLLM 推理信号实测：开工清单

> **状态：已执行一次（2026-11-20，腾讯云 T4 单卡）。** 结果与证据见
> [vllm-inference-run-2026-11-20.md](vllm-inference-run-2026-11-20.md)：
> 三条信号中 QueueDepth 与 TTFT 越线，副本 `1 → 3`；撤负载后按稳定窗口 `3 → 2 → 1`。
> `KVCacheUsage` 峰值只到 0.27，未触发（原因见那份记录的 §4）。
> 本文仍是可复现的开工清单，下面的结果栏保持空白，值以那份记录为准。
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

不同 vLLM 版本（尤其 V1 引擎）会改名或移除指标，CPU 后端还会多一条
`vllm:cpu_cache_usage_perc`（GPU 之外的 KV cache），不一定上报 `gpu_cache_usage_perc`。
开工第一步是 `curl -s localhost:8000/metrics | grep -E '^vllm:' | head -30`，把真实名字抄进 §7。
名字不一致时**用 recording rule 做别名**（§3.3 附），不要改 Go 源码默认值去迁就一套私有名字——
源码注释第 35 行写明了默认值不该为某个环境让路。CPU 后端缺哪条就如实写"未触发"，
不许把 `cpu_cache_usage_perc` 硬凑成 GPU 那条来宣布三信号全通。

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
用 `--prometheus-window=1m` 这个 **flag**，并让打流持续 ≥3 分钟，
别用 30 秒的脉冲流量。`QueueDepth` 是 `sum()` 不带 rate，不受这条影响。

注意：**没有 `PROMETHEUS_WINDOW` 这个环境变量**。只有 `--prometheus-url` 读环境变量
`PROMETHEUS_URL`，窗口只认 flag（`cmd/main.go:72`）。写成环境变量会被静默忽略、
退回默认 5m，日志里能看到 `"window": "5m"`。

## 1. 环境与分工

下表是**主线 A（腾讯云 CVM 按量付费 GPU 实例）**的布局。不花钱的**零成本 C（本机 CPU 版 vLLM）**见 §6，
那种情况下 vLLM / Prometheus / loadgen 全在本机，不需要 CVM 和 SSH 隧道，§2 自检 A
与 §3.4 整段跳过。两档共用 §0、§3.2 的 label 规则、§3.5 之后的 controller 与 App 配置。

| 组件 | 跑在哪 | 说明 |
|---|---|---|
| vLLM（Qwen2.5-1.5B，`:8000`） | 腾讯云 CVM（GPU 按量实例） | 单卡 T4 16G / A10 24G 都够 1.5B；`--max-model-len 2048`，`--gpu-memory-utilization` 留余量 |
| Prometheus（`:9090`） | CVM，官方二进制（也可 docker） | 抓 vLLM，补 `app` / `namespace` label |
| loadgen | CVM | 本机打 `localhost:8000`，不用把 8000 也转出来 |
| KubeStasis manager | **本地宿主机进程**（`go run ./cmd`） | 直连当前 kubeconfig，避开"容器内访问宿主机"的网络坑 |
| Kubernetes | 本地 docker-desktop v1.36.1 | `kubectl` 1.36.1 / Docker 29.9.2 已就绪；本机没有 `make` / `kind` / `helm`，用等价命令 |
| SSH 隧道 | 本地，走 CVM 公网 IP | `-L 9090:127.0.0.1:9090`，manager 连 `127.0.0.1:9090`；CVM 安全组不必放行 9090 |

**备选 B**：如果 CVM 的 SSH 从我这边连不上，把整套搬到 CVM 上（k3s + in-cluster manager
+ 同机 Prometheus），代价是要装 k3s、且跨容器访问宿主机端口要显式配
`host.docker.internal`。主线不成立时再切，别一上来两头都搭。
本地出站已实测：443、22，以及 2222 / 30000 这类自定义高位端口都通（对端确实监听时），
所以主线 A 大概率成立；但这是 TCP 层探测，不等于 CVM 实例真能连，仍以 §2 自检 A 为准。

### 1.1 CVM 开工配置

| 项 | 选什么 | 为什么 |
|---|---|---|
| 计费 | **按量计费**，下单前看清费用单位是「元/小时」 | 只跑 2–3 小时；创建时会冻结一小时费用，销毁后解冻。页面右下角的配置费用若没标单位，务必点「费用明细」确认是按量小时价，别误买包月 |
| 地域 | 有货就行（香港 / 上海 / 北京均可） | 不影响任何步骤：`kubectl` 在本地、流量走 SSH 隧道。香港出站拉 PyPI / 模型权重更顺，内地地域延迟更低；单价以页面为准，别照抄网上数字 |
| 机型 | 单卡 T4（16G）或 A10（24G），如 `GN7.2XLARGE32`（8C32G + 1×T4） | 1.5B 模型用不到大卡；T4 的 compute capability 是 7.5，正好卡在 vLLM 要求的下限（官方 ≥ 7.5），再小的卡跑不了 |
| 系统 | **Ubuntu Server 24.04 LTS 64 位**（公共镜像） | vLLM 要求 Python 3.11–3.14；24.04 自带 3.12 正好够，20.04 自带 3.8、22.04 自带 3.10，都得额外装 Python，反而更麻烦 |
| GPU 驱动 | 勾「后台自动安装 GPU 驱动」，驱动 / CUDA / cuDNN 用默认下拉（实测为 580 / CUDA 13.0 / cuDNN 9.20） | 驱动 580 ≥ 525，向下兼容 vLLM wheel 依赖的 CUDA 12.x。**别**为了"对齐 CUDA 12.9"去换镜像或手动降级 |
| 系统盘 | 默认 100G 增强型 SSD 即可 | 模型权重 3G 左右，50G 也够；这 2–3 小时的盘费可以忽略，不值得为省几毛钱去改 |
| 登录 | **绑定 SSH 密钥**（§1.2），不要只设密码 | 我这边用 `BatchMode` 非交互登录，只给密码会直接失败 |
| 安全组 | 只放行入站 22；**不要**放行 9090 / 8000 | 9090 走隧道，公网暴露等于把 Prometheus 开放出去 |
| 公网 IP | **勾「分配独立公网 IP」**（或事后绑 EIP） | 购买页这一项默认不勾，不勾就没公网 IP，我连不上；EIP 是为了关机再开时 IP 不变 |
| 公网带宽 | 计费方式选**按流量**，带宽上限**拉到 20Mbps 以上** | 按流量只收出流量（中国香港约 ¥0.67/GB），抬上限不额外花钱；但**入带宽跟着上限走**——上限 ≤10Mbps 时入方向被固定为 10Mbps，而 `pip install vllm` 加 3GB 模型权重约 6GB 下载，10Mbps 要 80 分钟，20Mbps 减半 |

首次开 GPU 机型可能需要先在控制台申请配额，部分可用区也会无库存——这两件只能账号
本人在控制台确认，开工前先确认好，别等实例开起来才发现选不了卡。

点「开通」时报 `指定实例类型的库存小于指定的购买数量 (29170130)`，是**该可用区这一档没货**，
不是配置错、也不是余额不足：换可用区（同地域内换区最省事，SSH 密钥全地域通用、不用重导）
或换地域重试即可，已充值的余额不会损失。安全组是单地域资源，换地域要重建，密钥不用。

另一种失败是**下单成功但创建失败**：几分钟后收到「云服务器创建结果」邮件，写"由于当前资源紧张，
排队人数过多……0 台创建成功"，系统自动退款。这同样是抢不到资源，不是配置问题；重试时优先换
可用区（同区被抢空时换区比同区反复点更有效），并留意购买页规格行上的「库存 / 紧缺」标签。

### 1.2 SSH 密钥

我在本机生成了一对专用密钥（私钥留在本地、不入库、不进 git）：

```
~/.ssh/kubestasis_vllm_tencent        # 私钥，权限 600
~/.ssh/kubestasis_vllm_tencent.pub    # 公钥
```

创建 CVM 时在「SSH 密钥」里新建并粘贴这段公钥。两个坑：

- **密钥名称只能用字母、数字、下划线**（`kubestasis_vllm`），带连字符会报"请输入密钥名称"；
- 公钥**必须在一行里**，中间不能有换行或多余空格，粘完按一次 `End` 应该直接到行尾。

公钥：

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIe1z1vH1W1iCmgUta/kJZI6yeMzAuL7XGVltACAYJwI kubestasis-vllm-tencent-temp
```

实例销毁后这对密钥就没用了，可以随时删。

需要账号本人的共四件：**注册/实名与付款**、**创建实例（选卡、绑公钥、确认配额）**、
把公网 IP 给我、**用完销毁实例**。其余步骤都可脚本化代跑。

## 2. 前置自检（开工第一条命令）

```bash
# A. CVM 是否能连（腾讯云 Ubuntu 镜像默认用户是 ubuntu，不是 root；密钥见 §1.2）
ssh -o BatchMode=yes -i ~/.ssh/kubestasis_vllm_tencent -p 22 ubuntu@<公网IP> 'echo ok'

# B. 真实指标名（抄进 §7；vLLM 要到 §3.1 才起，这条在起完服务后跑）
ssh -i ~/.ssh/kubestasis_vllm_tencent -p 22 ubuntu@<公网IP> \
  'curl -s localhost:8000/metrics | grep -E "^vllm:" | head -30'

# C. 本地集群
kubectl get nodes
```

A 不通就先停，不要往下跑；B 里三条指标缺任何一条，按 §5 中止。
腾讯云 Ubuntu 镜像默认只让 `ubuntu` 用户登录，`root` 直接连会被拒。要提权就 `sudo -i`；
若 sudo 要密码而密钥登录又没法交互，先在控制台给实例设一个登录密码（或从 VNC 进去配
免密 sudo），别等跑流时才发现提不了权。

## 3. 步骤

### 3.1 起 vLLM（CVM）

系统里没有 vLLM 本体。动手前先确认驱动真的装好了（勾了「后台自动安装」也要等它装完，
通常开机后 1–2 分钟）：

```bash
nvidia-smi        # 必须看到 T4 和 "Driver Version: 580.x"
```

装法选一种，默认走 A。

**A. venv + pip**（跑在宿主机，§3.2 的 target 原样可用）

```bash
# python3.12-dev 不是可选项：torch 的 triton 后端要即时编译 kernel，缺 Python.h
# 会直接 fatal error，engine 起不来（2026-11-20 实测踩过）
sudo apt install -y python3-venv python3.12-dev build-essential
python3 -m venv ~/vllm && source ~/vllm/bin/activate
pip install vllm
vllm serve Qwen/Qwen2.5-1.5B --port 8000 --max-model-len 2048 \
  --gpu-memory-utilization 0.85 --host 0.0.0.0
```

venv 建在家目录而不是 `/opt`，省掉 `sudo` 建目录、后来又要 `chown` 的麻烦。
Ubuntu 24.04 有 PEP 668，**必须在 venv 里装**。直接在系统 Python 上 `pip install`
会报 `externally-managed-environment`；别用 `--break-system-packages` 图省事，
这个实验不值得冒污染系统 Python 的险。

**模型权重怎么下来**：内地机器连不上 huggingface.co，`hf-mirror.com` 能通但 hf-xet
会卡死（下载停在中途、`.cache` 里零增长）。用 modelscope 最稳，实测 10–12 MB/s：

```bash
pip install modelscope
python -c "from modelscope import snapshot_download; \
print(snapshot_download('Qwen/Qwen2.5-1.5B', cache_dir='/home/ubuntu/ms'))"
# 输出路径形如 /home/ubuntu/ms/models/Qwen--Qwen2.5-1.5B/snapshots/master
vllm serve <上面的路径> --served-model-name Qwen/Qwen2.5-1.5B ...
```

注意要带 `--served-model-name` 对上 App 侧引用的模型名，否则 loadgen 里的 `model`
字段对不上。香港地域直接 `vllm serve Qwen/Qwen2.5-1.5B` 让它自己下也行。

**B. 官方 Docker 镜像**（需要先自己装 Docker + nvidia-container-toolkit，公共镜像不带）

```bash
docker run -d --name vllm --gpus all -p 8000:8000 \
  vllm/vllm-openai:latest --model Qwen/Qwen2.5-1.5B \
  --max-model-len 2048 --gpu-memory-utilization 0.85
```

走容器时 §3.2 的 target 要改成容器可达地址（或让 Prometheus 也 `--network host`），
别照抄 `host.docker.internal:8000`。

确认服务起来：`curl -s localhost:8000/v1/models`。

`--gpu-memory-utilization` 默认 0.9，容易和模型权重、激活一起挤爆显存；0.85 是保守起点，
按实际显存调。T4 只有 16G，1.5B 模型够用但余量小，起不来就把 `max-model-len` 降到 1024
或把该值调到 0.7；A10 24G 宽松些。

### 3.2 写 `prom.yml`（CVM）

```yaml
global:
  scrape_interval: 5s
  evaluation_interval: 5s

rule_files:
  - /etc/prometheus/alias.yml      # 仅当 §0.1 的真实指标名与默认值不一致时需要

scrape_configs:
  - job_name: vllm
    static_configs:
      - targets: ['127.0.0.1:8000']   # Prometheus 与 vLLM 同机跑，别写 host.docker.internal
        labels:
          app: vllm                 # 必须逐字等于 App CR 的 metadata.name
          namespace: vllm           # 必须逐字等于 App CR 所在的 namespace
```

公共镜像里 vLLM 和 Prometheus 都跑在宿主机上，`127.0.0.1:8000` 直接可达。只有下面
§3.3 走 Docker 那一种才需要 `host.docker.internal`。

### 3.3 起 Prometheus（CVM）

公共镜像**不含 Docker**，最省事的做法是直接用官方二进制，不装容器运行时：

```bash
# 内地机器直连 GitHub Releases 大概率卡住（github.com 200、release 资源超时），
# 走清华镜像；版本号按 LatestRelease 目录下的实际文件名改
V=3.16.0
curl -sLO "https://mirrors.tuna.tsinghua.edu.cn/github-release/prometheus/prometheus/LatestRelease/prometheus-$V.linux-amd64.tar.gz"
tar xf "prometheus-$V.linux-amd64.tar.gz"
sudo mkdir -p /etc/prometheus
sudo cp prom.yml /etc/prometheus/prometheus.yml
[ -f alias.yml ] && sudo cp alias.yml /etc/prometheus/alias.yml
nohup ./prometheus-$V.linux-amd64/prometheus \
  --config.file=/etc/prometheus/prometheus.yml --web.enable-lifecycle \
  --storage.tsdb.path=/tmp/prom-data > /tmp/prom.log 2>&1 &
```

想用容器也行，先 `sudo apt install -y docker.io`，然后起 `prom/prometheus` 并带
`--add-host=host.docker.internal:host-gateway`，同时把 §3.2 的 target 改成
`host.docker.internal:8000`。两条路都能走，别混着写。

指标名不一致时的 `alias.yml`（把真实指标映射成默认名，不改 Go）：

```yaml
groups:
  - name: vllm-alias
    rules:
      - record: vllm:gpu_cache_usage_perc
        expr: vllm:kv_cache_usage_perc      # 换成 §2.B 查到的真实名字
```

**vLLM 0.34 实测**：暴露的就是 `vllm:kv_cache_usage_perc`，上面这段原样可用；
`num_requests_waiting` 和 `time_to_first_token_seconds_bucket` 的默认名没变。
不配这条别名，KVCacheUsage 会一直返回空值、静默弃权——不报错，最难查。

另外 `prom.yml` 里要加 `rule_files: [<alias.yml 绝对路径>]`，否则别名规则不会被加载。

**验收**：`curl -s 'http://localhost:9090/api/v1/query?query=vllm:num_requests_waiting{app="vllm",namespace="vllm"}'`
必须返回非空 `result`。这一步不过，后面全部白跑。

### 3.4 隧道（本地，保持后台）

```bash
ssh -N -i ~/.ssh/kubestasis_vllm_tencent -L 9090:127.0.0.1:9090 -p 22 ubuntu@<公网IP>
curl -s 'http://127.0.0.1:9090/api/v1/query?query=up' | head -c 200
```

### 3.5 起 controller（本地）

```bash
kubectl apply -k config/crd
kubectl create namespace vllm --dry-run=client -o yaml | kubectl apply -f -
PROMETHEUS_URL=http://127.0.0.1:9090 \
  go run ./cmd --enable-webhook=false --prometheus-window=1m
```

窗口是 **flag**，不是环境变量——别写成 `PROMETHEUS_WINDOW=1m`，那个名字代码里不读，
会静默退回 5m（见 §0.3）。

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

### 3.7 打流（CVM）

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

删 App、停 manager、关隧道，**然后到腾讯云控制台销毁/退还实例**。

按量实例的关机计费容易踩坑，先说清楚：

- 按量实例**默认 `KEEP_CHARGING`**（关机照收 CPU/内存/GPU），但也有
  **「关机不收费」`STOP_CHARGING`** 选项：在控制台关机时选它，或 `StopInstances` API
  传 `StoppedMode=STOP_CHARGING`，CPU/内存/GPU 才停收（GPU 异构实例同样停）。
- 但即便选了「关机不收费」，**云盘、公网带宽、镜像仍继续计费**；而且 CPU/内存/GPU
  被释放、公网 IP 被回收（除非先转 EIP），再开机可能因资源不足失败、IP 也变了。
- 功能有限制：仅系统盘和数据盘**均为云盘**的按量实例可用；不适用于竞价实例、
  搭载本地盘的实例、在实例内部执行 `shutdown`、欠费关机。
- 所以本实验只跑一次、跑完不留环境，**最省事也最省钱的收尾是直接「销毁/退还」实例**，
  而不是纠结关机模式。这一步只能账号本人做。

一句话：不管是销毁还是关机，都别只把进程停了就走。账单以控制台实际出账为准，
按量计费创建时冻结的一小时费用会在销毁后解冻。

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

## 6. 成本：三档，可以一分钱不花

先说清楚钱花在哪：这个实验要验的是"三条 PromQL 在真指标上能否驱动副本变更"，
**KubeStasis 从头到尾只发 HTTP GET 到 Prometheus，不碰 GPU**。GPU 的作用只是让
vLLM 快一点、让 `gpu_cache_usage_perc` 这个名字名副其实。所以 GPU 不是必需项。

| 档 | 花销 | 做法 | 能写进结论的措辞 | 代价 |
|---|---|---|---|---|
| 主线 A：腾讯云 CVM 按量 GPU 实例 | 按量计费，2–3 小时 | §1–§3 原样 | "在单卡 GPU 的真实 vLLM 上" | **单价以购买页实时报价为准**（T4 / A10 单卡，不同卡型差好几倍）；要账号本人实名付款、创建、绑公钥、销毁；安全组只开 22，9090 走 §3.4 隧道 |
| **零成本 C：本机 CPU 版 vLLM** | **0 元** | 见下 | **"在真实 vLLM（CPU 后端）上，三信号中 N 条触发了决策"** | 见下，口径要多一层限定，但仍是真 vLLM、真 `/metrics`、真推理 |
| 免费 GPU：Kaggle / Colab | 0 元，但要注册 | 免费 T4 notebook | 不建议 | 会话 9–12 小时会断、环境每次重置、不能常驻开放端口给本地 controller 连；SSH 隧道那条路直接断了 |

### 零成本 C 怎么跑

本机已核过：没有 GPU（`nvidia-smi` 不存在），16 核 CPU，19.8 GiB 内存，
Docker Desktop 分到约 9.6 GiB、当前空闲约 5 GiB，Kubernetes 是 docker-desktop v1.36.1。
vLLM 有官方 CPU 镜像，不用编译：

```bash
docker run -d --name vllm-cpu -p 8000:8000 --shm-size 2g \
  -e VLLM_CPU_KVCACHE_SPACE=2 -e VLLM_CPU_OMP_THREADS_BIND=0-7 \
  vllm/vllm-openai-cpu:latest-x86_64 \
  --model Qwen/Qwen2.5-1.5B-Instruct --host 0.0.0.0 --port 8000 \
  --dtype bfloat16 --max-model-len 2048 --max-num-seqs 8 --enforce-eager
```

Prometheus 同样在本机用 docker 起，target 写 `host.docker.internal:8000`（Windows
Docker Desktop 自带这个 hostname），§3.2 的 `app` / `namespace` label 照样要补。
manager 直连 `127.0.0.1:9090`，**不需要 SSH 隧道、不需要第二台机器**，§2 的自检 A
和 §3.4 整段跳过。这也是唯一一条我能在本机全程代跑、且你不用开任何账号的路。

四个如实写下的限制：

1. 镜像解压后约 5.4 GiB，加上模型权重和 KV cache，本机 5 GiB 空闲内存会很紧；
   起容器前关掉不用的东西，`VLLM_CPU_KVCACHE_SPACE` 从 2 起、不够再调小。
2. CPU 推理慢，TTFT 会天然偏高，`"1s"` 阈值很容易越过——这算真触发，但要在
   报告里注明是 CPU 后端，别把慢当成"负载压力大"。
3. CPU 后端可能只上报 `vllm:cpu_cache_usage_perc` 而不报 `gpu_cache_usage_perc`
   （§0.1）。缺就写"KVCacheUsage 未触发"，不许用别名硬凑成三条全通。
4. 结论不能写"GPU 集群"或"AI 推理弹性已在真集群端到端验证"——后一句本来就被
   首屏口径声明挡掉了（扩出来的副本不承接流量）。

### 止损，三档通用

**单卡上 KV cache 占用率未必能推到 0.85**（T4 16G / A10 24G 都一样）——1.5B 模型配
2048 上下文，KV 池很大。
CPU 档则相反，`VLLM_CPU_KVCACHE_SPACE=2` 时更容易打满。无论哪档，它不越阈值就如实写
"KVCacheUsage 未触发"，不要为了凑齐三信号把目标值改到 0.1。三条里能坐实两条，也比编一条强。

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
