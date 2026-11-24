# AI 参与记录（按可核验的事实）

README 里原来有一张分工表，按模块写哪些代码由 AI 起草，并用了「我逐行改」这类说法。那句话证明不了什么，2026-11-24 从 README 删掉。这里换成能查的东西：某个问题被什么手段暴露、修在哪个提交、哪条门防止它回来。

原来那条底线继续用：AI 写下的每个「已验证」都要有对应的命令输出，没有就删。STATUS 里的「未实测」就是这么留下的。

## 怎么核

这里每条记录都能落到下面四类东西之一，不用靠自述。

- 提交哈希。`git show <hash>` 能看到改了什么。
- 报告与原始数据。`docs/benchmark/` 下的报告和 CSV，数字能自己复算。
- 测试与门。用例名、`hack/lab/` 下的实验脚本、`.github/workflows/ci.yml` 里的步骤，跑一次就有输出。
- CI run 编号。GitHub Actions 上的 job 结论和日志。

## 记录

| 日期 | 问题 | 怎么暴露的 | 修复与可查证据 | 防回归 |
|---|---|---|---|---|
| 2026-11-03 | 省略策略的 App 在首轮 Reconcile 死循环；L3 回滚会选回坏镜像 | 代码复查与 kind CI | `4463133`（`Scaling` / `Health` 改指针）、`a036ca1`（防乒乓，L3 选版排除坏镜像，提交信息里写明是 kind CI 抓到的） | CI e2e 的 P2 自愈回归 |
| 2026-11-04 | 五轮压测前四轮全废 | run2 采样循环用循环计数器当时间轴，每轮实际 6 到 9 秒，20 分钟被拉成 35 分钟，连 CSV 都没留；run3 把 `scrape_timeout: 20s` 写成大于 `scrape_interval: 5s`，Prometheus 拒绝启动、整轮 CrashLoop；run4 在一个采样窗口内 `3→2→1` 连跳两步、冷却被绕过，根因是 `Apply` 写 spec 立刻触发下一轮 Reconcile，而 cache 里的 `lastScalingAt` 还没更新；run1 是对称迟滞带 | [报告 §3](benchmark/hpa-vs-kubestasis.md) 逐轮归因，三份原始 CSV（`data-run1-symmetric-hysteresis.csv`、`data-run3-prometheus-crashloop.csv`、`data-run4-double-step-race.csv`），修复随 `565b0fb` 入库 | 时间轴改挂钟驱动；status 的冷却起点先于 spec 写入 |
| 2026-11-04 | 突发#2 起点误缩容 | run5 里 t≈535 时 QPS 的 1m 窗口均值还在 30 到 50，控制器算出 desired 3 小于 current 4，13 秒后又扩回 5 | 报告 §2.1 保留为历史记录；`1301365` 加 `scaleDownStabilizationSeconds`（默认 60s），真集群验证 | [D2a 协议](benchmark/d2a-protocol.md) 把误缩容写成计数指标，突发#2 窗口内相邻采样出现下降即计 1 次 |
| 2026-11-19 | miniinformer 五处 | 复查加回放：重连后 List 不清掉断线期间被删的 key，Store 留幽灵对象且 `DeleteFunc` 不触发；排队的 Add 被 Sync 覆盖；consume 卡在 Pop 时 done 唤不醒；List 失败直接退出、断线零间隔重连；`Apply` 偷偷改 `app.Spec.Replicas` | `af222e0`、STATUS 11-19 台账；回放脚本在 `hack/lab/` | 用例数 139 → 143；`make lab-check` 检查每个脚本都装了命名空间白名单 |
| 2026-11-20 | 三个已有缺陷 | 指标全弃权时 `Decide` 停在 min，六分钟 `5→2`，事件还写 `load below targets`；`hysteresisPercent` 用 `int + omitempty`，webhook 把显式 0 从 patch 里删掉、CRD 默认值再改回 10，「关闭」永远表达不出来；L2 用 `c.Delete` 绕过 PDB | `86ee56f`；healer 改走 `SubResource("eviction").Create`，RBAC 两份副本补 `pods/eviction` | 三条 scaler 单测（其中一条旧用例原先把 bug 写成预期）、healer 两条、e2e 的 L2 eviction 门；用例数 143 → 149 |
| 2026-11-20 | 文档与徽章写 144 用例，真实 `--- PASS` 是 149 | 合并预演时按包数出来的。git 不查，CI 原来也不查这一项 | `86ee56f` | `ci.yml` 的 build job 加「徽章等于真实 PASS 数」门；`doc_consistency.py` 加两条 REALITY 断言，实录存在时禁止文档写「AI 推理未实测」 |
| 2026-11-20 | e2e 的 PDB 回归门自己写错了 | 门断言「L2 走 eviction 会被 PDB 429 拦」，真 apiserver 上 PDB 是 `ALLOWED DISRUPTIONS 0`，但 L2 摘除的是 CrashLoopBackOff 未 Ready Pod，K8s 的 PDB 只保护 Ready Pod，eviction 放行，门跑满 6 分钟后失败 | CI run `44744579105` 的 job 日志；`76e5f3c` 把断言换成三条间接证据（RBAC 含 `pods/eviction`、healer 源码无直接 `Delete`、L2 事件写 `evicted` 而非 `deleted`） | CI run `44750774603` 六个 job 全绿 |

## 不写什么

不区分哪一行是谁写的，没有证据能支持这种区分，也不写「逐行改」「我定语义」这类动作描述：动作查不了，结果能查。最后两条记录里出错的都是门和文档本身，留着比删掉有用。没有证据的地方照 [STATUS §七](STATUS.md) 标未实测：D2a 十轮没跑、KEDA 对照没做、双副本 leaderElection 切换没验证。

## 边界

这份记录只说明问题怎么被发现，不证明代码正确，也不构成端到端弹性或统计结论。压测是单节点单次运行，方差还没补齐，见 [variance-precheck.md](benchmark/variance-precheck.md)；重复实验的判定线在 [d2a-protocol.md](benchmark/d2a-protocol.md)，一轮数据都还没跑。
