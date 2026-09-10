// ============================================================
// pciid.go: PCI 장치 ID 로 가속기 제품명을 판정
// 상세: sysfs 의 vendor/device 파일만 읽으므로 특권 도구(nvidia-smi 등) 없이 동작한다.
//
//	detect() 는 벤더 단위 집계라 model 이 "generic" 으로 뭉개지는데, 보고 단계에서
//	PCI 주소마다 이 판정을 태워 실제 제품명을 싣는다. 판정은 3단 계층이다
//	(pcidb.go): ① 실측 확인 표 ② 표준 PCI DB ③ 빈 문자열.
//
// 생성일: 2026-08-11 | 수정일: 2026-08-12
// ============================================================
package main

import (
	"path/filepath"
	"strings"
)

// pciProduct 는 "<vendor>:<device>"(0x 접두 없는 소문자) → 제품명 표다.
// 실측으로 확인한 것만 넣는다 — 지어낸 ID 는 fail-closed 판정을 조용히 무너뜨린다.
var pciProduct = map[string]string{
	"10de:20b7": "a30", // k8s-worker1 0000:18:00.0 (nvidia-smi 제품명과 대조, 2026-08-11)
	"10de:25b6": "a2",  // k8s-worker1 0000:86:00.0 (nvidia-smi 제품명과 대조, 2026-08-11)
}

// productFromPCI 는 sysfsRoot/<addr> 의 vendor·device ID 로 제품명을 찾는다.
// 순서가 중요하다. 표준 DB 는 한 ID 에 제품을 둘 적기도 한다(25b6 = "A2 / A16").
// 우리가 nvidia-smi 로 실물을 확인한 것이 DB 보다 정확하므로 표가 먼저다.
//
//	① 실측 확인 표(pciProduct)  ② 표준 DB(lookupPCIDB)  ③ 빈 문자열(호출부가 generic 유지)
func productFromPCI(sysfsRoot, addr string) string {
	if addr == "" {
		return "" // Join(root, "") 은 root 로 접혀 엉뚱한 노드를 읽는다
	}
	base := filepath.Join(sysfsRoot, addr)
	id := func(name string) string {
		return strings.TrimPrefix(strings.ToLower(readFileTrim(filepath.Join(base, name))), "0x")
	}
	v, d := id("vendor"), id("device")
	if v == "" || d == "" {
		return ""
	}
	if p, ok := pciProduct[v+":"+d]; ok {
		return p
	}
	return lookupPCIDB(pciDBPath, v, d)
}
