# hack/lab：可复现的实验

这里的每个脚本都在本机 Docker Desktop 的 k8s 上真跑过，输出抄在
`docs/lab/README.md`。目的不是"再测一遍功能"，而是回答那些只读代码答不了的
问题：改一个参数，行为到底怎么变；某个设计主张在真实集群里成立吗。

## 怎么跑

```bash
make lab                     # 列出全部实验和各自证明什么
bash hack/lab/exp5.sh        # 单个实验，跑完自动清理
bash hack/lab/exp5.sh --keep # 保留现场自己看
LAB_GUARD_ONLY=1 bash hack/lab/exp5.sh   # 只验证守卫，不碰集群
```

前置：`kubectl`、本地集群（kind / Docker Desktop）、镜像
`kubestasis-demoapp:v1` 与 `:v2-crash`、控制器在 `kubestasis-hv` 里跑着。
缺哪个脚本会在开头直接说，不会跑到一半才炸。

## 安全模型

危险不来自命令敲错，来自"能碰到全局对象"。所以约束写在 `lib.sh` 里，而不是
每个脚本开头一句"请注意"：

- **命名空间白名单**：只允许 `lab-*`。写 `bench` 会被直接拒绝——2026-11-18
  的设计里本来要"停掉 Prometheus 看会怎样"，而它没有 PVC，停一次等于删掉
  十几天的压测历史。
- **受保护对象**：`bench`（压测基线）、`kubestasis-hv` / `kubestasis-system`
  （控制器自身）、`kube-*`、`default`。脚本只读它们，不写。
- **本地集群限定**：context 必须是 kind / docker-desktop / minikube。实验会改
  CRD、改 webhook、重启控制器，这些动作不该落在共享集群上。
- **清理幂等**：`trap EXIT` 兜底，跑两次不会重复删；`lab_cleanup_ns` 会确认
  命名空间真的消失，卡在 Terminating 时明确报出来。
- **静态门**：`make lab-check` 检查每个脚本都装了守卫、没有对受保护命名空间
  发起写操作。CI 里跑。

## 八个实验

> **时点说明（2026-11-24 补）**：`exp_abstain_test.go` 与 `exp5.sh` 记录的是
> `86ee56f`（2026-11-20）加「全信号弃权守卫」**之前**的行为：那时所有指标查询
> 返回 `ok=false` 会被当成 `desired=minReplicas`，一路缩到 min。现在
> `internal/scaler/engine.go` 的 `if !anySignal` 分支返回 `ActionNone`、保持副本数、
> 原因码 `no_metrics_data`。重跑 `exp_abstain_test.go` 会停在起始副本数（本次
> `go test -overlay` 实跑验证）；`exp5.sh` 走同一条路径，按代码也不会再缩，
> 但**未在集群重跑**。归档观测见 [docs/lab/README.md](../../docs/lab/README.md)，
> 两个脚本与 `exp5.sh` 的结论段保留不改，它们是当时的原始记录。

| 脚本 | 证明什么 | 耗时 |
|---|---|---|
| `exp_lab_test.go` | 决策层：稳定窗口、冷却、迟滞带各自的作用（A/B/C 拆窗口，D/E 是迟滞 0 与 50 的对照） | 0.3s |
| `exp_abstain_test.go` | 全信号弃权时是否保持副本数（旧版是「缩到 min」的 bug 证据，见上方说明） | 0.3s |
| `exp3_4.sh` | 冷却的间隔贡献；稳定窗口计时跨重启存活 | 6min |
| `exp5.sh` | 真实集群验证全弃权路径，含 min=1 / min=3 两组判别对照（旧版缩到 min，见上方说明） | 3min |
| `exp6.sh` | 冷却窗口短于探测周期时，升级条件永不触发 | 4min |
| `exp7.sh` | L2→L3 升级与回滚，rev1 复用验证 | 2min |
| `exp8.sh` | L2 绕过 PDB：同一时刻 eviction 429、Delete 成功 | 1min |
| `exp9_10.sh` | `Owns` 生效性，用耗时量级区分 watch 和 15 秒巡检 | 2min |
| `exp11.sh` | 准入是唯一防线；以及恢复准入后的 finalizer 死锁 | 2min |
| `exp12.sh` | CRD 默认值早于 mutating webhook（结果是"被拒"而不是"填 1"） | 1min |

两个 `.go` 文件放在 `testdata/` 下：Go 工具链会跳过这个目录，所以它们不会参与
`go build ./...`。留在 `internal/scaler/` 里会让 `go test ./...` 带着它们，
它们只打印不断言，永远绿；改引擎时还会因为字段变动连带编译失败。用法：

```bash
cp hack/lab/testdata/exp_lab_test.go internal/scaler/
go test ./internal/scaler -run TestLabTrace -v
rm internal/scaler/exp_lab_test.go
```

## 还没做的

上面全是横向语义（参数 → 行为）。纵向故障注入还缺：kill kubelet、证书过期、
apiserver 429 限流、etcd 写满、网络分区。这些在单节点 Docker Desktop 上要么
做不出来，要么会把整个开发环境搞坏，得换一次性集群做，所以先留在这里当账。
