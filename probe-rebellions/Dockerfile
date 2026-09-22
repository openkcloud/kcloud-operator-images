# ============================================================
# Dockerfile: probe-rebellions — ACPP 기능 probe(rbln-stat) 종료코드 판정용 one-shot 이미지
# 상세: 이미지 자체에는 rbln-stat 바이너리가 없다 — nsenter 로 호스트 네임스페이스
#       (mount/net/pid/ipc)에 진입해 호스트에 설치된 실 바이너리를 실행하는 래퍼만 담는다
#       (tester/pods/atom-smi.yaml(비추적 루트 tester/) 의 상시 파드 관측과 같은 이유). operator
#       (acpp_verifier.go vendorProbes)가 이 컨테이너를 privileged+hostPID 로 띄우고
#       command=["rbln-stat"](PATH 조회)로 1회 실행 후 종료코드로 판정한다 — 특권 파드이므로
#       values.yaml 기본값은 비워 두고(레거시 pause 유지) 명시적으로 켜야 한다.
# 생성일: 2026-09-20
# ============================================================
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends util-linux \
    && rm -rf /var/lib/apt/lists/*
COPY rbln-stat /usr/local/bin/rbln-stat
RUN chmod +x /usr/local/bin/rbln-stat
ENTRYPOINT ["/usr/local/bin/rbln-stat"]
