// ============================================================
// metrics_test.go: 방출 지표 이름·라벨·값 시험
// 생성일: 2026-08-07 | 수정일: 2026-10-11
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
			PCI: "0000:27:00.0", Device: "npu0", UUID: "C0413086-0709-4307-884B-4E4E4A414C4C",
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
kcloud_furiosa_core_utilization{core="0",device="npu0",node="rngd-1",pci="0000:27:00.0",uuid="C0413086-0709-4307-884B-4E4E4A414C4C"} 42.5
`
	if err := testutil.GatherAndCompare(reg, strings.NewReader(want), "kcloud_furiosa_core_utilization"); err != nil {
		t.Error(err)
	}

	wantMem := `
# HELP kcloud_furiosa_memory_used_bytes DRAM 사용 바이트
# TYPE kcloud_furiosa_memory_used_bytes gauge
kcloud_furiosa_memory_used_bytes{device="npu0",node="rngd-1",pci="0000:27:00.0",uuid="C0413086-0709-4307-884B-4E4E4A414C4C"} 25
`
	if err := testutil.GatherAndCompare(reg, strings.NewReader(wantMem), "kcloud_furiosa_memory_used_bytes"); err != nil {
		t.Error(err)
	}

	wantMemTotal := `
# HELP kcloud_furiosa_memory_total_bytes DRAM 전체 바이트
# TYPE kcloud_furiosa_memory_total_bytes gauge
kcloud_furiosa_memory_total_bytes{device="npu0",node="rngd-1",pci="0000:27:00.0",uuid="C0413086-0709-4307-884B-4E4E4A414C4C"} 100
`
	if err := testutil.GatherAndCompare(reg, strings.NewReader(wantMemTotal), "kcloud_furiosa_memory_total_bytes"); err != nil {
		t.Error(err)
	}

	wantPower := `
# HELP kcloud_furiosa_power_watts 장치 전력(W)
# TYPE kcloud_furiosa_power_watts gauge
kcloud_furiosa_power_watts{device="npu0",node="rngd-1",pci="0000:27:00.0",uuid="C0413086-0709-4307-884B-4E4E4A414C4C"} 91.5
`
	if err := testutil.GatherAndCompare(reg, strings.NewReader(wantPower), "kcloud_furiosa_power_watts"); err != nil {
		t.Error(err)
	}

	wantTemp := `
# HELP kcloud_furiosa_temperature_celsius 장치 온도(°C)
# TYPE kcloud_furiosa_temperature_celsius gauge
kcloud_furiosa_temperature_celsius{device="npu0",node="rngd-1",pci="0000:27:00.0",sensor="ambient",uuid="C0413086-0709-4307-884B-4E4E4A414C4C"} 33
kcloud_furiosa_temperature_celsius{device="npu0",node="rngd-1",pci="0000:27:00.0",sensor="soc_peak",uuid="C0413086-0709-4307-884B-4E4E4A414C4C"} 61
`
	if err := testutil.GatherAndCompare(reg, strings.NewReader(wantTemp), "kcloud_furiosa_temperature_celsius"); err != nil {
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
kcloud_furiosa_device_alive{device="npu0",node="rngd-1",pci="0000:27:00.0",uuid=""} 0
`
	if err := testutil.GatherAndCompare(reg, strings.NewReader(want), "kcloud_furiosa_device_alive"); err != nil {
		t.Error(err)
	}
}

func TestMetricsEmitsCoreClock(t *testing.T) {
	m := &Metrics{Node: "rngd-1", Samples: func() []DeviceSample {
		return []DeviceSample{{
			PCI: "0000:27:00.0", Device: "npu0", UUID: "UUID-A",
			CoreClocks: []CoreClock{{Core: 0, MHz: 2000}, {Core: 1, MHz: 1500}},
		}}
	}}
	reg := prometheus.NewRegistry()
	reg.MustRegister(m)

	want := `
# HELP kcloud_furiosa_core_clock_mhz PE 코어 동작 주파수(MHz)
# TYPE kcloud_furiosa_core_clock_mhz gauge
kcloud_furiosa_core_clock_mhz{core="0",device="npu0",node="rngd-1",pci="0000:27:00.0",uuid="UUID-A"} 2000
kcloud_furiosa_core_clock_mhz{core="1",device="npu0",node="rngd-1",pci="0000:27:00.0",uuid="UUID-A"} 1500
`
	if err := testutil.GatherAndCompare(reg, strings.NewReader(want), "kcloud_furiosa_core_clock_mhz"); err != nil {
		t.Error(err)
	}
}

func TestMetricsOmitsCoreClockWhenUnread(t *testing.T) {
	m := &Metrics{Node: "rngd-1", Samples: func() []DeviceSample {
		return []DeviceSample{{PCI: "0000:27:00.0", Device: "npu0", UUID: "UUID-A"}}
	}}
	reg := prometheus.NewRegistry()
	reg.MustRegister(m)

	if err := testutil.GatherAndCompare(reg, strings.NewReader(""), "kcloud_furiosa_core_clock_mhz"); err != nil {
		t.Error(err)
	}
}

func TestMetricsEmitsGovernor(t *testing.T) {
	m := &Metrics{Node: "rngd-1", Samples: func() []DeviceSample {
		return []DeviceSample{{
			PCI: "0000:27:00.0", Device: "npu0", UUID: "UUID-A", Governor: "performance",
		}}
	}}
	reg := prometheus.NewRegistry()
	reg.MustRegister(m)

	want := `
# HELP kcloud_furiosa_governor 활성 전력 모드. 활성 모드만 1 로 낸다
# TYPE kcloud_furiosa_governor gauge
kcloud_furiosa_governor{device="npu0",mode="performance",node="rngd-1",pci="0000:27:00.0",uuid="UUID-A"} 1
`
	if err := testutil.GatherAndCompare(reg, strings.NewReader(want), "kcloud_furiosa_governor"); err != nil {
		t.Error(err)
	}
}

func TestMetricsOmitsGovernorWhenUnread(t *testing.T) {
	m := &Metrics{Node: "rngd-1", Samples: func() []DeviceSample {
		return []DeviceSample{{PCI: "0000:27:00.0", Device: "npu0", UUID: "UUID-A"}}
	}}
	reg := prometheus.NewRegistry()
	reg.MustRegister(m)

	if err := testutil.GatherAndCompare(reg, strings.NewReader(""), "kcloud_furiosa_governor"); err != nil {
		t.Error(err)
	}
}

func TestMetricsEmitsThrottleReason(t *testing.T) {
	m := &Metrics{Node: "rngd-1", Samples: func() []DeviceSample {
		return []DeviceSample{{
			PCI: "0000:27:00.0", Device: "npu0", UUID: "UUID-A",
			ThrottleReason: 2, ThrottleValid: true,
		}}
	}}
	reg := prometheus.NewRegistry()
	reg.MustRegister(m)

	want := `
# HELP kcloud_furiosa_throttle_reason 쓰로틀 사유 비트마스크. 0 이 정상. 비트 정의는 노드의 throttle_reason_list 에 있다
# TYPE kcloud_furiosa_throttle_reason gauge
kcloud_furiosa_throttle_reason{device="npu0",node="rngd-1",pci="0000:27:00.0",uuid="UUID-A"} 2
`
	if err := testutil.GatherAndCompare(reg, strings.NewReader(want), "kcloud_furiosa_throttle_reason"); err != nil {
		t.Error(err)
	}
}

func TestMetricsEmitsThrottleReasonZeroWhenValid(t *testing.T) {
	m := &Metrics{Node: "rngd-1", Samples: func() []DeviceSample {
		return []DeviceSample{{
			PCI: "0000:27:00.0", Device: "npu0", UUID: "UUID-A",
			ThrottleReason: 0, ThrottleValid: true,
		}}
	}}
	reg := prometheus.NewRegistry()
	reg.MustRegister(m)

	want := `
# HELP kcloud_furiosa_throttle_reason 쓰로틀 사유 비트마스크. 0 이 정상. 비트 정의는 노드의 throttle_reason_list 에 있다
# TYPE kcloud_furiosa_throttle_reason gauge
kcloud_furiosa_throttle_reason{device="npu0",node="rngd-1",pci="0000:27:00.0",uuid="UUID-A"} 0
`
	if err := testutil.GatherAndCompare(reg, strings.NewReader(want), "kcloud_furiosa_throttle_reason"); err != nil {
		t.Error(err)
	}
}

func TestMetricsOmitsThrottleReasonWhenUnread(t *testing.T) {
	m := &Metrics{Node: "rngd-1", Samples: func() []DeviceSample {
		return []DeviceSample{{
			PCI: "0000:27:00.0", Device: "npu0", UUID: "UUID-A", ThrottleValid: false,
		}}
	}}
	reg := prometheus.NewRegistry()
	reg.MustRegister(m)

	if err := testutil.GatherAndCompare(reg, strings.NewReader(""), "kcloud_furiosa_throttle_reason"); err != nil {
		t.Error(err)
	}
}

func TestMetricsEmitsThrottlingEventsTotal(t *testing.T) {
	m := &Metrics{Node: "rngd-1", Samples: func() []DeviceSample {
		return []DeviceSample{{
			PCI: "0000:27:00.0", Device: "npu0", UUID: "UUID-A",
			ThrottleValid: true, ThrottleEvents: 3,
		}}
	}}
	reg := prometheus.NewRegistry()
	reg.MustRegister(m)

	want := `
# HELP kcloud_furiosa_throttling_events_total 쓰로틀이 시작된 횟수. 사유 비트가 0 에서 0 이 아닌 값으로 바뀐 때 1 올린다
# TYPE kcloud_furiosa_throttling_events_total counter
kcloud_furiosa_throttling_events_total{device="npu0",node="rngd-1",pci="0000:27:00.0",uuid="UUID-A"} 3
`
	if err := testutil.GatherAndCompare(reg, strings.NewReader(want), "kcloud_furiosa_throttling_events_total"); err != nil {
		t.Error(err)
	}
}
