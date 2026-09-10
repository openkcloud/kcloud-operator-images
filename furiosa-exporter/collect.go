// ============================================================
// collect.go: 장치 판독을 지표 샘플로 변환한다(순수 로직, cgo 없음)
// 상세: DeviceSource 뒤에 벤더 SDK 를 숨겨 실장치 없이 시험 가능하게 한다.
//       장치 하나가 실패해도 나머지 샘플은 살린다 — 부분 실패로 노드 전체
//       관측을 지우지 않는다.
// 생성일: 2026-08-07
// ============================================================
package main

import "fmt"

// CoreReading 은 PE 코어 하나의 사용률이다.
type CoreReading struct {
	Core         uint32
	UsagePercent float64
}

// DeviceReading 은 벤더 SDK 에서 읽은 장치 하나의 원본 값이다.
// Err 가 비어 있지 않으면 그 장치는 이번 회차에 건너뛴다.
type DeviceReading struct {
	Index          uint32
	Name           string
	Serial         string
	UUID           string
	BDF            string
	CoreNum        uint32
	Cores          []CoreReading
	DramTotalBytes uint64
	DramInUseBytes uint64
	PowerWatts     float64
	TempSocPeak    float64
	TempAmbient    float64
	Alive          bool
	Err            error
}

// DeviceSource 는 장치 판독의 공급원이다. 실구현은 device.go 의 smi 백엔드이고
// 시험은 가짜를 넣는다.
type DeviceSource interface {
	Devices() ([]DeviceReading, error)
}

// DeviceSample 은 지표로 방출할 장치 하나의 값이다.
type DeviceSample struct {
	PCI            string
	Device         string
	Cores          []CoreReading
	DramTotalBytes uint64
	DramInUseBytes uint64
	PowerWatts     float64
	TempSocPeak    float64
	TempAmbient    float64
	Alive          bool
}

// Collect 는 공급원의 판독을 샘플로 옮긴다. 개별 장치 오류는 그 장치만 버린다.
func Collect(src DeviceSource) ([]DeviceSample, error) {
	readings, err := src.Devices()
	if err != nil {
		return nil, err
	}
	out := make([]DeviceSample, 0, len(readings))
	for _, r := range readings {
		if r.Err != nil {
			continue
		}
		out = append(out, DeviceSample{
			PCI:            r.BDF,
			Device:         fmt.Sprintf("npu%d", r.Index),
			Cores:          r.Cores,
			DramTotalBytes: r.DramTotalBytes,
			DramInUseBytes: r.DramInUseBytes,
			PowerWatts:     r.PowerWatts,
			TempSocPeak:    r.TempSocPeak,
			TempAmbient:    r.TempAmbient,
			Alive:          r.Alive,
		})
	}
	return out, nil
}
