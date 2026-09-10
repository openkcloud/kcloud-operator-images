//go:build smi

// ============================================================
// device.go: furiosa-smi 백엔드(cgo). DeviceSource 의 실구현.
// 상세: 이 파일만 벤더 SDK 를 안다. 링크에 libfuriosa_smi.so 가 필요하므로
//       smi 빌드 태그 뒤에 둔다 — 그 라이브러리가 없는 개발 머신에서도
//       나머지 패키지의 시험이 돌아야 한다. Dockerfile 이 -tags smi 로 빌드한다.
//       Observer 는 시간 창으로 PE 사용률을 계산하므로 프로세스 수명 동안
//       하나만 만들어 재사용한다.
// 생성일: 2026-08-07
// ============================================================
package main

import (
	"fmt"

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
