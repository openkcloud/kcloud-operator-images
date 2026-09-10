// go.mod: Furiosa RNGD 텔레메트리 exporter 모듈
// 상세: furiosa-smi-go(cgo)로 코어 사용률·메모리·온도·전력을 읽어
//       Prometheus 포맷으로 :9410 에 노출한다.
// 생성일: 2026-08-07
module furiosa-exporter

go 1.25.0

require (
	github.com/furiosa-ai/furiosa-smi-go v0.6.1-0.20260423053636-b0ca0981e92f
	github.com/prometheus/client_golang v1.24.1
)

require (
	github.com/beorn7/perks v1.0.1 // indirect
	github.com/bradfitz/iter v0.0.0-20191230175014-e8f45d346db8 // indirect
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/kylelemons/godebug v1.1.0 // indirect
	github.com/munnerz/goautoneg v0.0.0-20191010083416-a7dc8b61c822 // indirect
	github.com/prometheus/client_model v0.6.2 // indirect
	github.com/prometheus/common v0.70.1 // indirect
	github.com/prometheus/procfs v0.21.1 // indirect
	golang.org/x/sys v0.47.0 // indirect
	google.golang.org/protobuf v1.36.11 // indirect
)
