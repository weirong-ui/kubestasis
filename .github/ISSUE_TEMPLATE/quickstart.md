---
name: 快速开始跑不通
about: 按 README 的步骤没跑起来，或者文档写的和实际不符
title: "[quickstart] "
labels: ""
---

**跑到哪一步了**

比如：`make deploy-webhook` 之后 `kubectl get app` 一直停在 Progressing。

**环境**

- Kubernetes 版本 / 发行版（kind / minikube / Docker Desktop）：
- 操作系统：
- 有没有可用的 Prometheus：

**看到了什么**

```
kubectl get events --sort-by=.lastTimestamp | tail -20
```

**你觉得文档该怎么改**

一句话就够，比如"Windows 下 `make` 不能直接用，需要先装 X"。
