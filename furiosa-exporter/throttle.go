// ============================================================
// throttle.go: 쓰로틀 사유 비트별 변화 계수(최근 창 안의 횟수)
// 상세: 공식 furiosa-metrics-exporter(Apache-2.0)의 집계 방식을 따른다 — 1초마다 읽은 사유 비트가 이전 값과 다르면
// 비트별로 1 을 세어 창(300초) 안의 개수를 gauge 로 낸다. 마지막 관측값은 창과 따로 쥔다(공식은 창이 비면 기준점을 잃는다).
// 생성일: 2026-10-13 | 수정일: 2026-10-13
// ============================================================
package main

import (
	"sync"
	"time"
)

// throttleLabels 의 비트 정의는 furiosa-smi-go binding 의 ThrottleReason 값이다.
var throttleLabels = []struct {
	name string
	bit  uint32
}{
	{"idle", 1 << 0}, {"thermal_slowdown", 1 << 1}, {"app_power_cap", 1 << 2}, {"app_clock_cap", 1 << 3},
	{"hw_clock_cap", 1 << 4}, {"hw_bus_limit", 1 << 5}, {"hw_power_cap", 1 << 6}, {"other_reason", 1 << 7},
}

// throttleChange 는 사유가 바뀐 시각과 그때 값이 달라진 비트 이름이다.
type throttleChange struct {
	at      time.Time
	changed []string
}

// throttleDevice 는 장치 하나의 마지막 관측값과 창 안의 변화다. 마지막 관측값은 변화 기록과 따로
// 쥔다 — 변화가 창에서 밀려나도 비교 기준은 남아야 오래 이어진 정상 구간 뒤의 첫 변화를 센다.
type throttleDevice struct {
	last    uint32
	changes []throttleChange
}

// throttleWindow 는 장치(UUID)별 사유 변화 기록이다. 첫 관측은 기준점이라 변화로 세지 않는다.
type throttleWindow struct {
	mu      sync.Mutex
	window  time.Duration
	devices map[string]*throttleDevice
}

func newThrottleWindow(window time.Duration) *throttleWindow {
	return &throttleWindow{window: window, devices: map[string]*throttleDevice{}}
}

func (w *throttleWindow) observe(uuid string, reason uint32, now time.Time) {
	w.mu.Lock()
	defer w.mu.Unlock()
	d, seen := w.devices[uuid]
	if !seen {
		w.devices[uuid] = &throttleDevice{last: reason}
		return
	}
	if d.last != reason {
		var changed []string
		for _, l := range throttleLabels {
			if reason&l.bit != d.last&l.bit {
				changed = append(changed, l.name)
			}
		}
		d.changes = append(d.changes, throttleChange{at: now, changed: changed})
		d.last = reason
	}
	cut := now.Add(-w.window)
	i := 0
	for i < len(d.changes) && d.changes[i].at.Before(cut) {
		i++
	}
	d.changes = d.changes[i:]
}

// counts 는 창 안의 비트별 변화 횟수다. 한 번도 관측하지 않은 장치는 ok=false.
func (w *throttleWindow) counts(uuid string, now time.Time) (map[string]float64, bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	d, ok := w.devices[uuid]
	if !ok {
		return nil, false
	}
	out := make(map[string]float64, len(throttleLabels))
	for _, l := range throttleLabels {
		out[l.name] = 0
	}
	cut := now.Add(-w.window)
	for _, c := range d.changes {
		if c.at.Before(cut) {
			continue
		}
		for _, n := range c.changed {
			out[n]++
		}
	}
	return out, true
}
