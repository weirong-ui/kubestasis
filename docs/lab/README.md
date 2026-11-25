# 实验记录

`hack/lab/` 里脚本的实测输出。每个实验都是"先写预测，再跑，再看差在哪"；
预测写在脚本头部，跑之前就能看到。这里只记结果和偏差，不重抄脚本逻辑。

环境：Docker Desktop 自带 k8s（v1.36.1），控制器 `kubestasis:p9`，镜像
`kubestasis-demoapp:v1` / `:v2-crash`。所有实验只写 `lab-*` 命名空间，
跑完自动回收；`bench`（压测基线）和控制器只读。

## 结果一览

> **时点说明（2026-11-24 补）**：这一批实验跑在控制器 `kubestasis:p9` 上，早于
> `86ee56f`（2026-11-20）合入的「全信号弃权守卫」。下表有两行依赖那条旧路径：
> 「指标全弃权（单元）」和「5（集群）」。旧实现里所有指标查询返回 `ok=false`
> 时，`desired` 停在 `minReplicas` 继续往下走，稳定窗口一过就按步长缩到 min，
> 原因码 `scale_down`、事件写 `load below targets`，这正是当时要复现的 bug。
> 现在 `internal/scaler/engine.go` 的 `if !anySignal` 分支返回 `ActionNone`、
> 保持副本数、原因码 `no_metrics_data`，`TestDecide_AllSignalsAbstain_HoldsReplicas`
> 与 `TestDecide_PartialAbstain_StillScales` 是回归门。按
> [hack/lab/README.md](../../hack/lab/README.md) 重跑，`TestLabAbstain` 二十四轮
> 恒为 `5`（本次用 `go test -overlay` 实跑过）；`exp5.sh` 走同一条 `ok=false`
> 路径，按当前代码也不会再缩到 min，但**未在集群重跑**。**两行观测保留不改**，
> 它们是修复前的真实快照；其余各行不依赖这条路径，不受影响。

| 实验 | 关键观测 | 结论 |
|---|---|---|
| 决策层（单元） | 稳定 60s+冷却 120s：`5 5 5 5 4 4 4 4`；稳定 0s：`4 4 4 … 3`；冷却 0s：`5 5 5 5 4 3 2 1` | 两个窗口各自贡献独立的延迟，不是同一个东西 |
| 指标全弃权（单元） | 二十四轮 `5 → 2` 仍在降；冷却 0 时一分钟缩到 1 | 指标全挂会缩到 min，且原因码是 `scale_down` |
| 5（集群） | `min=1` 组缩到 1；`min=3` 组停在 3；四条缩容事件同一秒 | 判别对照排除了"按步长缩到最少"这个竞争解释 |
| 3 + 4（集群） | 冷却 120s：间隔 121s；冷却 0：间隔 0s；稳定 120s：首次 120s，之后 3→2→1 同秒 | 冷却每步重新计时，稳定窗口只在第一次挡 |
| 4 跨重启 | `belowTargetSince` 重启前后都是 `08:14:20Z`，缩容发生在起点后 128s | 计时从 etcd 读回，不在内存 |
| 6 | 冷却 5s：120 秒内 6 次 L2、0 次 L3；改回 3m 后同一故障 21 秒升 L3 | 升级由时间窗口驱动，不是次数驱动 |
| 7 | `12:57:25` L2 摘 1 个；`12:57:55` 回滚到 v1 | 回滚改的是 `spec.image`，Deployment 复用 rev1 的 RS |
| 8 | 三次分别摘 1/2/2 个；同一时刻对照组 eviction 被 429 拒绝 | L2 当时走 `Delete`，PDB 不参与 |
| 9 + 10 | 手改 Deployment 副本：平均 475ms 被改回；删 Service：440ms / 427ms 重建 | `Owns` 是秒级，15 秒巡检兜底无法解释这个数量级 |
| 11 | 排除命名空间后非法 App 创建成功，控制器照建 3 副本；恢复准入后 App 卡在 `kubestasis.io/finalizer` | 准入是唯一防线；`failurePolicy=Fail` 会锁死删除 |
| 12 | 加 CRD 默认值后 apply 被拒：`spec.replicas(1) 必须落在 [3, 10] 区间内` | 默认值在准入之前生效，跨字段默认不能与它共存 |

> 双副本选主的实测不在 `hack/lab/exp*.sh` 里：脚本是 `hack/ha-verify.sh`，判定线写在
> [docs/ha-verification.md](../ha-verification.md)，原始数据在 `docs/lab/ha-20261125-145018/`。
> 那轮用的是 `kubestasis:ha1`（源码 `c076560`），不是下面这批实验的 `p9`。

## 三次预测错了，错的地方比结果有用

**实验 8：不是"一次删光"。** 预测 3 个 Pod 会一起被删，实测是 1~2 个。`Diagnose`
只把当轮处于 `CrashLoopBackOff` 的 Pod 放进 `report.Pods`，而三个容器的重启
退避是错开的。准确说法是"一轮内列表里有几个就删几个，没有上限、没有逐个退避"。

**实验 3：冷却关掉后间隔是 0 秒，不是 15 秒。** 我原以为 `RequeueAfter: 15s`
是节奏来源，实际它只是兜底下限——写 status 会立刻触发下一轮。

**实验 7：回滚后确实有 rev3，但它和 rev1 是同一个 ReplicaSet 对象。**
`kubectl get rs` 里查不到 `revision=1`，因为那个对象的注解被从 1 改成了 3。

## 两次设计错了，都在跑之前就该看出来

**实验 5 原设计要"停掉 Prometheus"。** 它只挂 config、没有 PVC，TSDB 在容器可写层，
`scale --replicas=0` 再拉起来就等于删掉压测历史。换成一个查不到指标的命名空间，
走的是同一条 `ok=false` 路径，代价为零。

**实验 9 原设计只"等 20 秒看有没有被改回来"。** 控制器有 15 秒巡检兜底，就算
`Owns` 完全失效也会被捡回来。判据必须改成耗时量级。

## 纵向故障：能做什么、做不了什么

上面全是横向语义（参数 → 行为）。纵向故障是"让某个部件坏掉，看系统怎么反应"，
更接近真实事故，但代价高：单节点 Docker Desktop 上做，等于把开发环境本身变成
故障现场。所以这一栏先列清楚可行性，只有第一条写了脚本。

| 故障 | 能验证什么 | 本机 | 门槛 |
|---|---|---|---|
| 节点失联 | NotReady 判定与驱逐之间的 260 秒窗口；控制面健康 ≠ 数据面健康 | 不行 | 一次性 kind，见 `fault-kubelet.sh`（未实测） |
| 证书过期 | 自签证书轮换；`failurePolicy=Fail` 时全部写入失败 | 不行 | 重建集群并缩短证书 TTL |
| apiserver 429 | 限流退避；`RetryOnConflict` 会不会把限流误当冲突 | 不行 | 改 apiserver `--max-requests-inflight` |
| etcd 写满 | 配额触发后 status 回写与 finalizer 的表现 | 不行 | 限制 etcd 配额，风险最高 |
| 网络分区 | watch 断线重连、relist、410 Gone；`pkg/miniinformer` 的断线语义 | 部分 | 在 kind 节点里用 iptables/tc 掐 |

建议顺序：先做节点失联（脚本已写，答案最确定），再做网络分区（能直接打在
`pkg/miniinformer` 上，而那个包的自述里就写着"断线期间被删的 key"这类坑），
限流和 etcd 留到最后——它们的价值主要在"见过一次失败长什么样"。

`fault-kubelet.sh` 与其它脚本的区别要说明白：它**没有在本机实跑过**，因为它
必然让节点 NotReady。它自己建一次性集群、跑完删掉，并硬性要求 context 是
`kind-lab-fault`，碰不到你现有的 `docker-desktop`。
