// ============================================================
// metrics.go: DeviceSample 을 Prometheus 지표로 방출한다
// 상세: 커스텀 레지스트리로 :9410/metrics 에 노출한다. 샘플이 없으면 지표를 내지 않는다 —
// 0 을 내면 "사용률 0" 으로 읽힌다. liveness 만 예외다, 그 0 은 "장치가 죽었다" 는 사실이다.
// 생성일: 2026-08-07 | 수정일: 2026-10-11
// ============================================================
package main

import (
	"strconv"

	"github.com/prometheus/client_golang/prometheus"
)

var (
	descCoreUtil = prometheus.NewDesc("kcloud_furiosa_core_utilization",
		"PE 코어 사용률(%)", []string{"node", "pci", "device", "uuid", "core"}, nil)
	descCoreClock = prometheus.NewDesc("kcloud_furiosa_core_clock_mhz",
		"PE 코어 동작 주파수(MHz)", []string{"node", "pci", "device", "uuid", "core"}, nil)
	descGovernor = prometheus.NewDesc("kcloud_furiosa_governor",
		"활성 전력 모드. 활성 모드만 1 로 낸다", []string{"node", "pci", "device", "uuid", "mode"}, nil)
	descThrottleReason = prometheus.NewDesc("kcloud_furiosa_throttle_reason",
		"쓰로틀 사유 비트마스크. 0 이 정상. 비트 정의는 노드의 throttle_reason_list 에 있다",
		[]string{"node", "pci", "device", "uuid"}, nil)
	descThrottleEvents = prometheus.NewDesc("kcloud_furiosa_throttling_events_total",
		"쓰로틀이 시작된 횟수. 사유 비트가 0 에서 0 이 아닌 값으로 바뀐 때 1 올린다",
		[]string{"node", "pci", "device", "uuid"}, nil)
	descMemUsed = prometheus.NewDesc("kcloud_furiosa_memory_used_bytes",
		"DRAM 사용 바이트", []string{"node", "pci", "device", "uuid"}, nil)
	descMemTotal = prometheus.NewDesc("kcloud_furiosa_memory_total_bytes",
		"DRAM 전체 바이트", []string{"node", "pci", "device", "uuid"}, nil)
	descPower = prometheus.NewDesc("kcloud_furiosa_power_watts",
		"장치 전력(W)", []string{"node", "pci", "device", "uuid"}, nil)
	descTemp = prometheus.NewDesc("kcloud_furiosa_temperature_celsius",
		"장치 온도(°C)", []string{"node", "pci", "device", "uuid", "sensor"}, nil)
	descAlive = prometheus.NewDesc("kcloud_furiosa_device_alive",
		"장치 liveness(0/1)", []string{"node", "pci", "device", "uuid"}, nil)
)

// Metrics 는 수집기다. Samples 는 마지막 수집 회차의 스냅샷을 돌려준다.
type Metrics struct {
	Node    string
	Samples func() []DeviceSample
}

// Describe 는 이 수집기가 낼 수 있는 지표 종류를 알린다.
func (m *Metrics) Describe(ch chan<- *prometheus.Desc) {
	ch <- descCoreUtil
	ch <- descCoreClock
	ch <- descGovernor
	ch <- descThrottleReason
	ch <- descThrottleEvents
	ch <- descMemUsed
	ch <- descMemTotal
	ch <- descPower
	ch <- descTemp
	ch <- descAlive
}

// Collect 는 스크레이프 시점의 스냅샷을 지표로 옮긴다.
func (m *Metrics) Collect(ch chan<- prometheus.Metric) {
	for _, s := range m.Samples() {
		for _, c := range s.Cores {
			ch <- prometheus.MustNewConstMetric(descCoreUtil, prometheus.GaugeValue,
				c.UsagePercent, m.Node, s.PCI, s.Device, s.UUID, itoa(c.Core))
		}
		for _, c := range s.CoreClocks {
			ch <- prometheus.MustNewConstMetric(descCoreClock, prometheus.GaugeValue,
				float64(c.MHz), m.Node, s.PCI, s.Device, s.UUID, itoa(c.Core))
		}
		// 비활성 모드 행은 내지 않는다. 값에 문자열을 담을 수 없어 활성 모드를 라벨로 세운다.
		if s.Governor != "" {
			ch <- prometheus.MustNewConstMetric(descGovernor, prometheus.GaugeValue,
				1, m.Node, s.PCI, s.Device, s.UUID, s.Governor)
		}
		if s.ThrottleValid {
			ch <- prometheus.MustNewConstMetric(descThrottleReason, prometheus.GaugeValue,
				float64(s.ThrottleReason), m.Node, s.PCI, s.Device, s.UUID)
			ch <- prometheus.MustNewConstMetric(descThrottleEvents, prometheus.CounterValue,
				float64(s.ThrottleEvents), m.Node, s.PCI, s.Device, s.UUID)
		}
		if s.DramTotalBytes > 0 {
			ch <- prometheus.MustNewConstMetric(descMemUsed, prometheus.GaugeValue,
				float64(s.DramInUseBytes), m.Node, s.PCI, s.Device, s.UUID)
			ch <- prometheus.MustNewConstMetric(descMemTotal, prometheus.GaugeValue,
				float64(s.DramTotalBytes), m.Node, s.PCI, s.Device, s.UUID)
		}
		if s.PowerWatts > 0 {
			ch <- prometheus.MustNewConstMetric(descPower, prometheus.GaugeValue,
				s.PowerWatts, m.Node, s.PCI, s.Device, s.UUID)
		}
		if s.TempSocPeak > 0 {
			ch <- prometheus.MustNewConstMetric(descTemp, prometheus.GaugeValue,
				s.TempSocPeak, m.Node, s.PCI, s.Device, s.UUID, "soc_peak")
		}
		if s.TempAmbient > 0 {
			ch <- prometheus.MustNewConstMetric(descTemp, prometheus.GaugeValue,
				s.TempAmbient, m.Node, s.PCI, s.Device, s.UUID, "ambient")
		}
		alive := 0.0
		if s.Alive {
			alive = 1
		}
		ch <- prometheus.MustNewConstMetric(descAlive, prometheus.GaugeValue,
			alive, m.Node, s.PCI, s.Device, s.UUID)
	}
}

// itoa 는 코어 번호를 라벨 문자열로 만든다.
func itoa(v uint32) string {
	return strconv.FormatUint(uint64(v), 10)
}
