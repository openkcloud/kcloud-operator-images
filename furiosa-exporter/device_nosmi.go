//go:build !smi

// ============================================================
// device_nosmi.go: smi 태그 없이 빌드했을 때의 자리표
// 상세: libfuriosa_smi.so 가 없는 머신에서 나머지 패키지를 컴파일·시험하기 위한
//       것이다. 실행하면 즉시 실패한다 — 조용히 빈 목록을 돌려주면 지표가 0건인
//       것이 "장치 없음" 인지 "잘못 빌드됨" 인지 구분되지 않는다.
// 생성일: 2026-08-07
// ============================================================
package main

import "fmt"

// NewSMISource 는 이 빌드에서 항상 실패한다. 배포 이미지는 -tags smi 로 빌드한다.
func NewSMISource() (DeviceSource, error) {
	return nil, fmt.Errorf("smi 백엔드 없이 빌드된 바이너리다 — 이미지 빌드에 -tags smi 가 빠졌다")
}
