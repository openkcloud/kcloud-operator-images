// ============================================================
// main.go: Furiosa exporter 진입점. 주기 수집 + :9410/metrics 서빙.
// 상세: 수집을 goroutine 이 주기로 돌려 스냅샷을 갱신하고, /metrics 요청은
//       그 스냅샷만 읽는다. 스크레이프가 벤더 SDK 호출을 직접 유발하지
//       않게 해 스크레이프 폭주가 장치를 때리는 것을 막는다.
// 생성일: 2026-08-07
// ============================================================
package main

import (
	"flag"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

func main() {
	listen := flag.String("listen", ":9410", "metrics 리슨 주소")
	interval := flag.Duration("interval", 10*time.Second, "장치 수집 주기")
	flag.Parse()

	node := os.Getenv("NODE_NAME")
	if node == "" {
		log.Fatal("NODE_NAME 환경변수가 비어 있다 — DaemonSet 이 fieldRef 로 주입해야 한다")
	}

	// 공급원 생성은 refresher 에 맡긴다. 여기서 만들어 실패 시 종료하면, 드라이버 교체로 장치가
	// 잠깐 사라진 순간에 뜬 프로세스가 재기동 루프에 빠지거나 빈 핸들을 물고 굳는다
	// (2026-08-10 라이브). 잃으면 다시 잡는 것이 이 프로세스의 일이다.
	r := newRefresher(NewSMISource)
	r.refresh()
	go func() {
		t := time.NewTicker(*interval)
		defer t.Stop()
		for range t.C {
			r.refresh()
		}
	}()

	reg := prometheus.NewRegistry()
	reg.MustRegister(&Metrics{Node: node, Samples: r.snapshot})

	mux := http.NewServeMux()
	mux.Handle("GET /metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})

	log.Printf("furiosa-exporter listening on %s (node=%s, interval=%s)", *listen, node, *interval)
	srv := &http.Server{Addr: *listen, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
