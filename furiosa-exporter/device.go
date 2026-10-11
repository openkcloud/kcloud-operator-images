//go:build smi

// ============================================================
// device.go: furiosa-smi 백엔드(cgo). DeviceSource 의 실구현.
// 상세: 이 파일만 벤더 SDK 를 안다. smi 태그 뒤에 둬 라이브러리 없는 머신에서도 나머지
// 패키지가 빌드·시험되게 한다. Observer 는 시간 창으로 계산하므로 프로세스 수명 동안 재사용한다.
// 생성일: 2026-08-07 | 수정일: 2026-10-11
// ============================================================
package main

import (
	"fmt"
	"strings"

	"github.com/furiosa-ai/furiosa-smi-go/pkg/smi"
)

type smiSource struct {
	observer smi.Observer
}

// NewSMISource 는 SMI 를 초기화하고 Observer 를 만든다.
func NewSMISource() (DeviceSource, error) {
	if err := smi.Init(); err != nil {
		return nil, fmt.Errorf("furiosa-smi 초기화 실패: %w", err)
	}
	obs, err := smi.CreateDefaultObserver()
	if err != nil {
		return nil, fmt.Errorf("observer 생성 실패: %w", err)
	}
	return &smiSource{observer: obs}, nil
}

func (s *smiSource) Devices() ([]DeviceReading, error) {
	devs, err := smi.ListDevices()
	if err != nil {
		return nil, fmt.Errorf("장치 목록 실패: %w", err)
	}
	out := make([]DeviceReading, 0, len(devs))
	for _, d := range devs {
		out = append(out, s.read(d))
	}
	return out, nil
}

// read 는 장치 하나를 읽는다. 축마다 따로 실패할 수 있으므로 치명적인 것
// (DeviceInfo)만 Err 로 올리고 나머지는 그 축만 비운다.
func (s *smiSource) read(d smi.Device) DeviceReading {
	info, err := d.DeviceInfo()
	if err != nil {
		return DeviceReading{Err: fmt.Errorf("DeviceInfo 실패: %w", err)}
	}
	r := DeviceReading{
		Index: info.Index(), Name: info.Name(), Serial: info.Serial(),
		UUID: info.UUID(), BDF: info.BDF(), CoreNum: info.CoreNum(),
	}
	if utils, err := s.observer.GetCoreUtilization(d); err == nil {
		for _, u := range utils {
			r.Cores = append(r.Cores, CoreReading{Core: u.Core(), UsagePercent: u.PeUsagePercentage()})
		}
	}
	if freq, err := d.CoreFrequency(); err == nil {
		for _, pe := range freq.PeFrequency() {
			r.CoreClocks = append(r.CoreClocks, CoreClock{Core: pe.Core(), MHz: pe.Frequency()})
		}
	}
	if g, err := d.GovernorProfile(); err == nil {
		r.Governor = strings.ToLower(g.String())
	}
	if tr, err := d.ThrottleReason(); err == nil {
		r.ThrottleReason, r.ThrottleValid = uint32(tr), true
	}
	if mem, err := d.MemoryUtilization(); err == nil {
		for _, b := range mem.Dram().Memory() {
			r.DramTotalBytes += b.TotalBytes()
			r.DramInUseBytes += b.InUseBytes()
		}
	}
	if p, err := d.PowerConsumption(); err == nil {
		r.PowerWatts = p
	}
	if t, err := d.DeviceTemperature(); err == nil {
		r.TempSocPeak, r.TempAmbient = t.SocPeak(), t.Ambient()
	}
	if alive, err := d.Liveness(); err == nil {
		r.Alive = alive
	}
	return r
}
