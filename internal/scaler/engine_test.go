/*
Copyright 2026 weirong-ui

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package scaler

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	appsv1alpha1 "github.com/weirong-ui/kubestasis/api/v1alpha1"
)

// fakeSource 固定返回预设值，让 Decide 的每一道闸都可以独立测试。
type fakeSource struct {
	vals map[appsv1alpha1.MetricType]fakeVal
}

type fakeVal struct {
	replicas int32
	ok       bool
}

func (f fakeSource) DesiredReplicas(_ context.Context, _ *appsv1alpha1.App,
	target appsv1alpha1.MetricTarget, _ int32) (int32, bool) {
	v, ok := f.vals[target.Type]
	return v.replicas, ok && v.ok
}

func newApp(replicas, min, max int32, cooldown int, metrics ...appsv1alpha1.MetricTarget) *appsv1alpha1.App {
	// 稳定窗口默认关掉：本文件与 knobs/inference 的用例都在验证其它规则
	// （迟滞/冷却/步长/多信号），开着窗口会让所有缩容断言先被拦一轮。
	// 窗口本身由 stabilization_test.go 专门覆盖。
	noStabilization := int32(0)
	return &appsv1alpha1.App{
		ObjectMeta: metav1.ObjectMeta{Name: "sample", Namespace: "default"},
		Spec: appsv1alpha1.AppSpec{
			Replicas: &replicas,
			Scaling: &appsv1alpha1.ScalingPolicy{
				MinReplicas:                   min,
				MaxReplicas:                   max,
				CooldownSeconds:               cooldown,
				Metrics:                       metrics,
				ScaleDownStabilizationSeconds: &noStabilization,
			},
		},
	}
}

// TestDecide_NoScalingPolicy 省略 spec.scaling 时必须显式拒绝，
// 不能按零值继续（minReplicas=0 会把副本缩没）。
func TestDecide_NoScalingPolicy(t *testing.T) {
	app := &appsv1alpha1.App{
		ObjectMeta: metav1.ObjectMeta{Name: "bare", Namespace: "default"},
		Spec:       appsv1alpha1.AppSpec{Replicas: int32Ptr3(3)},
	}
	e := NewEngine().WithMetricsSource(fakeSource{vals: map[appsv1alpha1.MetricType]fakeVal{
		appsv1alpha1.MetricQPS: {100, true},
	}})
	d := e.Decide(context.Background(), app, func() time.Time { return frozen })
	if d.Action != ActionNone || d.Reason == "" {
		t.Fatalf("want explicit None with reason, got %+v", d)
	}
}

func int32Ptr3(v int32) *int32 { return &v }

// TestAppSpec_OmitsNilPolicies 锁住真实集群里炸出来的序列化 bug：
// Go 的 omitempty 对结构体不生效——值类型的 Scaling/Health 会被序列化成
// 零值对象（strategy=""），被 CRD 的 enum 校验拒绝，导致 finalizer 的
// Update 失败、对象卡死。指针类型 + omitempty 才能真正省略。
func TestAppSpec_OmitsNilPolicies(t *testing.T) {
	app := &appsv1alpha1.App{
		ObjectMeta: metav1.ObjectMeta{Name: "bare", Namespace: "default"},
		Spec:       appsv1alpha1.AppSpec{Image: "nginx:1.27"},
	}
	b, err := json.Marshal(app)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	if strings.Contains(s, "scaling") {
		t.Errorf("nil Scaling must be omitted from JSON, got %s", s)
	}
	if strings.Contains(s, "health") {
		t.Errorf("nil Health must be omitted from JSON, got %s", s)
	}
}

func qpsTarget() appsv1alpha1.MetricTarget {
	return appsv1alpha1.MetricTarget{Type: appsv1alpha1.MetricQPS, Target: "1000"}
}

var frozen = time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)

func TestDecide_NoSource_ReturnsNoneExplicitly(t *testing.T) {
	// 无指标源必须显式返回，而不是拿当前副本数冒充信号（修复前的 bug）
	e := NewEngine()
	d := e.Decide(context.Background(), newApp(5, 2, 20, 120, qpsTarget()), func() time.Time { return frozen })
	if d.Action != ActionNone {
		t.Fatalf("want None, got %s", d.Action)
	}
	if d.Reason == "" {
		t.Fatal("reason should explain why (no metrics source), got empty")
	}
}

func TestDecide_HysteresisBand(t *testing.T) {
	tests := []struct {
		name    string
		current int32
		signal  int32 // QPS 信号算出的期望副本
		want    Action
		wantTo  int32
	}{
		// 迟滞带只挡缩容：扩容差 1 也直通（压测实证，见 Decide 注释）
		{"扩容差 1 直通（迟滞带不抑制扩容）", 10, 11, ActionScaleUp, 11},
		{"扩容差 1 在小副本数上同样直通", 3, 4, ActionScaleUp, 4},
		{"缩容差 1 在带内不动作", 10, 9, ActionNone, 10},
		{"小副本数缩容差 1 也在带内", 4, 3, ActionNone, 4},
		{"差值超带上沿则扩容", 10, 12, ActionScaleUp, 12},
		{"小副本数信号 5 超带扩容", 3, 5, ActionScaleUp, 5},
		{"回落 minReplicas 不受迟滞约束", 3, 2, ActionScaleDown, 2},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			e := NewEngine().WithMetricsSource(fakeSource{vals: map[appsv1alpha1.MetricType]fakeVal{
				appsv1alpha1.MetricQPS: {tc.signal, true},
			}})
			d := e.Decide(context.Background(), newApp(tc.current, 2, 20, 0, qpsTarget()), func() time.Time { return frozen })
			if d.Action != tc.want || d.ToReplicas != tc.wantTo {
				t.Fatalf("want %s->%d, got %s->%d", tc.want, tc.wantTo, d.Action, d.ToReplicas)
			}
		})
	}
}

func TestDecide_CooldownBlocksScaleDownOnly(t *testing.T) {
	// 冷却起点 60s 前，窗口 120s：仍在冷却
	scaledAt := metav1.NewTime(frozen.Add(-60 * time.Second))

	tests := []struct {
		name    string
		signal  int32
		want    Action
		wantTo  int32
		wantMsg string
	}{
		{"冷却期内拒绝缩容", 2, ActionNone, 10, "cooldown"},
		{"冷却期内扩容紧急放行", 18, ActionScaleUp, 18, ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			app := newApp(10, 2, 20, 120, qpsTarget())
			app.Status.LastScalingAt = &scaledAt
			e := NewEngine().WithMetricsSource(fakeSource{vals: map[appsv1alpha1.MetricType]fakeVal{
				appsv1alpha1.MetricQPS: {tc.signal, true},
			}})
			d := e.Decide(context.Background(), app, func() time.Time { return frozen })
			if d.Action != tc.want || d.ToReplicas != tc.wantTo {
				t.Fatalf("want %s->%d, got %s->%d", tc.want, tc.wantTo, d.Action, d.ToReplicas)
			}
			if tc.wantMsg != "" && !contains(d.Reason, tc.wantMsg) {
				t.Fatalf("reason %q should mention %q", d.Reason, tc.wantMsg)
			}
		})
	}

	t.Run("冷却窗口过期后允许缩容", func(t *testing.T) {
		app := newApp(10, 2, 20, 120, qpsTarget())
		expired := metav1.NewTime(frozen.Add(-180 * time.Second))
		app.Status.LastScalingAt = &expired
		e := NewEngine().WithMetricsSource(fakeSource{vals: map[appsv1alpha1.MetricType]fakeVal{
			appsv1alpha1.MetricQPS: {2, true},
		}})
		d := e.Decide(context.Background(), app, func() time.Time { return frozen })
		// 缩容渐进：10 最多一次缩 2 个 → 8
		if d.Action != ActionScaleDown || d.ToReplicas != 8 {
			t.Fatalf("want ScaleDown->8, got %s->%d", d.Action, d.ToReplicas)
		}
	})
}

// TestDecide_ShrinkIsGradual 验证缩容渐进的 ceil 陷阱：
// 错误写法 ceil(current*0.8) 在 current=2/3/4 时会被 ceil 拉回原值，永远缩不动。
func TestDecide_ShrinkIsGradual(t *testing.T) {
	tests := []struct {
		current int32
		wantTo  int32
	}{
		{2, 1},  // ceil(2*0.2)=1 → 2-1=1
		{3, 2},  // ceil(3*0.2)=1 → 3-1=2
		{4, 3},  // ceil(4*0.2)=1 → 4-1=3
		{5, 4},  // ceil(5*0.2)=1 → 5-1=4
		{10, 8}, // ceil(10*0.2)=2 → 10-2=8
	}
	for _, tc := range tests {
		e := NewEngine().WithMetricsSource(fakeSource{vals: map[appsv1alpha1.MetricType]fakeVal{
			appsv1alpha1.MetricQPS: {1, true}, // 信号指向 min
		}})
		d := e.Decide(context.Background(), newApp(tc.current, 1, 20, 0, qpsTarget()), func() time.Time { return frozen })
		if d.Action != ActionScaleDown {
			t.Fatalf("current=%d: want ScaleDown, got %s", tc.current, d.Action)
		}
		if d.ToReplicas != tc.wantTo {
			t.Fatalf("current=%d: want shrink to %d, got %d", tc.current, tc.wantTo, d.ToReplicas)
		}
	}
}

func TestDecide_ClampsToMinMax(t *testing.T) {
	t.Run("扩容不超上限", func(t *testing.T) {
		e := NewEngine().WithMetricsSource(fakeSource{vals: map[appsv1alpha1.MetricType]fakeVal{
			appsv1alpha1.MetricQPS: {100, true},
		}})
		d := e.Decide(context.Background(), newApp(10, 2, 20, 0, qpsTarget()), func() time.Time { return frozen })
		if d.ToReplicas != 20 {
			t.Fatalf("want clamped to 20, got %d", d.ToReplicas)
		}
	})
	t.Run("全信号无数据时保持当前副本", func(t *testing.T) {
		// 这条断言 2026-11-18 翻转。原来写的是"逐步缩回 min（不卡死也不瞬间到底）"，
		// 它把 bug 固化成了预期行为：desired 初值取 minReplicas、弃权就 continue，
		// 于是"没有任何数据"和"负载为零"走出了同一条收敛路径，只是速度慢一点。
		// 集群侧复现见 docs/lab/exp5：六分钟 5→2，事件写 load below targets。
		e := NewEngine().WithMetricsSource(fakeSource{vals: map[appsv1alpha1.MetricType]fakeVal{
			appsv1alpha1.MetricQPS: {0, false}, // 无数据：跳过，不是 0
		}})
		d := e.Decide(context.Background(), newApp(6, 2, 20, 0, qpsTarget()), func() time.Time { return frozen })
		if d.Action != ActionNone || d.ToReplicas != 6 {
			t.Fatalf("want hold 6 replicas, got %s->%d", d.Action, d.ToReplicas)
		}
		if d.ReasonCode != ReasonNoMetricsData {
			t.Fatalf("reason code = %q, want %q", d.ReasonCode, ReasonNoMetricsData)
		}
	})
}

func TestDecide_MultiSignalTakesMax(t *testing.T) {
	// QPS 说 4，错误率说要扩到 12 → 取最紧急者 12
	e := NewEngine().WithMetricsSource(fakeSource{vals: map[appsv1alpha1.MetricType]fakeVal{
		appsv1alpha1.MetricQPS:       {4, true},
		appsv1alpha1.MetricErrorRate: {12, true},
	}})
	app := newApp(10, 2, 20, 0,
		qpsTarget(),
		appsv1alpha1.MetricTarget{Type: appsv1alpha1.MetricErrorRate, Target: "0.01"})
	d := e.Decide(context.Background(), app, func() time.Time { return frozen })
	if d.ToReplicas != 12 {
		t.Fatalf("want max(4,12)=12, got %d", d.ToReplicas)
	}
}

// TestDecide_AllSignalsAbstain_HoldsReplicas 锁住一个真实 bug（2026-11-18 实验发现，
// 集群侧复现见 docs/lab/exp5）：Prometheus 整个挂掉时每个信号都返回 ok=false，
// 旧实现让 desired 停在 minReplicas，稳定窗口一过就按步长一路缩到 min。
// 六分钟把 5 副本缩到 2，而事件写的是 "load below targets"、原因码是 scale_down，
// 和正常缩容完全无法区分——把"查不到"当成了"需求很低"。
func TestDecide_AllSignalsAbstain_HoldsReplicas(t *testing.T) {
	// 稳定窗口与冷却都关掉：旧实现这两道闸都不拦，第一轮就会缩
	app := newApp(5, 1, 10, 0, qpsTarget())
	e := NewEngine().WithMetricsSource(fakeSource{vals: map[appsv1alpha1.MetricType]fakeVal{
		appsv1alpha1.MetricQPS: {0, false},
	}})

	d := e.Decide(context.Background(), app, func() time.Time { return frozen })

	if d.Action != ActionNone || d.ToReplicas != 5 {
		t.Fatalf("all signals abstained must hold 5 replicas, got %s -> %d", d.Action, d.ToReplicas)
	}
	if d.ReasonCode != ReasonNoMetricsData {
		t.Fatalf("reason code = %q, want %q：这个码必须能和正常缩容区分开，否则排障看不出故障",
			d.ReasonCode, ReasonNoMetricsData)
	}
	if !d.BelowTarget.Set {
		t.Fatalf("abstain must clear the stabilization timer (no evidence of a lull), got %+v", d.BelowTarget)
	}
}

// TestDecide_PartialAbstain_StillScales 反向约束：只有一个信号没数据时不能整体停摆，
// 另一个信号知道需求，就照它决策。守卫只该覆盖"全都没有"这一种情况。
func TestDecide_PartialAbstain_StillScales(t *testing.T) {
	e := NewEngine().WithMetricsSource(fakeSource{vals: map[appsv1alpha1.MetricType]fakeVal{
		appsv1alpha1.MetricQPS:       {0, false},
		appsv1alpha1.MetricErrorRate: {8, true},
	}})
	app := newApp(10, 2, 20, 0, qpsTarget(),
		appsv1alpha1.MetricTarget{Type: appsv1alpha1.MetricErrorRate, Target: "0.01"})

	d := e.Decide(context.Background(), app, func() time.Time { return frozen })

	if d.Action != ActionScaleDown || d.ToReplicas != 8 {
		t.Fatalf("one live signal must still drive the decision, want ScaleDown->8, got %s -> %d",
			d.Action, d.ToReplicas)
	}
	if d.ReasonCode == ReasonNoMetricsData {
		t.Fatalf("partial abstain must not be reported as no metrics data")
	}
}

// TestDecide_ZeroHysteresisDisablesBand 验证 0 是"关闭"而不是"没设置"。
// API 层还有一道：该字段曾是 int + omitempty，显式写的 0 会被 mutating webhook
// 从 patch 里删掉、再被 CRD 默认值改回 10（见 api/v1alpha1 的 HysteresisPercent 注释）。
func TestDecide_ZeroHysteresisDisablesBand(t *testing.T) {
	tests := []struct {
		name string
		hyst *int32
		want Action
	}{
		{"显式 0 关闭带宽：差值 1 直接缩", int32Ptr3(0), ActionScaleDown},
		{"未设置走默认 10：差值 1 落在带内不动作", nil, ActionNone},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			app := newApp(10, 2, 20, 0, qpsTarget())
			app.Spec.Scaling.HysteresisPercent = tc.hyst
			e := NewEngine().WithMetricsSource(fakeSource{vals: map[appsv1alpha1.MetricType]fakeVal{
				appsv1alpha1.MetricQPS: {9, true},
			}})
			d := e.Decide(context.Background(), app, func() time.Time { return frozen })
			if d.Action != tc.want {
				t.Fatalf("want %s, got %s -> %d (%s)", tc.want, d.Action, d.ToReplicas, d.Reason)
			}
		})
	}
}

func contains(s, sub string) bool {
	return len(sub) == 0 || (len(s) >= len(sub) && indexOf(s, sub) >= 0)
}

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
