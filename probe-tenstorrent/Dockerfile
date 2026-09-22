# ============================================================
# Dockerfile: probe-tenstorrent — ACPP 기능 probe(tt-smi -s) 종료코드 판정용 one-shot 이미지
# 상세: PyPI tt-smi 만 설치한다 — 커널 모듈(tt-kmd)은 호스트 것을 쓰고 /dev/tenstorrent/N 은
#       device-plugin 이 주입한다. pods/tt-smi.Dockerfile(비추적 루트 pods/, 상시 파드용, CMD sleep infinity)의
#       probe 전용 변형이다 — operator(acpp_verifier.go vendorProbes)가 이 컨테이너를
#       RestartPolicy Never 로 1회 실행하고 종료코드로 판정하므로 sleep 이 없다.
# 생성일: 2026-09-20
# ============================================================
FROM python:3.10-slim
RUN apt-get update && apt-get install -y --no-install-recommends pciutils libatomic1 libgomp1 \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir tt-smi
ENTRYPOINT ["tt-smi"]
CMD ["-s"]
