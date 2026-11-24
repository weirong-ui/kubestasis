package scaler

// 临时实验文件 2：验证「所有信号弃权」时 Decide 会怎么走。
// 用法：go test ./internal/scaler -run TestLabAbstain -v
// 跑完删掉，不要提交。

import (
	"context"
	"fmt"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	appsv1alpha1 "github.com/weirong-ui/kubestasis/api/v1alpha1"
)

// deadSource 模拟 Prometheus 整体不可用：每次查询都返回 ok=false。
type deadSource struct{}

func (deadSource) DesiredReplicas(_ context.Context, _ *appsv1alpha1.App,
	_ appsv1alpha1.MetricTarget, _ int32) (int32, bool) {
	return 0, false
}

func runAbstain(t *testing.T, name string, stabSeconds, cooldownSeconds int, rounds int) {
	t.Helper()

	app := &appsv1alpha1.App{ObjectMeta: metav1.ObjectMeta{Name: "demo", Namespace: "default"}}
	replicas := int32(5)
	app.Spec.Replicas = &replicas
	stab := int32(stabSeconds)
	hyst := int32(10)
	app.Spec.Scaling = &appsv1alpha1.ScalingPolicy{
		MinReplicas:                   1,
		MaxReplicas:                   10,
		CooldownSeconds:               cooldownSeconds,
		HysteresisPercent:             &hyst,
		ScaleDownStepPercent:          20,
		ScaleDownStabilizationSeconds: &stab,
		Metrics: []appsv1alpha1.MetricTarget{
			{Type: appsv1alpha1.MetricQPS, Target: "10"},
			{Type: appsv1alpha1.MetricP99Latency, Target: "200"},
		},
	}

	eng := NewEngine().WithMetricsSource(deadSource{})
	base := time.Date(2026, 11, 17, 20, 0, 0, 0, time.UTC)

	trace := make([]int32, 0, rounds)
	var reasons []string

	for i := 0; i < rounds; i++ {
		now := base.Add(time.Duration(i) * 15 * time.Second)
		clock := now
		d := eng.Decide(context.Background(), app, func() time.Time { return clock })

		if d.BelowTarget.Set {
			app.Status.BelowTargetSince = d.BelowTarget.Value
		}
		if d.Action != ActionNone {
			ts := metav1.NewTime(now)
			app.Status.LastScalingAt = &ts
			next := d.ToReplicas
			app.Spec.Replicas = &next
		}

		trace = append(trace, d.ToReplicas)
		if len(reasons) == 0 || reasons[len(reasons)-1] != d.ReasonCode {
			reasons = append(reasons, d.ReasonCode)
		}
	}

	fmt.Printf("%-28s 副本数: %v\n", name, trace)
	fmt.Printf("%-28s 原因码: %v\n\n", "", reasons)
}

func TestLabAbstain(t *testing.T) {
	fmt.Println("场景：Prometheus 整个挂掉，所有信号返回 ok=false")
	fmt.Println("起点 5 副本，每轮间隔 15 秒，共 24 轮（6 分钟）")
	fmt.Println()

	runAbstain(t, "E1 稳定60s + 冷却120s", 60, 120, 24)
	runAbstain(t, "E2 稳定0s  + 冷却0s", 0, 0, 24)

	fmt.Println("要看的是：副本数有没有停在 5，还是一路缩到 min=1")
}
