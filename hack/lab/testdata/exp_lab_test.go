package scaler

// 临时实验文件：只用来观察 Decide 在连续多轮里的输出，不做断言。
// 用法：复制到 internal/scaler/ 下，跑
//   go test ./internal/scaler -run TestLabTrace -v
// 跑完删掉，不要提交。
//
// 放在 testdata/ 下是为了不被 go build ./... 当成包编译。

import (
	"context"
	"fmt"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	appsv1alpha1 "github.com/weirong-ui/kubestasis/api/v1alpha1"
)

// fixedSource 是个假指标源：每轮都返回同一个期望副本数。
// 真实环境里这个值来自 Prometheus，实验里固定住，才能把变量控制在一个。
type fixedSource struct {
	want int32
	ok   bool
}

func (f fixedSource) DesiredReplicas(_ context.Context, _ *appsv1alpha1.App,
	_ appsv1alpha1.MetricTarget, _ int32) (int32, bool) {
	return f.want, f.ok
}

// runTrace 模拟控制器连续 12 轮 Reconcile，每轮间隔 15 秒。
// 只做三件事：调 Decide、把 Decision 的状态写回 status、动作生效后改 spec。
// 这三件事正是 controller 在真实环境里做的事，模拟出来才有可比性。
func runTrace(t *testing.T, name string, stabSeconds, cooldownSeconds, hystPercent int,
	signal int32, rounds int) {
	t.Helper()

	app := &appsv1alpha1.App{ObjectMeta: metav1.ObjectMeta{Name: "demo", Namespace: "default"}}
	replicas := int32(5)
	app.Spec.Replicas = &replicas
	stab := int32(stabSeconds)
	// 迟滞带现在是指针：nil 走 CRD 默认 10，显式 0 才是"关掉"。
	// 这里必须取地址，用 0 值 int 赋值会编译不过。
	hyst := int32(hystPercent)
	app.Spec.Scaling = &appsv1alpha1.ScalingPolicy{
		MinReplicas:                   1,
		MaxReplicas:                   10,
		CooldownSeconds:               cooldownSeconds,
		HysteresisPercent:             &hyst,
		ScaleDownStepPercent:          20,
		ScaleDownStabilizationSeconds: &stab,
		Metrics: []appsv1alpha1.MetricTarget{
			{Type: appsv1alpha1.MetricQPS, Target: "10"},
		},
	}

	eng := NewEngine().WithMetricsSource(fixedSource{want: signal, ok: true})
	base := time.Date(2026, 11, 17, 20, 0, 0, 0, time.UTC)

	trace := make([]int32, 0, rounds)
	var reasons []string

	for i := 0; i < rounds; i++ {
		now := base.Add(time.Duration(i) * 15 * time.Second)
		clock := now

		d := eng.Decide(context.Background(), app, func() time.Time { return clock })

		// 模拟 controller：Decision 带回来的计时建议由外层落盘
		if d.BelowTarget.Set {
			app.Status.BelowTargetSince = d.BelowTarget.Value
		}
		// 模拟 controller：动作落地后开冷却窗口，并把新副本数写回 spec
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

	fmt.Printf("%-26s 副本数: %v\n", name, trace)
	fmt.Printf("%-26s 原因码: %v\n\n", "", reasons)
}

func TestLabTrace(t *testing.T) {
	fmt.Println("起点 5 副本，每轮间隔 15 秒，共 12 轮（约 3 分钟）")
	fmt.Println()

	// 实验 3、4：两个窗口各贡献多少延迟。
	// A 是基线，B 只关稳定窗口，C 只关冷却窗口。
	fmt.Println("— 实验 3、4 —")
	runTrace(t, "A 稳定60s + 冷却120s", 60, 120, 10, 1, 12)
	runTrace(t, "B 稳定0s  + 冷却120s", 0, 120, 10, 1, 12)
	runTrace(t, "C 稳定60s + 冷却0s", 60, 0, 10, 1, 12)

	// 实验 1、2：同一条信号（要求 4 副本，比当前少 1），只改迟滞带。
	// D 是关掉迟滞（实验1），E 是拉满 50%（实验2）。
	fmt.Println("— 实验 1、2 —")
	runTrace(t, "D 迟滞0（实验1）", 60, 0, 0, 4, 12)
	runTrace(t, "E 迟滞50（实验2）", 60, 0, 50, 4, 12)

	fmt.Println("A 与 B 之差是稳定窗口的贡献；A 与 C 之差是冷却窗口的贡献。")
	fmt.Println("D 与 E 只差一个迟滞值：0 该缩，50 把 1 个副本的差挡在带内。")
}
