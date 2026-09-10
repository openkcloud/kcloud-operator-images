// ============================================================
// metrics.go: DeviceSample 을 Prometheus 지표로 방출한다
// 상세: 커스텀 레지스트리에 등록해 :9410/metrics 로 노출한다. 샘플이 없으면
//       지표를 내지 않는다 — 0 을 내면 "장치가 있는데 사용률 0" 으로 읽힌다.
//       liveness 만 예외다. 그 0 은 "장치가 죽었다" 는 사실이다.
// 생성일: 2026-08-07
// ============================================================
package main

import (
	"strconv"

	"github.com/prometheus/client_golang/prometheus"
)

var (
	descCoreUtil = prometheus.NewDesc("kcloud_furiosa_core_utilization",
		"PE 코어 사용률(%)", []string{"node", "pci", "device", "core"}, nil)
	descMemUsed = prometheus.NewDesc("kcloud_furiosa_memory_used_bytes",
		"DRAM 사용 바이트", []string{"node", "pci", "device"}, nil)
	descMemTotal = prometheus.NewDesc("kcloud_furiosa_memory_total_bytes",
		"DRAM 전체 바이트", []string{"node", "pci", "device"}, nil)
	descPower = prometheus.NewDesc("kcloud_furiosa_power_watts",
		"장치 전력(W)", []string{"node", "pci", "device"}, nil)
	descTemp = prometheus.NewDesc("kcloud_furiosa_temperature_celsius",
		"장치 온도(°C)", []string{"node", "pci", "device", "sensor"}, nil)
	descAlive = prometheus.NewDesc("kcloud_furiosa_device_alive",
		"장치 liveness(0/1)", []string{"node", "pci", "device"}, nil)
)

// Metrics 는 수집기다. Samples 는 마지막 수집 회차의 스냅샷을 돌려준다.
type Metrics struct {
	Node    string
	Samples func() []DeviceSample
}

// Describe 는 이 수집기가 낼 수 있는 지표 종류를 알린다.
func (m *Metrics) Describe(ch chan<- *prometheus.Desc) {
	ch <- descCoreUtil
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
				c.UsagePercent, m.Node, s.PCI, s.Device, itoa(c.Core))
		}
		if s.DramTotalBytes > 0 {
			ch <- prometheus.MustNewConstMetric(descMemUsed, prometheus.GaugeValue,
				float64(s.DramInUseBytes), m.Node, s.PCI, s.Device)
			ch <- prometheus.MustNewConstMetric(descMemTotal, prometheus.GaugeValue,
				float64(s.DramTotalBytes), m.Node, s.PCI, s.Device)
		}
		if s.PowerWatts > 0 {
			ch <- prometheus.MustNewConstMetric(descPower, prometheus.GaugeValue,
				s.PowerWatts, m.Node, s.PCI, s.Device)
		}
		if s.TempSocPeak > 0 {
			ch <- prometheus.MustNewConstMetric(descTemp, prometheus.GaugeValue,
				s.TempSocPeak, m.Node, s.PCI, s.Device, "soc_peak")
		}
		if s.TempAmbient > 0 {
			ch <- prometheus.MustNewConstMetric(descTemp, prometheus.GaugeValue,
				s.TempAmbient, m.Node, s.PCI, s.Device, "ambient")
		}
		alive := 0.0
		if s.Alive {
			alive = 1
		}
		ch <- prometheus.MustNewConstMetric(descAlive, prometheus.GaugeValue,
			alive, m.Node, s.PCI, s.Device)
	}
}

// itoa 는 코어 번호를 라벨 문자열로 만든다.
func itoa(v uint32) string {
	return strconv.FormatUint(uint64(v), 10)
}
