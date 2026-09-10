// ============================================================
// metrics_test.go: 방출 지표 이름·라벨·값 시험
// 생성일: 2026-08-07
// ============================================================
package main

import (
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestMetricsEmitsCoreAndMemory(t *testing.T) {
	m := &Metrics{Node: "rngd-1", Samples: func() []DeviceSample {
		return []DeviceSample{{
			PCI: "0000:27:00.0", Device: "npu0",
			Cores:          []CoreReading{{Core: 0, UsagePercent: 42.5}},
			DramTotalBytes: 100, DramInUseBytes: 25,
			PowerWatts: 91.5, TempSocPeak: 61, TempAmbient: 33, Alive: true,
		}}
	}}
	reg := prometheus.NewRegistry()
	reg.MustRegister(m)

	want := `
# HELP kcloud_furiosa_core_utilization PE 코어 사용률(%)
# TYPE kcloud_furiosa_core_utilization gauge
kcloud_furiosa_core_utilization{core="0",device="npu0",node="rngd-1",pci="0000:27:00.0"} 42.5
`
	if err := testutil.GatherAndCompare(reg, strings.NewReader(want), "kcloud_furiosa_core_utilization"); err != nil {
		t.Error(err)
	}

	wantMem := `
# HELP kcloud_furiosa_memory_used_bytes DRAM 사용 바이트
# TYPE kcloud_furiosa_memory_used_bytes gauge
kcloud_furiosa_memory_used_bytes{device="npu0",node="rngd-1",pci="0000:27:00.0"} 25
`
	if err := testutil.GatherAndCompare(reg, strings.NewReader(wantMem), "kcloud_furiosa_memory_used_bytes"); err != nil {
		t.Error(err)
	}
}

// 샘플이 0건이면 지표를 하나도 내지 않아야 한다. 0 을 내면 "장치가 있는데
// 사용률이 0" 으로 읽혀 없는 사실이 그려진다.
func TestMetricsEmitsNothingWhenNoSamples(t *testing.T) {
	m := &Metrics{Node: "rngd-1", Samples: func() []DeviceSample { return nil }}
	reg := prometheus.NewRegistry()
	reg.MustRegister(m)

	if got := testutil.CollectAndCount(m); got != 0 {
		t.Errorf("지표 수 = %d, 기대 0", got)
	}
}

// liveness 는 0 도 의미가 있다 — 장치가 죽었다는 사실이다. 그래서 alive 는
// 다른 지표와 달리 값이 0 이어도 반드시 방출한다.
func TestMetricsEmitsAliveZero(t *testing.T) {
	m := &Metrics{Node: "rngd-1", Samples: func() []DeviceSample {
		return []DeviceSample{{PCI: "0000:27:00.0", Device: "npu0", Alive: false}}
	}}
	reg := prometheus.NewRegistry()
	reg.MustRegister(m)

	want := `
# HELP kcloud_furiosa_device_alive 장치 liveness(0/1)
# TYPE kcloud_furiosa_device_alive gauge
kcloud_furiosa_device_alive{device="npu0",node="rngd-1",pci="0000:27:00.0"} 0
`
	if err := testutil.GatherAndCompare(reg, strings.NewReader(want), "kcloud_furiosa_device_alive"); err != nil {
		t.Error(err)
	}
}
