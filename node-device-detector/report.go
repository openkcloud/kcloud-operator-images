// ============================================================
// report.go: Snapshot → NodeDeviceReport(status) 기록 능력
// 상세: 기존 감지 결과(devices/passthroughReserved)를 unstructured NDR 로 R/W 한다.
//
//	Validation 결과가 있으면 status.validation 을 additive 로 덧붙인다(기존 소비자 무영향).
//
// 생성일: 2026-07-16 | 수정일: 2026-09-09
// ============================================================
package main

import (
	"context"
	"fmt"
	"strings"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

var (
	ndrGV  = schema.GroupVersion{Group: "npu.ai", Version: "v1alpha1"}
	ndrGVK = schema.GroupVersionKind{Group: ndrGV.Group, Version: ndrGV.Version, Kind: "NodeDeviceReport"}
)

// buildDevices 는 Snapshot 의 Detected 목록을 NDR status.devices 맵으로 변환한다.
// 필드 구성은 기존 main 루프와 바이트 동등(회귀 0). 각 device 에 대표 드라이버 바인딩을 채운다.
func buildDevices(snap *Snapshot) []map[string]any {
	// S2-5 WP-R1: cross-major 재부팅 필요 신호. install/driver-manager 가 rmmod 실패+Require 시
	// host 노드-레벨 마커를 남긴다(WP-R2). detector 는 host-var 마운트로 read.
	// ponytail: 단일 노드-레벨 마커라 NVIDIA device 에만 적용(1st 레퍼런스, 멀티벤더 오탐 방지).
	// 타 벤더는 rmmod 로 수렴(reboot 불요). 벤더별 마커/메이저불일치(계획 §2.1b)는 후속.
	needsRebootMarker := fileExists(markerPath("needs-reboot"))

	devices := make([]map[string]any, 0, len(snap.Devices))
	for _, d := range snap.Devices {
		newBase := func() map[string]any {
			dev := map[string]any{
				"vendor":              d.vendor,
				"model":               d.model,
				"count":               int32(d.count),
				"driverLoaded":        d.loaded,
				"driverVersion":       d.ver,    // 통일된 짧은 버전 (숫자형만)
				"driverVersionDetail": d.detail, // 상세(한 줄)
				// 모든 벤더 device 에 대표 드라이버 바인딩을 보고한다
				// (self-driver / vfio-pci / mixed / none).
				"driverBinding": deviceDriverBinding(d),
			}
			// needsReboot 는 true 일 때만 기록(false 는 생략 → 기존 NDR 과 바이트 동등, 회귀 0).
			if needsRebootMarker && strings.EqualFold(d.vendor, "nvidia") {
				dev["needsReboot"] = true
			}
			return dev
		}

		// PCI 주소마다 별도 device entry 를 만든다. NVIDIA 는 MIG 관측을 per-PCI 로 부착하려고
		// 먼저 이렇게 했지만(Task 2, spec §14.1/§15.3 — 전역 -lgip/-lgi 를 여러 GPU 에 복붙하면
		// 상태가 뒤섞인다), 카드를 개별로 지목할 수 있어야 하는 건 NPU 도 같다: 소비자 쪽
		// rngd backend 의 deviceID() 는 PCI 가 없으면 model 로 폴백해 한 노드의 RNGD 카드를 전부
		// 같은 ID 로 뭉개고, intent.ApplyHealth 의 장치 단위 제외는 PCI 를 키로 삼아 PCI 없는
		// 장치를 아예 못 뺀다(2026-08-04 라이브: warboy/rngd/tenstorrent 전부 pcie 공란).
		//
		// 집계 entry 에 주소 하나를 붙이는 방식은 답이 못 된다 — 카드가 2장이면 나머지 1장에
		// 대해서는 거짓이 되고, 위 두 소비자 문제는 그대로 남는다.
		//
		// 소비자 회귀: NDR 소비자는 이미 NVIDIA 때문에 "벤더당 entry 1개" 를 가정할 수 없는
		// 상태다(worker1 은 nvidia entry 가 2개). count 를 합산하는 쪽(intent.physicalDeviceCount,
		// acpp 의 nvidiaPhysicalGPUs, apiserver.ndrEntriesFor)은 fan-out 시 entry 당 count=1 이라
		// 합이 보존된다. 주소 목록은 *PciCount 와 같은 match 함수에서 나오므로 개수도 일치한다.
		pcis := snap.PciAddrs[vendorKey(d.vendor, d.model)]
		isNvidia := strings.EqualFold(d.vendor, "nvidia")
		if len(pcis) == 0 {
			// PCI 목록을 못 찾으면(sysfs 부재 등) 기존 단일 집계 entry 를 유지한다(회귀 0).
			dev := newBase()
			if isNvidia {
				// NVIDIA 는 전역 MigLgip 폴백까지. MIG 필드는 pci 공란으로 fail-closed(Unknown+Err).
				attachMigObservation(dev, observeMig(""))
				dev["migLgipOutput"] = snap.MigLgip // Task 11 producer 와 바이트 동등 폴백
			}
			devices = append(devices, dev)
			continue
		}
		for _, pci := range pcis {
			dev := newBase()
			dev["count"] = int32(1) // fan-out entry: 물리 카드 1장당 1 entry (집계 count 복붙 금지)
			dev["pcieAddress"] = pci
			// detect() 는 벤더 단위 집계라 model 이 "generic" 으로 뭉개진다. 카드를 개별로
			// 지목할 수 있는 건 여기가 처음이므로, PCI ID 로 실제 제품명을 찾아 덮는다.
			// 이 값이 제품명의 정본이다 — 노드 라벨 `<벤더>.product` 는 집계값 "generic" 으로
			// 남아 갈라진다(사유는 label.go 의 product/count 주석).
			// 판정 실패(빈 문자열)면 기존 값을 그대로 둔다 — 이 폴백이 깨지면 소비자
			// (partition/nvidia backend)의 fail-closed 판정이 무너진다.
			if isNvidia && d.model == "generic" {
				if p := productFromPCI(H(hostSysPciDevices), pci); p != "" {
					dev["model"] = p
				}
			}
			if isNvidia {
				obs := observeMig(pci)
				attachMigObservation(dev, obs)
				dev["migLgipOutput"] = obs.LgipOutput // per-PCI(Task 2) — 더 이상 전역 복붙 아님
			}
			devices = append(devices, dev)
		}
	}
	return devices
}

// attachMigObservation 은 MigObservation 을 NDR device entry 의 4개 MIG 필드로 매핑한다
// (DeviceEntry.MigModeCurrent/MigModePending/MigCurrentGeometry/MigObservationError, Task 1).
func attachMigObservation(dev map[string]any, obs MigObservation) {
	dev["migModeCurrent"] = obs.ModeCurrent
	dev["migModePending"] = obs.ModePending
	dev["migCurrentGeometry"] = obs.Geometry
	dev["migObservationError"] = obs.Err
}

// migCarryFields 는 관측 주체가 바뀔 때 함께 옮겨야 하는 MIG 필드다. 넷을 따로 옮기면
// mode 는 새 값, geometry 는 옛 값 같은 섞인 상태가 만들어진다.
var migCarryFields = []string{
	"migModeCurrent", "migModePending", "migCurrentGeometry", "migObservationError", "migLgipOutput",
}

// preserveObservedMig 는 **이번에 관측하지 못한** GPU 의 MIG 필드를 기존 보고서 값으로 되돌린다.
//
// detector 는 비특권 컨테이너라 `/dev/nvidia*` 가 없어 MIG 를 못 본다(호스트 nvidia-smi 는
// 실행되지만 GPU 를 열지 못해 exit 9). 그런데도 매 주기 "Unknown + 관측 실패" 를 써 넣으면,
// operator 가 특권 Job 으로 제대로 관측해 채워 둔 값을 30초마다 지우게 된다 — 노드 라벨에서
// 똑같은 일이 있었다(D-4, label.go 의 operatorOwnedLabels).
//
// 규칙은 하나다: **우리가 실패했고 저쪽이 성공한 경우에만 물려받는다.** detector 가 언젠가
// 관측할 수 있게 되면 그때는 새 값이 이긴다.
func preserveObservedMig(fresh []map[string]any, old []any) {
	prior := map[string]map[string]any{}
	for _, e := range old {
		m, ok := e.(map[string]any)
		if !ok {
			continue
		}
		pci, _ := m["pcieAddress"].(string)
		if pci == "" {
			continue
		}
		if errStr, _ := m["migObservationError"].(string); errStr != "" {
			continue // 저쪽도 관측 못 한 값이다 — 물려받을 것이 없다
		}
		prior[pci] = m
	}
	for _, dev := range fresh {
		if errStr, _ := dev["migObservationError"].(string); errStr == "" {
			continue // 이번에 관측했다 — 새 값이 이긴다
		}
		pci, _ := dev["pcieAddress"].(string)
		p, ok := prior[pci]
		if !ok {
			continue
		}
		for _, k := range migCarryFields {
			delete(dev, k)
			if v, has := p[k]; has {
				dev[k] = v
			}
		}
	}
}

// buildValidation 은 ValidationResult 를 NDR status.validation 맵으로 변환한다.
// nil 이면 nil 을 반환하여 status 에 키를 쓰지 않는다(additive-only).
func buildValidation(v *ValidationResult) map[string]any {
	if v == nil {
		return nil
	}
	steps := make([]map[string]any, 0, len(v.Steps))
	for _, s := range v.Steps {
		st := map[string]any{"name": s.Name, "passed": s.Passed}
		if s.NotApplicable {
			st["notApplicable"] = true
		}
		if s.Message != "" {
			st["message"] = s.Message
		}
		steps = append(steps, st)
	}
	return map[string]any{
		"passed":      v.Passed,
		"lastRunTime": v.LastRunTime.UTC().Format("2006-01-02T15:04:05Z"),
		"vendor":      v.Vendor,
		"steps":       steps,
	}
}

// Report 는 Snapshot 을 NDR 로 기록한다(Get-or-Create + status update).
// 기존 main 루프의 write 로직을 그대로 옮긴 것으로, validation 만 additive 로 추가된다.
func Report(ctx context.Context, c client.Client, snap *Snapshot) error {
	node := snap.Node
	devices := buildDevices(snap)
	validation := buildValidation(snap.Validation)

	ndr := &unstructured.Unstructured{}
	ndr.SetGroupVersionKind(ndrGVK)
	ndr.SetName(node)

	// Get or Create
	if err := c.Get(ctx, client.ObjectKey{Name: node}, ndr); err != nil {
		status := map[string]any{
			"devices":             devices,
			"passthroughReserved": snap.PassthroughReserved,
			// 관측 시각을 함께 보낸다. 이 값이 없으면 health 판정이 보고서의 신선도를 알 수 없어
			// 모든 노드를 Unknown 으로 둔다(operator 쪽 계약, R&D base v0.1 §9.3).
			"observedAt": time.Now().UTC().Format(time.RFC3339),
		}
		if validation != nil {
			status["validation"] = validation
		}
		ndr.Object = map[string]any{
			"apiVersion": ndrGV.String(),
			"kind":       "NodeDeviceReport",
			"metadata":   map[string]any{"name": node},
			"spec":       map[string]any{"nodeName": node},
			"status":     status,
		}
		if err := c.Create(ctx, ndr); err != nil {
			return fmt.Errorf("create NDR: %w", err)
		}
		_ = c.Status().Update(ctx, ndr)
		fmt.Println("NDR created for", node)
		return nil
	}

	if ndr.Object["status"] == nil {
		ndr.Object["status"] = map[string]any{}
	}
	st := ndr.Object["status"].(map[string]any)
	if old, ok := st["devices"].([]any); ok {
		preserveObservedMig(devices, old)
	}
	st["devices"] = devices
	st["passthroughReserved"] = snap.PassthroughReserved
	st["observedAt"] = time.Now().UTC().Format(time.RFC3339)
	if validation != nil {
		st["validation"] = validation
	}
	if err := c.Status().Update(ctx, ndr); err != nil {
		if ndr.Object["spec"] == nil {
			ndr.Object["spec"] = map[string]any{"nodeName": node}
		}
		_ = c.Update(ctx, ndr)
	}
	fmt.Println("NDR updated for", node, "devices:", len(devices))
	return nil
}
