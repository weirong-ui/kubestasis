# KubeStasis Helm Chart

kustomize 之外的第二种安装形态。两者装的是同一个控制器，只是打包方式不同：

| | kustomize（`config/`） | Helm（`charts/kubestasis`） |
|---|---|---|
| 适用 | 开发、CI e2e、读源码 | 交付给别人的集群 |
| 参数化 | 改 manifest / overlay patch | `values.yaml` |
| Webhook 证书 | `hack/webhook-certs.sh` 自签脚本 | chart 内自签（升级自动重签+滚动）或 cert-manager |
| CRD | `kubectl apply -k config/crd` | `crds/`（仅首次安装创建） |

## 安装

```bash
# 最小安装（伸缩引擎休眠，其余能力可用）
helm install kubestasis ./charts/kubestasis -n kubestasis-system --create-namespace

# 打开伸缩：指向集群内 Prometheus
helm install kubestasis ./charts/kubestasis -n kubestasis-system --create-namespace \
  --set prometheus.url=http://prometheus.monitoring.svc.cluster.local:9090 \
  --set prometheus.window=1m

# 带 Admission Webhook（自签证书，不依赖 cert-manager）
helm install kubestasis ./charts/kubestasis -n kubestasis-system --create-namespace \
  --set webhook.enabled=true

# 本地镜像/kind 演示
helm install kubestasis ./charts/kubestasis -n kubestasis-system --create-namespace \
  --set image.repository=kubestasis --set image.tag=p8
```

## 验证

```bash
kubectl -n kubestasis-system rollout status deploy/kubestasis-kubestasis
kubectl apply -f config/samples/app_v1alpha1_app.yaml
kubectl -n default get app -w

# 决策指标（"为什么这次没扩"）
kubectl -n kubestasis-system port-forward svc/kubestasis-kubestasis-metrics 8080:8080
curl -s localhost:8080/metrics | grep kubestasis_scaling
```

接 Prometheus Operator 时开 `--set metrics.serviceMonitor.enabled=true`。生成的
ServiceMonitor 带 `honorLabels: true`：决策指标的 `namespace` 是**被伸缩 App 的命名空间**
（业务语义），不开它会被目标标签（控制器 Pod 所在 ns）覆盖、原值改名 `exported_namespace`，
按 App 过滤的面板和录制规则就全空了。现成面板见 [deploy/monitoring/grafana](../../deploy/monitoring/README.md)。

## 高可用（双副本选主）

```bash
helm install kubestasis ./charts/kubestasis -n kubestasis-system --create-namespace \
  --set replicaCount=2
```

`replicaCount > 1` 时 chart 自动补两件东西，都不需要额外开关：

- **PodDisruptionBudget** `minAvailable: 1`：节点 drain 时逐出 Pod，没有 PDB 可能两个副本同时被赶走，控制面停摆到新 Pod 调度起来。不想要就 `--set podDisruptionBudget.enabled=false`。
- **Pod 软反亲和**（`kubernetes.io/hostname`）：两个 manager 优先不同节点。用 `preferred` 不是 `required`，单节点集群（kind、Docker Desktop）照样能调度，只是退化成同节点。自己设了 `affinity` 就完全按自己的来。

选主由 `--leader-elect` 驱动，Lease 名 `kubestasis.io`，在 manager 所在命名空间。同一时刻只有一个 manager 跑控制器，另一个空转等接管。**验证记录见 [docs/ha-verification.md](../../docs/ha-verification.md)**：两个副本时的 Lease 唯一性、杀 leader 的接管时延、切换期间扩容是否重复执行。

两点必须知道的副作用：

- **指标会在副本之间跳。** 两个副本都监听 `:8080/metrics`，但只有 leader 的计数器在动。Service 轮询到 standby 时会读到全 0 的 `kubestasis_scaling_decisions_total`。多副本下按 `pod` 区分或只对 leader 采样，否则面板会出现锯齿。
- **Webhook 两个副本都能收。** 证书走同一个 Secret，不会错配；`failurePolicy: Fail` 时任一副本不可用都可能放大准入延迟，双副本提高了可用性也提高了这一层的复杂度。

## 升级与 CRD

`crds/` 下的 CRD **只在首次安装时创建**，`helm upgrade` 不会更新 schema
（Helm 的既定行为，不是本 chart 的疏忽）。升级后手动执行：

```bash
kubectl apply -f charts/kubestasis/crds/
```

不这么做的话，新版本新增的字段（比如 `scaleDownStabilizationSeconds`）会被
apiserver 当作未知字段剪掉，表现为"配置了但没生效"。

## Webhook 证书的两条路

- `webhook.certManager.enabled=true`：需要集群已装 cert-manager，且
  `webhook.certManager.issuerRef` 指向一个存在的 issuer。证书自动续期。
- 默认（false）：chart 用 Helm 的 `genSelfSignedCert` 现场生成自签证书。
  **每次 `helm upgrade` 都会重签**，Deployment 上的 `checksum/webhook-cert`
  注解会触发滚动重启，避免"旧 Pod 拿旧证书、caBundle 已更新"的错配
  （错配的表现是所有 App 创建/更新在准入阶段失败，`failurePolicy=Fail` 时尤其致命）。

## 注意事项

- **从 kustomize 迁移到 Helm 时，先把旧的拆干净**（`make undeploy` 或删掉旧命名空间与旧
  `Mutating/ValidatingWebhookConfiguration`），再 `helm install`。两套共存时 webhook 会同时生效：
  旧那套的 service 已无后端（manager 缩到 0 或删掉），`failurePolicy=Fail` 之下**所有** App
  写入——包括控制器摘 finalizer 的 Update——都会被 connection refused 打回，App 卡在
  Terminating。表象是"新装的控制器有毛病"，实际是死掉的那套在拦人（真集群踩过）。
- `failurePolicy: Fail`：控制器不可用时 App 的创建/更新会被拒绝。演示前先确认
  manager Pod Ready；生产环境想更宽容可设 `webhook.failurePolicy: Ignore`，
  代价是控制器挂掉时非法 App 能写进去。
- `replicaCount > 1` 时必须保持 `leaderElection: true`，否则多个 manager 会争抢同一个 App。
- 指标标签约定 `{app, namespace}` 由控制器注入的 `APP_NAME`/`POD_NAMESPACE` 保证，
  PromQL 里直接用这两个标签即可。
