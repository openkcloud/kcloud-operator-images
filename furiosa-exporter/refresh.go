// ============================================================
// refresh.go: 장치 공급원 수명 관리 — 잃으면 다시 잡는다
// 상세: SMI 핸들을 기동 시 한 번만 만들면, 장치가 잠깐 사라진 순간에 기동한 프로세스가 빈
// 핸들을 물고 굳어 지표가 영구히 0건이 된다. 회차가 비거나 실패하면 핸들을 버리고 다시 만든다.
// 생성일: 2026-08-10 | 수정일: 2026-10-11
// ============================================================
package main

import (
	"log"
	"sync"
)

// sourceFactory 는 장치 공급원을 새로 만든다. 실제로는 NewSMISource 이고 시험은 가짜를 넣는다.
type sourceFactory func() (DeviceSource, error)

// maxEmptyCycles 는 장치를 못 본 채로 견디는 회차 수다. 넘으면 프로세스를 끝낸다.
//
// 기본 주기 10s 기준 90초. 드라이버 교체 중 장치가 사라지는 구간은 실측 약 50초다 — 그보다
// 넉넉히 잡아 정상 교체 중 재기동을 피하되, 영구 고착은 반드시 끊는다.
const maxEmptyCycles = 9

// refresher 는 공급원 하나를 들고 주기 수집을 돈다.
//
// 장치가 없는 순간에 뜬 프로세스는 smi.Init() 을 몇 번을 다시 불러도 끝내 장치를 보지 못한다.
// 같은 이미지·같은 마운트로 새 프로세스를 띄우면 즉시 정상이다 — 벤더 라이브러리 초기화가
// 프로세스 안에서 되돌려지지 않는다는 뜻이다. 따라서 유일하게 통하는 복구는 프로세스 교체이고,
// kubelet 이 이미 해 주는 일이므로 여기서는 끝내 주기만 하면 된다.
type refresher struct {
	newSource sourceFactory
	giveUp    func() // 장치를 오래 못 보면 호출. 기본은 프로세스 종료.

	mu   sync.RWMutex
	snap []DeviceSample

	src   DeviceSource
	empty int // 연속으로 장치를 못 본 회차 수

	// 쓰로틀 전이 계수. 키는 장치 BDF 다 — 인덱스는 재획득 때 순서가 바뀔 수 있다.
	// SMI 와 sysfs 어디에도 누적 카운터가 없어 여기서 파생한다. 집계 방식은 upstream
	// furiosa-ai/furiosa-metrics-exporter 의 internal/collector/throttle.go(Apache-2.0)를 따른다.
	throttlePrev  map[string]uint32
	throttleCount map[string]uint64
}

func newRefresher(f sourceFactory) *refresher {
	return &refresher{
		newSource:     f,
		throttlePrev:  make(map[string]uint32),
		throttleCount: make(map[string]uint64),
		giveUp: func() {
			log.Fatalf("장치를 %d 회차 연속 보지 못했다 — 프로세스를 끝낸다(재기동으로만 복구된다)",
				maxEmptyCycles)
		},
	}
}

// snapshot 은 마지막으로 성공한 수집 결과다.
func (r *refresher) snapshot() []DeviceSample {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.snap
}

// refresh 는 한 회차를 돈다.
//
// 읽지 못한 회차는 **빈 스냅샷을 낸다.** 마지막 정상값을 붙들고 있으면 장치가 실제로 죽은
// 동안에도 `kcloud_furiosa_device_alive` 가 1 을 계속 보고한다 — 없는 것을 있다고 말하는 쪽이
// 지표가 잠깐 사라지는 쪽보다 나쁘다. 드라이버 교체 중 몇십 초 비는 것은 사실 그대로다.
func (r *refresher) refresh() {
	samples := r.read()
	r.countThrottle(samples)
	r.publish(samples)

	if len(samples) > 0 {
		r.empty = 0
		return
	}
	r.empty++
	if r.empty >= maxEmptyCycles {
		r.giveUp()
	}
}

// countThrottle 은 사유 비트가 0 에서 0 이 아닌 값으로 바뀐 횟수를 장치별로 누적해 샘플에 싣는다.
//
// 못 읽은 회차(ThrottleValid=false)는 이전 값을 그대로 둔다 — 미수집을 "쓰로틀 해제" 로 읽으면
// 없던 전이가 생긴다. 재기동 시 0 으로 돌아가는 것은 Prometheus 의 rate·increase 가 처리하므로
// 그대로 둔다.
func (r *refresher) countThrottle(samples []DeviceSample) {
	for i := range samples {
		s := &samples[i]
		if !s.ThrottleValid {
			s.ThrottleEvents = r.throttleCount[s.PCI]
			continue
		}
		prev, seen := r.throttlePrev[s.PCI]
		if seen && prev == 0 && s.ThrottleReason != 0 {
			r.throttleCount[s.PCI]++
		}
		r.throttlePrev[s.PCI] = s.ThrottleReason
		s.ThrottleEvents = r.throttleCount[s.PCI]
	}
}

// read 는 이번 회차의 샘플이다. 읽지 못했으면 핸들을 버려 다음 회차에 다시 잡는다.
func (r *refresher) read() []DeviceSample {
	if r.src == nil {
		src, err := r.newSource()
		if err != nil {
			// 드라이버가 아직 안 돌아왔으면 생성이 계속 실패한다. 죽지 않고 다음 회차에 다시 시도한다 —
			// 여기서 종료하면 재기동 루프에 들어가 복귀를 관측할 주체 자체가 사라진다.
			log.Printf("장치 공급원 생성 실패 — 다음 회차에 재시도: %v", err)
			return nil
		}
		r.src = src
	}

	samples, err := Collect(r.src)
	if err != nil {
		log.Printf("수집 실패 — 공급원을 버리고 다음 회차에 재획득: %v", err)
		r.src = nil
		return nil
	}

	if len(samples) == 0 {
		// 장치가 하나도 안 보인다. 이 노드는 장치가 있어야 하는 노드다(없으면 DaemonSet 이
		// 스케줄되지 않는다). 따라서 빈 목록은 "장치 없음" 이 아니라 "핸들이 상했다" 로 읽는다.
		log.Print("장치가 하나도 보이지 않는다 — 공급원을 버리고 다음 회차에 재획득")
		r.src = nil
	}
	return samples
}

func (r *refresher) publish(samples []DeviceSample) {
	r.mu.Lock()
	r.snap = samples
	r.mu.Unlock()
}
