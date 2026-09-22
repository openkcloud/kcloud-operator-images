// ============================================================
// driver.go: DRA kubeletplugin 구현
// 상세: host /dev 발견 결과를 ResourceSlice 로 발행하고, claim 이 오면 CDI 스펙을
//
//	써서 장치를 주입한다. 벤더는 모른다 — 전부 설정(발견 템플릿)에서 온다.
//
// 생성일: 2026-08-11 | 수정일: 2026-09-18
// ============================================================
package main

import (
	"context"
	"fmt"
	"sync"

	resourceapi "k8s.io/api/resource/v1"
	"k8s.io/apimachinery/pkg/types"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	coreclientset "k8s.io/client-go/kubernetes"
	"k8s.io/dynamic-resource-allocation/kubeletplugin"
	"k8s.io/dynamic-resource-allocation/resourceslice"
	"k8s.io/klog/v2"
)

// driver 는 kubeletplugin.DRAPlugin 을 구현한다.
type driver struct {
	config   *Config
	nodeName string
	cdiDir   string
	hostRoot string
	helper   *kubeletplugin.Helper

	mu       sync.Mutex
	prepared map[types.UID][]string // claim UID -> 이 claim 이 준비한 장치 ID 목록(회수용)
}

// NewDriver 는 kubeletplugin 을 기동하고 host 에서 발견한 장치를 즉시 발행한다.
func NewDriver(ctx context.Context, client coreclientset.Interface, config *Config, nodeName, cdiDir, hostRoot, registrarDir, pluginDataDir string) (*driver, error) {
	d := &driver{
		config:   config,
		nodeName: nodeName,
		cdiDir:   cdiDir,
		hostRoot: hostRoot,
		prepared: map[types.UID][]string{},
	}

	helper, err := kubeletplugin.Start(ctx, d,
		kubeletplugin.KubeClient(client),
		kubeletplugin.NodeName(nodeName),
		kubeletplugin.DriverName(config.DriverName),
		kubeletplugin.RegistrarDirectoryPath(registrarDir),
		kubeletplugin.PluginDataDirectoryPath(pluginDataDir),
	)
	if err != nil {
		return nil, fmt.Errorf("kubeletplugin 기동 실패: %w", err)
	}
	d.helper = helper

	discovered, err := discoverDevices(config.DeviceNodes, hostRoot)
	if err != nil {
		return nil, fmt.Errorf("장치 발견 실패: %w", err)
	}
	devices := make([]resourceapi.Device, len(discovered))
	for i, dev := range discovered {
		id := dev.ID
		devices[i] = resourceapi.Device{
			Name:       dev.ID,
			Attributes: map[resourceapi.QualifiedName]resourceapi.DeviceAttribute{"id": {StringValue: &id}},
		}
	}
	resources := resourceslice.DriverResources{
		Pools: map[string]resourceslice.Pool{
			nodeName: {Slices: []resourceslice.Slice{{Devices: devices}}},
		},
	}
	if err := helper.PublishResources(ctx, resources); err != nil {
		helper.Stop()
		return nil, fmt.Errorf("자원 발행 실패: %w", err)
	}

	return d, nil
}

// Shutdown 은 helper 를 멈춘다.
func (d *driver) Shutdown(klog.Logger) error {
	d.helper.Stop()
	return nil
}

// PrepareResourceClaims 는 claim 마다 CDI 스펙을 써서 장치를 주입한다.
func (d *driver) PrepareResourceClaims(ctx context.Context, claims []*resourceapi.ResourceClaim) (map[types.UID]kubeletplugin.PrepareResult, error) {
	result := make(map[types.UID]kubeletplugin.PrepareResult, len(claims))
	for _, claim := range claims {
		result[claim.UID] = d.prepareResourceClaim(claim)
	}
	return result, nil
}

// prepareResourceClaim 은 매 호출 host 를 다시 발견한다 — ResourceSlice 발행과 같은
// 원천을 써야 ID 가 어긋나지 않는다(hotplug 로 사이에 장치가 바뀌어도 따라잡는다).
//
// ponytail: claim 마다 재발견 — 배치 안 claim 수가 많아지면 PrepareResourceClaims
// 레벨에서 한 번만 발견해 넘기는 식으로 바꿀 것.
func (d *driver) prepareResourceClaim(claim *resourceapi.ResourceClaim) kubeletplugin.PrepareResult {
	if claim.Status.Allocation == nil {
		return kubeletplugin.PrepareResult{Err: fmt.Errorf("claim %s 에 할당이 없다", claim.UID)}
	}

	discovered, err := discoverDevices(d.config.DeviceNodes, d.hostRoot)
	if err != nil {
		return kubeletplugin.PrepareResult{Err: fmt.Errorf("장치 발견 실패: %w", err)}
	}
	byID := map[string]Device{}
	for _, dev := range discovered {
		byID[dev.ID] = dev
	}

	var devices []kubeletplugin.Device
	var deviceIDs []string
	for _, r := range claim.Status.Allocation.Devices.Results {
		if r.Driver != d.config.DriverName {
			continue
		}

		dev, ok := byID[r.Device]
		if !ok {
			// 설정에 없는 장치를 claim 이 요구한다. 조용히 건너뛰면 파드가 장치 없이
			// 뜬다 — 오류로 돌려 kubelet 이 재시도하게 한다.
			return kubeletplugin.PrepareResult{Err: fmt.Errorf("설정에 없는 장치를 claim 이 요구했다: %s", r.Device)}
		}

		nodes, err := resolveNodes(dev.NodeGlobs, d.hostRoot)
		if err != nil {
			return kubeletplugin.PrepareResult{Err: err}
		}
		cdiName, err := writeCDISpec(d.cdiDir, d.config.DriverName, dev.ID, nodes)
		if err != nil {
			return kubeletplugin.PrepareResult{Err: err}
		}

		devices = append(devices, kubeletplugin.Device{
			Requests:     []string{r.Request},
			PoolName:     r.Pool,
			DeviceName:   r.Device,
			CDIDeviceIDs: []string{cdiName},
		})
		deviceIDs = append(deviceIDs, dev.ID)
	}

	d.mu.Lock()
	d.prepared[claim.UID] = deviceIDs
	d.mu.Unlock()

	return kubeletplugin.PrepareResult{Devices: devices}
}

// UnprepareResourceClaims 는 PrepareResourceClaims 가 쓴 CDI 스펙을 지운다.
func (d *driver) UnprepareResourceClaims(ctx context.Context, claims []kubeletplugin.NamespacedObject) (map[types.UID]error, error) {
	result := make(map[types.UID]error, len(claims))
	for _, claim := range claims {
		result[claim.UID] = d.unprepareResourceClaim(claim.UID)
	}
	return result, nil
}

func (d *driver) unprepareResourceClaim(uid types.UID) error {
	d.mu.Lock()
	deviceIDs := d.prepared[uid]
	delete(d.prepared, uid)
	d.mu.Unlock()

	for _, id := range deviceIDs {
		if err := removeCDISpec(d.cdiDir, d.config.DriverName, id); err != nil {
			return err
		}
	}
	return nil
}

// HandleError 는 백그라운드에서 발생한 오류(예: ResourceSlice 발행 실패)를 기록한다.
func (d *driver) HandleError(ctx context.Context, err error, msg string) {
	utilruntime.HandleErrorWithContext(ctx, err, msg)
}
