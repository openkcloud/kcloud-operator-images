// ============================================================
// metrics.go: DeviceSample 을 Prometheus 지표로 방출한다(공식 furiosa-metrics-exporter 이름·라벨)
// 상세: 지표 이름·라벨은 furiosa-ai/furiosa-metrics-exporter(Apache-2.0)와 같다. 공식에 없는 governor·
// throttle_reason 은 같은 접두로 둔다. 읽지 못한 값은 내지 않는다 — 0 을 내면 사실이 아닌 값을 그린다.
// 생성일: 2026-08-07 | 수정일: 2026-10-13
// ============================================================
package main

import (
	"fmt"
	"strconv"

	"github.com/prometheus/client_golang/prometheus"
)

// 공통 라벨 순서. pod·namespace·container 는 공식 기본 설정(--kube-resources-label=false)에서
// 방출되지 않으므로 두지 않는다.
var baseLabels = []string{"arch", "core", "device", "uuid", "pci_bus_id", "firmware_version", "driver_version", "hostname"}

func desc(name, help string, extra ...string) *prometheus.Desc {
	return prometheus.NewDesc(name, help, append(append([]string{}, baseLabels...), extra...), nil)
}

var (
	descCoreUtil       = desc("furiosa_npu_core_utilization", "PE 코어 사용률(%)")
	descCoreFreq       = desc("furiosa_npu_core_frequency", "PE 코어 동작 주파수(MHz)")
	descGovernor       = desc("furiosa_npu_governor", "활성 전력 모드. 활성 모드만 1 로 낸다", "mode")
	descThrottleReason = desc("furiosa_npu_throttle_reason", "쓰로틀 사유 비트마스크. 0 이 정상. 비트 정의는 노드의 throttle_reason_list 에 있다")
	descDramUsage      = desc("furiosa_npu_dram_usage", "DRAM 사용 바이트(공유 영역 포함)")
	descDramTotal      = desc("furiosa_npu_dram_total", "DRAM 전체 바이트(공유 영역 포함)")
	descPower          = desc("furiosa_npu_hw_power", "장치 전력(W)", "label")
	descTemp           = desc("furiosa_npu_hw_temperature", "장치 온도(°C)", "label")
	descAlive          = desc("furiosa_npu_alive", "장치 liveness(0/1)")
	descTotalCycle     = desc("furiosa_npu_total_cycle_count", "PE 코어 누적 사이클 수")
	descTaskCycle      = desc("furiosa_npu_task_execution_cycle", "PE 코어가 작업을 실행한 누적 사이클 수")

	descThrottleEvents = desc("furiosa_npu_throttling_events_count", "최근 300초 동안 쓰로틀 사유 비트가 바뀐 횟수", "label")
)

// Metrics 는 수집기다. Samples 는 마지막 수집 회차의 스냅샷을 돌려준다. Node 는 hostname 라벨 값이다.
// Throttle 은 장치(UUID)의 사유 비트별 최근 변화 횟수이고, 한 번도 읽지 못한 장치는 ok=false 다.
type Metrics struct {
	Node     string
	Samples  func() []DeviceSample
	Throttle func(uuid string) (counts map[string]float64, ok bool)
}

// Describe 는 이 수집기가 낼 수 있는 지표 종류를 알린다.
func (m *Metrics) Describe(ch chan<- *prometheus.Desc) {
	for _, d := range []*prometheus.Desc{descCoreUtil, descCoreFreq, descGovernor, descThrottleReason,
		descDramUsage, descDramTotal, descPower, descTemp, descAlive, descTotalCycle, descTaskCycle, descThrottleEvents} {
		ch <- d
	}
}

// labels 는 baseLabels 순서의 값이다. core 는 코어 단위 지표면 코어 번호, 장치 단위 지표면 코어 범위다.
func (m *Metrics) labels(s DeviceSample, core string, extra ...string) []string {
	return append([]string{s.Arch, core, s.Name, s.UUID, s.PCI, s.FirmwareVersion, s.DriverVersion, m.Node}, extra...)
}

// Collect 는 스크레이프 시점의 스냅샷을 지표로 옮긴다.
func (m *Metrics) Collect(ch chan<- prometheus.Metric) {
	gauge := func(d *prometheus.Desc, v float64, lv []string) {
		ch <- prometheus.MustNewConstMetric(d, prometheus.GaugeValue, v, lv...)
	}
	counter := func(d *prometheus.Desc, v float64, lv []string) {
		ch <- prometheus.MustNewConstMetric(d, prometheus.CounterValue, v, lv...)
	}
	for _, s := range m.Samples() {
		dev := coreRange(s.CoreNum)
		for _, c := range s.Cores {
			gauge(descCoreUtil, c.UsagePercent, m.labels(s, itoa(c.Core)))
		}
		for _, c := range s.CoreClocks {
			gauge(descCoreFreq, float64(c.MHz), m.labels(s, itoa(c.Core)))
		}
		for _, c := range s.Cycles {
			counter(descTotalCycle, float64(c.Total), m.labels(s, itoa(c.Core)))
			counter(descTaskCycle, float64(c.TaskExec), m.labels(s, itoa(c.Core)))
		}
		// 비활성 모드 행은 내지 않는다. 값에 문자열을 담을 수 없어 활성 모드를 라벨로 세운다.
		if s.Governor != "" {
			gauge(descGovernor, 1, m.labels(s, dev, s.Governor))
		}
		if s.ThrottleValid {
			gauge(descThrottleReason, float64(s.ThrottleReason), m.labels(s, dev))
		}
		if m.Throttle != nil {
			if c, ok := m.Throttle(s.UUID); ok {
				for _, l := range throttleLabels {
					gauge(descThrottleEvents, c[l.name], m.labels(s, dev, l.name))
				}
			}
		}
		if s.DramTotalBytes > 0 {
			gauge(descDramUsage, float64(s.DramInUseBytes), m.labels(s, dev))
			gauge(descDramTotal, float64(s.DramTotalBytes), m.labels(s, dev))
		}
		if s.PowerWatts > 0 {
			gauge(descPower, s.PowerWatts, m.labels(s, dev, "rms"))
		}
		if s.TempSocPeak > 0 {
			gauge(descTemp, s.TempSocPeak, m.labels(s, dev, "peak"))
		}
		if s.TempAmbient > 0 {
			gauge(descTemp, s.TempAmbient, m.labels(s, dev, "ambient"))
		}
		if s.AliveValid {
			alive := 0.0
			if s.Alive {
				alive = 1
			}
			gauge(descAlive, alive, m.labels(s, dev))
		}
	}
}

// coreRange 는 장치 단위 지표의 core 라벨이다. 공식과 같은 형식("0-<마지막 코어>", 코어가 하나면 "0")을 코어 수로 만든다.
func coreRange(n uint32) string {
	if n <= 1 {
		return "0"
	}
	return fmt.Sprintf("0-%d", n-1)
}

// itoa 는 코어 번호를 라벨 문자열로 만든다.
func itoa(v uint32) string {
	return strconv.FormatUint(uint64(v), 10)
}
