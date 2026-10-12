// ============================================================
// throttle_test.go: 쓰로틀 사유 비트별 변화 계수(300초 창)와 1초 표본 시험
// 생성일: 2026-10-13 | 수정일: 2026-10-13
// ============================================================
package main

import (
	"errors"
	"io"
	"log"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

var t0 = time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC)

// 첫 관측은 기준점이라 세지 않는다. 같은 값이 이어지면 세지 않는다. 비트가 켜지고 꺼지는 양방향을 센다.
func TestThrottleWindowCountsBitChangesBothWays(t *testing.T) {
	w := newThrottleWindow(300 * time.Second)
	for i, r := range []uint32{0, 0, 2, 2, 0, 2 | 4} {
		w.observe("U", r, t0.Add(time.Duration(i)*time.Second))
	}
	got, ok := w.counts("U", t0.Add(6*time.Second))
	if !ok {
		t.Fatal("관측한 장치인데 ok=false")
	}
	// thermal_slowdown(1<<1): 0→2, 2→0, 0→6 세 번. app_power_cap(1<<2): 0→6 한 번.
	if got["thermal_slowdown"] != 3 || got["app_power_cap"] != 1 || got["idle"] != 0 {
		t.Errorf("counts=%v", got)
	}
	if len(got) != 8 {
		t.Errorf("라벨 %d개, 8 기대", len(got))
	}
}

// 기동 시점에 이미 켜져 있던 비트는 변화가 아니다. 이전 값이 없는 첫 관측을 0 으로 취급하면 여기서 센다.
func TestThrottleWindowFirstObservationIsBaseline(t *testing.T) {
	w := newThrottleWindow(300 * time.Second)
	w.observe("U", 2, t0)
	w.observe("U", 2, t0.Add(time.Second))
	got, _ := w.counts("U", t0.Add(2*time.Second))
	if got["thermal_slowdown"] != 0 {
		t.Errorf("기동 시점부터 켜진 비트를 변화로 셌다: %v", got)
	}
}

// 변화 없이 창보다 오래 지속된 뒤의 첫 변화도 센다. 기록이 창에서 밀려나며 기준점까지 잃으면
// 그 변화를 첫 관측으로 오인해 놓친다.
func TestThrottleWindowCountsChangeAfterLongSteadyState(t *testing.T) {
	w := newThrottleWindow(300 * time.Second)
	w.observe("U", 0, t0)
	w.observe("U", 0, t0.Add(400*time.Second))
	w.observe("U", 2, t0.Add(401*time.Second))
	got, _ := w.counts("U", t0.Add(402*time.Second))
	if got["thermal_slowdown"] != 1 {
		t.Errorf("긴 정상 구간 뒤의 첫 변화를 놓쳤다: %v", got)
	}
}

// 300초가 지난 변화는 창에서 빠진다.
func TestThrottleWindowDropsOldEvents(t *testing.T) {
	w := newThrottleWindow(300 * time.Second)
	w.observe("U", 0, t0)
	w.observe("U", 2, t0.Add(time.Second))
	got, _ := w.counts("U", t0.Add(302*time.Second))
	if got["thermal_slowdown"] != 0 {
		t.Errorf("창 밖 변화를 셌다: %v", got)
	}
}

func TestThrottleWindowUnknownDevice(t *testing.T) {
	if _, ok := newThrottleWindow(time.Minute).counts("X", t0); ok {
		t.Error("관측한 적 없는 장치인데 ok=true")
	}
}

func TestMetricsThrottlingEventsCount(t *testing.T) {
	s := sample()
	m := &Metrics{Node: "rngd-1", Samples: func() []DeviceSample { return []DeviceSample{s} },
		Throttle: func(string) (map[string]float64, bool) {
			c := map[string]float64{}
			for _, l := range throttleLabels {
				c[l.name] = 0
			}
			c["thermal_slowdown"] = 3
			return c, true
		}}
	reg := prometheus.NewRegistry()
	reg.MustRegister(m)
	want := `
# HELP furiosa_npu_throttling_events_count 최근 300초 동안 쓰로틀 사유 비트가 바뀐 횟수
# TYPE furiosa_npu_throttling_events_count gauge
furiosa_npu_throttling_events_count{` + lbl + `,core="0-7",label="app_clock_cap"} 0
furiosa_npu_throttling_events_count{` + lbl + `,core="0-7",label="app_power_cap"} 0
furiosa_npu_throttling_events_count{` + lbl + `,core="0-7",label="hw_bus_limit"} 0
furiosa_npu_throttling_events_count{` + lbl + `,core="0-7",label="hw_clock_cap"} 0
furiosa_npu_throttling_events_count{` + lbl + `,core="0-7",label="hw_power_cap"} 0
furiosa_npu_throttling_events_count{` + lbl + `,core="0-7",label="idle"} 0
furiosa_npu_throttling_events_count{` + lbl + `,core="0-7",label="other_reason"} 0
furiosa_npu_throttling_events_count{` + lbl + `,core="0-7",label="thermal_slowdown"} 3
`
	if err := testutil.GatherAndCompare(reg, strings.NewReader(sortLabels(want)), "furiosa_npu_throttling_events_count"); err != nil {
		t.Error(err)
	}
}

// 창에 기록이 없는 장치(아직 한 번도 읽지 못함)와 창이 연결되지 않은 수집기는 지표를 내지 않는다 —
// 0 을 내면 "변화 없음" 이라는 사실이 아닌 값을 그린다.
func TestMetricsThrottlingEventsOmittedWhenUnobserved(t *testing.T) {
	s := sample()
	for name, fn := range map[string]func(string) (map[string]float64, bool){
		"미관측": func(string) (map[string]float64, bool) { return nil, false },
		"미연결": nil,
	} {
		m := &Metrics{Node: "rngd-1", Samples: func() []DeviceSample { return []DeviceSample{s} }, Throttle: fn}
		reg := prometheus.NewRegistry()
		reg.MustRegister(m)
		if err := testutil.GatherAndCompare(reg, strings.NewReader(""), "furiosa_npu_throttling_events_count"); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
}

type throttleSrc struct {
	fakeSource
	mu     sync.Mutex
	reason uint32
	flap   bool // true 면 Devices 가 호출마다 정상 목록과 빈 목록을 번갈아 낸다
	calls  int
}

func (s *throttleSrc) Devices() ([]DeviceReading, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls++
	if s.flap && s.calls%2 == 0 {
		return nil, nil
	}
	return s.readings, s.err
}

func (s *throttleSrc) ThrottleReasons() (map[string]uint32, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return map[string]uint32{"UUID-A": s.reason}, nil
}

func (s *throttleSrc) set(reason uint32) {
	s.mu.Lock()
	s.reason = reason
	s.mu.Unlock()
}

// 판독이 실패하는 공급원이다. 못 읽은 표본은 창에 아무것도 남기지 않아야 한다.
type failingThrottleSrc struct{ fakeSource }

func (failingThrottleSrc) ThrottleReasons() (map[string]uint32, error) {
	return nil, errors.New("판독 실패")
}

func refresherWith(t *testing.T, src DeviceSource) *refresher {
	t.Helper()
	r := newRefresher(func() (DeviceSource, error) { return src, nil })
	r.giveUp = func() { t.Fatal("giveUp 이 불려서는 안 된다") }
	r.refresh()
	return r
}

// 표본이 공급원의 사유를 UUID 별로 창에 기록한다 — 켜지고 꺼지는 두 번의 변화가 센다.
func TestSampleThrottleRecordsReasonChanges(t *testing.T) {
	src := &throttleSrc{fakeSource: fakeSource{readings: liveDevice()}}
	r := refresherWith(t, src)
	for i, reason := range []uint32{0, 2, 0} {
		src.set(reason)
		r.sampleThrottle(t0.Add(time.Duration(i) * time.Second))
	}
	got, ok := r.throttle.counts("UUID-A", t0.Add(3*time.Second))
	if !ok || got["thermal_slowdown"] != 2 {
		t.Errorf("counts=%v ok=%v, thermal_slowdown 2 기대", got, ok)
	}
}

// 못 읽은 표본(공급원 없음·판독 미지원·판독 오류)은 "쓰로틀 해제" 로 읽히지 않고 건너뛴다.
func TestSampleThrottleSkipsWhenUnreadable(t *testing.T) {
	noSource := newRefresher(func() (DeviceSource, error) { return nil, errBoom })
	cases := map[string]*refresher{
		"공급원 없음": noSource,
		"판독 미지원": refresherWith(t, fakeSource{readings: liveDevice()}),
		"판독 오류":  refresherWith(t, failingThrottleSrc{fakeSource{readings: liveDevice()}}),
	}
	for name, r := range cases {
		r.sampleThrottle(t0)
		if _, ok := r.throttle.counts("UUID-A", t0); ok {
			t.Errorf("%s: 못 읽은 표본이 창에 기록됐다", name)
		}
	}
}

// 수집 회차가 공급원을 버리고 다시 만드는 동안 표본이 돌아도 경쟁·패닉이 없어야 한다(go test -race).
// Devices 가 정상 목록과 빈 목록을 번갈아 내므로 read() 가 r.src 를 유지하고 버리기를 반복한다.
func TestSampleThrottleSurvivesSourceReset(t *testing.T) {
	log.SetOutput(io.Discard) // 회차마다 찍는 재획득 로그를 줄인다
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	src := &throttleSrc{fakeSource: fakeSource{readings: liveDevice()}, flap: true}
	created := 0
	r := newRefresher(func() (DeviceSource, error) {
		created++
		return src, nil
	})
	r.giveUp = func() {}
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for i := 0; i < 200; i++ {
			r.refresh()
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < 200; i++ {
			r.sampleThrottle(t0.Add(time.Duration(i) * time.Second))
		}
	}()
	wg.Wait()
	// 두 회차에 한 번꼴로 공급원을 다시 만든다(약 100회). 재획득 경로를 타지 않으면 이 시험은 의미가 없다.
	if created < 50 {
		t.Fatalf("공급원 재생성 %d회, 50회 이상 기대 — 재획득 경로를 타지 않았다", created)
	}
}
