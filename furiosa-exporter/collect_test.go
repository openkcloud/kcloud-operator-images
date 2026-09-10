// ============================================================
// collect_test.go: 수집 변환 로직 시험(실장치·cgo 없이)
// 생성일: 2026-08-07
// ============================================================
package main

import (
	"fmt"
	"testing"
)

var errBoom = fmt.Errorf("장치 읽기 실패")

type fakeSource struct {
	readings []DeviceReading
	err      error
}

func (f fakeSource) Devices() ([]DeviceReading, error) { return f.readings, f.err }

func TestCollectMapsReadingToSample(t *testing.T) {
	src := fakeSource{readings: []DeviceReading{{
		Index: 0, Name: "rngd", BDF: "0000:27:00.0", CoreNum: 8,
		Cores:          []CoreReading{{Core: 0, UsagePercent: 42.5}, {Core: 1, UsagePercent: 0}},
		DramTotalBytes: 48 << 30, DramInUseBytes: 12 << 30,
		PowerWatts: 91.5, TempSocPeak: 61, TempAmbient: 33, Alive: true,
	}}}

	got, err := Collect(src)
	if err != nil {
		t.Fatalf("Collect 오류: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("샘플 수 = %d, 기대 1", len(got))
	}
	s := got[0]
	if s.PCI != "0000:27:00.0" {
		t.Errorf("PCI = %q, 기대 0000:27:00.0", s.PCI)
	}
	if s.Device != "npu0" {
		t.Errorf("Device = %q, 기대 npu0", s.Device)
	}
	if len(s.Cores) != 2 || s.Cores[0].UsagePercent != 42.5 {
		t.Errorf("Cores = %+v", s.Cores)
	}
	if s.DramInUseBytes != 12<<30 || s.DramTotalBytes != 48<<30 {
		t.Errorf("DRAM = %d/%d", s.DramInUseBytes, s.DramTotalBytes)
	}
}

// 장치 하나가 실패해도 나머지는 살아야 한다. 부분 실패로 전체가 죽으면
// 노드 한 장의 고장이 그 노드 전체 관측을 지운다.
func TestCollectSkipsFailedDeviceKeepsOthers(t *testing.T) {
	src := fakeSource{readings: []DeviceReading{
		{Index: 0, BDF: "0000:27:00.0", Err: errBoom},
		{Index: 1, BDF: "0000:2a:00.0", Alive: true},
	}}
	got, err := Collect(src)
	if err != nil {
		t.Fatalf("Collect 오류: %v", err)
	}
	if len(got) != 1 || got[0].Device != "npu1" {
		t.Fatalf("살아남은 샘플 = %+v, 기대 npu1 하나", got)
	}
}

// 공급원 자체가 실패하면 그건 부분 실패가 아니다 — 오류를 그대로 올린다.
func TestCollectPropagatesSourceError(t *testing.T) {
	if _, err := Collect(fakeSource{err: errBoom}); err == nil {
		t.Fatal("공급원 오류가 삼켜졌다")
	}
}
