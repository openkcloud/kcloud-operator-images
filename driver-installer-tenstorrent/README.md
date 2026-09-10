<!-- README.md: Tenstorrent tt-kmd 컨테이너화 드라이버 설치기 사용법 | 생성일: 2026-04-22 | 수정일: 2026-09-09 -->

# Tenstorrent tt-kmd 드라이버 컨테이너

Tenstorrent Blackhole NPU를 위한 컨테이너화 드라이버 설치기입니다.
Kubernetes DaemonSet으로 배포하여 호스트 커널 모듈 상태를 지속 관리합니다.

## 개요

| 항목 | 내용 |
|------|------|
| 대상 하드웨어 | Tenstorrent Blackhole (n150 / n300 계열) |
| 커널 모듈 | `tenstorrent` (tt-kmd) |
| 업스트림 | <https://github.com/tenstorrent/tt-kmd> |
| 라이선스 | GPL-2.0 |

## 동작 방식

```
[컨테이너 시작]
      │
      ▼
[호스트 네임스페이스 진입 (nsenter)]
      │
      ▼
[lsmod | grep tenstorrent ?]
   YES ──► [no-op] ──────────────────────────────┐
   NO                                            │
      │                                          │
      ▼                                          │
[modprobe tenstorrent]                           │
   OK  ──────────────────────────────────────────┤
   FAIL                                          │
      │                                          │
      ▼                                          │
[DKMS 빌드 (SKIP_DKMS=1이면 건너뜀)]            │
      │                                          │
      ▼                                          │
[ready 마커 생성]  ◄────────────────────────────┘
/tmp/driver-ready
/var/lib/kcloud-operator/driver.ready
      │
      ▼
[헬스 모니터링 루프 (30초 간격)]
lsmod | grep tenstorrent
ls /dev/tenstorrent/
```

### k8s-worker3 현황

`k8s-worker3`에는 이미 `tenstorrent` 모듈이 로드되어 있습니다.
이 경우 entrypoint.sh는 **설치 단계를 건너뛰고(no-op)** 즉시 ready 상태로
헬스 모니터링 루프에 진입합니다.

## 환경 변수

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `HEALTH_CHECK_INTERVAL` | `30` | health check 간격 (초) |
| `SKIP_DKMS` | `0` | `1`이면 DKMS 빌드 건너뜀 |
| `TT_KMD_VERSION` | `1.0` | DKMS 빌드 시 사용할 tt-kmd 버전 |
| `TT_KMD_REPO` | `https://github.com/tenstorrent/tt-kmd` | 소스 클론 URL |
| `DEBUG` | `0` | `1`이면 `set -x` 활성화 |

## 빌드 & 배포

```bash
# 이미지 빌드
make docker-build

# 레지스트리 푸시
make docker-push

# 로컬 테스트 (privileged + pid=host)
make local-run

# 커스텀 이미지 태그
make docker-build IMG=<your-registry>/tt-kmd-installer:v0.2.0
```

## DaemonSet Probe 설정 예시

```yaml
startupProbe:
  exec:
    command: ["test", "-f", "/tmp/driver-ready"]
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 60   # 최대 5분 대기

livenessProbe:
  exec:
    command: ["/usr/local/bin/healthcheck.sh"]
  initialDelaySeconds: 30
  periodSeconds: 30
  failureThreshold: 3
```

## 디렉토리 구조

```
tenstorrent/
├── Dockerfile        # 컨테이너 이미지 정의
├── entrypoint.sh     # 메인 드라이버 설치/모니터링 스크립트
├── healthcheck.sh    # livenessProbe용 헬스체크
├── Makefile          # 빌드/배포 자동화
├── .gitignore        # 제외 파일 목록
├── LICENSE           # GPL-2.0 라이선스
└── README.md         # 이 파일
```

## 참고

- [tt-kmd GitHub](https://github.com/tenstorrent/tt-kmd)
- [Tenstorrent 공식 문서](https://docs.tenstorrent.com/)
