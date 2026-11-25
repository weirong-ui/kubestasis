# 控制面双副本：选主、接管与"不重复执行"验证

STATUS §七「控制面高可用」那条挂了三周：chart 早就带了 `leaderElection`，但 `replicaCount` 默认 1，**双副本下的选主接管、伸缩不重复执行从未实测**。README 也因此在"不要用它"的表里写着"单副本 manager"。

这份文档做两件事：先把判定线写死，再跑一遍给出证据。判定线部分在采集之前定稿，避免跑完再挑一个好看的口径。

## 一、边界

- 集群：本机 Docker Desktop 的 Kubernetes v1.36.1，**单节点**。真实 apiserver，不是 envtest、不是 fake client。
- 镜像：本地构建，tag 与提交在 §七登记。
- 形态：Helm chart，`replicaCount=2`、`leaderElection=true`、webhook 关闭。
- 指标源：集群内的假 Prometheus（固定返回 QPS=105），只为让伸缩引擎有活干，不测 Prometheus 本身。

单节点这个约束决定了能证明什么：两个副本落在同一节点上，**选主与接管可验，节点级容灾不可验**。软反亲和在单节点下退化成同节点，这是预期行为，不是失败。

## 二、被测形态

| 组件 | 配置 |
|---|---|
| Deployment | 2 副本，`--leader-elect`，Lease 名 `kubestasis.io`，命名空间 `kubestasis-ha` |
| PDB | chart 自动生成，`minAvailable: 1` |
| 反亲和 | 软约束（`preferredDuringSchedulingIgnoredDuringExecution`，topologyKey `kubernetes.io/hostname`） |
| App | `minReplicas=1`、`maxReplicas=6`、单信号 QPS 目标 `100`、冷却 0、迟滞 0、稳定窗口 0 |
| 假 Prometheus | 任意查询都返回 `105`，因此 App 的期望副本恒为 `ceil(105/100)=2` |

期望副本恒为 2 是关键设计：把 `spec.replicas` 人为改回 1，控制器就会再走一次 `1 -> 2` 的决策。每一轮都能独立观察"这次扩容是不是只发生了一次"。

## 三、判定线（采集前定稿）

四条假设，每条都有明确的通过条件和失败条件，没有"看起来还行"这种中间态。

**H1 只有一任 leader 在任。** 采样周期 1s，持续到测试结束，记录 `lease.spec.holderIdentity` 的持有者序列。两轮接管应该得到 `A -> B -> C` 三个互不相同的 Pod，每个只出现一次；standby 的日志里只有 `attempting to acquire`，没有 `successfully acquired`。

失败条件：序列长度不等于"轮数 + 1"（有副本没轮上，或者凭空多出一任）；或同一个 Pod 在序列里出现两次（掉线后又抢回来，说明租约语义有问题）；或 lease 指向已删 Pod 的时间超过 H2 的接管时延——那说明租约没被放开，不是正常的等过期。

这条的初版写的是"holder 指向已删 Pod 超过一个采样周期即失败"，与 H2 允许 45s 接管自相矛盾：接管本来就要等租约过期 15 秒起。按初版跑的那一轮因此判红（见 §七），随后改成现在这个写法。改的是判定式，采样和样本没动。

**H2 接管时延不超过 45 秒。** 计时起点是 `kubectl delete pod <leader>` 返回的时刻，终点是 lease 的 `holderIdentity` 变成另一个 Pod。

45 秒这个数的依据：controller-runtime 默认 `LeaseDuration=15s`、`RenewDeadline=10s`、`RetryPeriod=2s`，standby 在 lease 过期后 2 秒内重试。留三倍余量，超过 45 秒说明接管路径有问题，不是抖动。

**H3 切换期间扩容不重复执行。** 两个观察面：

1. 每 5 秒抓一次每个 manager 的 `/metrics`（走 apiserver 的 pods/proxy），看 `kubestasis_scaling_decisions_total`。同一个采样区间内，允许至多一个 Pod 的计数增长。两个都涨 = 两个 manager 同时在跑控制器。
2. `action="ScaleUp"` 的决策总数必须正好等于"轮数 + 2"：首次扩容 1 次、每轮复位 1 次、H4 再 1 次。多出来就是某一轮被执行了两次。同时 `spec.replicas` 的峰值必须停在 2，冲到 3 就是重复扩容。

失败条件：任一采样区间两个 Pod 计数同时增长；ScaleUp 决策数不等于预期；副本峰值超过 2。

数事件条数这条路走不通，是实测踩出来的：EventRecorder 会把 `reason` 和 `message` 相同的事件聚合成一条，`kubectl get events` 永远只返回一行，用它数次数会稳定得到 1。细节见 §五。

**H4 接管后功能不降级。** 新 leader 接管后，再复位一次 `spec.replicas=1`，90 秒内 `spec.replicas` 与 `status.currentReplicas` 都回到 2。

## 四、判废规则

满足任一条件，本轮作废重跑，不计入结论：

- 集群里还有别的 KubeStasis manager 在跑（它们管着同一个 CRD、会抢同一个 App，事件和决策计数都归不到被测的两个副本头上）。脚本预检会直接拒绝；本机那次先把手上的 manager 缩到 0，跑完恢复。
- 镜像 digest 与登记的提交不符。
- 采样中断超过 10 秒（包括 kubectl 超时、apiserver 重启）。
- App 在这轮里进入 `Healing` 或 `RollingBack`（自愈介入会污染扩容事件）。

## 五、采集方式

`hack/ha-verify.sh` 一个脚本跑完，输出落在 `docs/lab/ha-<日期>/`：

| 文件 | 内容 |
|---|---|
| `samples.csv` | 每秒一行：时间戳、lease holder、holder 是否存在、App `spec.replicas`、`status.currentReplicas`、Pod 数 |
| `metrics.csv` | 每 5 秒一行：每个 manager 的 `kubestasis_scaling_decisions_total` 合计，以及其中 `action="ScaleUp"` 的部分（只统计被测 App 自己的标签） |
| `events.txt` | 测试窗口内 App 的全部事件（只作人看的旁证，不参与判定） |
| `pods.txt` / `pods-deleted.txt` | manager 日志，含 `successfully acquired lease` / `attempting to acquire`；被删的 Pod 在删除前先留一份 |
| `summary.txt` | 四条假设的判定结果与关键数值 |

判定不用事件条数，用决策计数器。原因是踩出来的：EventRecorder 会把 `reason` 和 `message` 相同的事件聚合成一条，`count` 递增，`kubectl get events` 永远只返回一行 `ScaleUp: 1 -> 2`，拿它数"扩容发生了几次"会稳定得到 1。

脚本只读集群状态，不修改除测试命名空间之外的任何东西；唯一的破坏性操作是删除 leader Pod 和复位 App 的 `spec.replicas`。

## 六、不验证什么

写清楚边界比多验一条更有用。以下四条这轮不覆盖，别把结论外推：

1. **网络分区导致的脑裂**。冻结 leader 进程（SIGSTOP）或切断它与 apiserver 的连接，才是真正考验 lease 语义的场景。容器里没有 shell，本机也没有权限做 nsenter，这轮只做崩溃式接管（Pod 被删）。
2. **节点级容灾**。单节点集群，两个副本同节点，节点宕了都宕。
3. **多节点下的反亲和实际分散**。chart 只保证渲染出软反亲和；它是否把两个副本分到不同节点，要真集群看 `pod.spec.nodeName`。
4. **Webhook 双副本的准入表现**。这轮 `webhook.enabled=false`。

另有一条只记录不判定：两个副本都监听 `:8080/metrics`，Service 轮询到 standby 时会读到全 0 的决策计数。这是双副本的已知副作用，修法是按 Pod 区分或只对 leader 采样，属于观测层的事，不影响控制器行为。

## 七、结果

环境：本地 Docker Desktop，Kubernetes v1.36.1，单节点。镜像 `kubestasis:ha1`，源码 `c076560`（这轮只改 chart 与文档，控制器二进制与该提交一致）。chart `replicaCount=2`。

正式记录：[docs/lab/ha-20261125-145018](lab/ha-20261125-145018/summary.txt)，2026-11-25 14:50:18 起，91 秒采样 34 点。

| 假设 | 实测 | 判定 |
|---|---|---|
| H1 唯一 leader | leader 序列 3 个 Pod，每个只拿到一次 lease；standby 日志里只有 `attempting to acquire`，没有 `successfully acquired` | 通过 |
| H2 接管时延 | 18s、17s（两轮） | 通过（判定线 45s） |
| H3 不重复执行 | ScaleUp 决策 4 次 = 首次 1 + 两轮复位 2 + H4 1；replicas 峰值 2（没有冲到 3）；34 个采样点里没有任何一个区间两个 Pod 的决策计数同时增长 | 通过 |
| H4 接管后功能不降级 | 最后一次接管后再复位，副本回到 2 | 通过 |

接管 18/17 秒这个数不是抖动：`LeaseDuration=15s` 决定接管最快也要等满 15 秒（旧 leader 停止续约后租约才失效），加上 `RetryPeriod=2s` 与 apiserver 往返，17 到 20 秒是这套默认参数的正常区间。想更快只能调小 `LeaseDuration`，代价是网络抖动时更容易误判 leader 失联，这是取舍不是优化。

失败的那一轮保留在 [docs/lab/ha-20261125-144234](lab/ha-20261125-144234/summary.txt)：它的 H2/H3/H4 都过，只有 H1 按初版判定式判红，暴露的是判定式本身与 H2 冲突。留在仓库里比删掉有用。

### 脚本与口径改了三次

1. **事件数不能用来数扩容次数。** 前两轮按 `ScaleUp: 1 -> 2` 事件条数判定，控制器扩了、事件也在，但计数永远是 1，判定直接超时。原因是 EventRecorder 把相同 message 的事件聚合了。改成读 `kubestasis_scaling_decisions_total{action="ScaleUp"}`，按 Pod 取峰值再求和——被删的 Pod 计数会随对象消失，但峰值已经落进 CSV。
2. **复位和 spec 回写会打架。** 看到扩容事件就立刻把 `spec.replicas` 改回 1，控制器同一轮正在把 spec 写回 2，于是 1 被覆盖、一条事件都不产生。加了一步：等 `status.observedGeneration` 追上 `metadata.generation` 再复位。
3. **H1 判定式自相矛盾**，见 §三。

前两条是脚本 bug，第三条是判定线写错。记录轮是三次都修完之后跑的；脚本 bug 那几轮的目录没留（它们只说明脚本自己有毛病），判定式冲突那一轮留了下来，因为它记录了这次修正本身。
