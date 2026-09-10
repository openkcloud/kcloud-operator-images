# ============================================================
# Dockerfile: Furiosa NPU(Warboy·RNGD 공용) 드라이버 설치 컨테이너 — furiosa-driver-ds
# 상세: entrypoint.sh 가 모델(FURIOSA_MODEL env 또는 PCI 자동 감지)에 맞는 드라이버 패키지를
#       nsenter 로 호스트에 설치하고 커널 모듈을 로드한다. 드라이버 패키지는 이미지에
#       담지 않고 런타임에 APT 저장소에서 받는다.
#       furiosa-warboy/ 와 furiosa-rngd/ 두 설치기를 하나로 합친 것이다.
#       Warboy 저장소는 인증이 필요해 /secrets 마운트를 요구하고 RNGD 는 익명이다 —
#       그 분기는 entrypoint.sh 의 모델 표가 가른다.
# 생성일: 2026-09-09
# ============================================================
FROM ubuntu:22.04

# image label 검증용 — verify-image.sh 와 짝. 이미지는 드라이버 버전을 담지 않으므로
# 이 값은 빌드 개정 번호(vN)다. 드라이버 버전은 DRIVER_VERSION env 로 들어온다.
ARG BUILD_VARIANT="v0"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg iproute2 \
    util-linux procps kmod pciutils jq dkms && \
    rm -rf /var/lib/apt/lists/*

COPY install-decision.sh     /usr/local/bin/install-decision.sh
COPY check-kernel-headers.sh /usr/local/bin/check-kernel-headers.sh
COPY driver-manager.sh       /usr/local/bin/driver-manager.sh
COPY marker-migrate.sh       /usr/local/bin/marker-migrate.sh
COPY entrypoint.sh           /usr/local/bin/entrypoint.sh
COPY healthcheck.sh          /usr/local/bin/healthcheck.sh

RUN chmod +x /usr/local/bin/check-kernel-headers.sh \
             /usr/local/bin/driver-manager.sh \
             /usr/local/bin/entrypoint.sh \
             /usr/local/bin/healthcheck.sh

RUN mkdir -p /opt/furiosa && echo "${BUILD_VARIANT}" > /opt/furiosa/version.txt
LABEL org.opencontainers.image.version="${BUILD_VARIANT}"
LABEL ai.npu.driver.vendor="furiosa"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
