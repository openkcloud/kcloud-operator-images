# ============================================================
# Dockerfile: Tenstorrent Blackhole DaemonSet/install-Job 겸용 tt-kmd 드라이버 컨테이너
# 상세: 빌드 시 tt-kmd 소스를 특정 태그로 clone → /opt/tt-kmd-src/<ver> 에 baked
#       (air-gap: 런타임 git clone 제거). entrypoint 가 DKMS 로 빌드/설치.
# 생성일: 2026-04-22 | 수정일: 2026-09-09
# ============================================================
FROM ubuntu:22.04

# tt-kmd upstream 태그(ttkmd-<ver>)와 그에 대응하는 semver 버전.
#   TT_KMD_GIT_TAG : git clone 대상 태그 (예: ttkmd-2.8.0)
#   TT_KMD_VERSION : DKMS PACKAGE_VERSION / 이미지 라벨 (예: 2.8.0)
ARG TT_KMD_GIT_TAG="ttkmd-2.8.0"
ARG TT_KMD_VERSION="2.8.0"

ENV DEBIAN_FRONTEND=noninteractive
# 런타임에서 entrypoint 가 사용할 권위 버전 (baked 소스와 1:1).
ENV TT_KMD_VERSION="${TT_KMD_VERSION}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    gnupg \
    iproute2 \
    util-linux \
    procps \
    kmod \
    pciutils \
    dkms \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

# tt-kmd 소스를 특정 태그로 baked (air-gap 클러스터에서 런타임 clone 불필요).
# /opt 하위에 둔다 — install Job 은 host /usr/src 를 컨테이너에 bind-mount 하므로
# /usr/src 아래 baked 하면 런타임에 가려진다. entrypoint 가 /opt→host/usr/src 로 복사.
RUN git clone --depth=1 --branch "${TT_KMD_GIT_TAG}" \
      https://github.com/tenstorrent/tt-kmd "/opt/tt-kmd-src/${TT_KMD_VERSION}" \
    && rm -rf "/opt/tt-kmd-src/${TT_KMD_VERSION}/.git"

COPY marker-migrate.sh /usr/local/bin/marker-migrate.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
COPY driver-manager.sh /usr/local/bin/driver-manager.sh
COPY check-kernel-headers.sh /usr/local/bin/check-kernel-headers.sh

RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/healthcheck.sh \
             /usr/local/bin/driver-manager.sh \
             /usr/local/bin/check-kernel-headers.sh

# image label 검증용 — verify-image.sh 가 ai.npu.driver.full 비교
RUN mkdir -p /opt/tenstorrent && echo "${TT_KMD_VERSION}" > /opt/tenstorrent/version.txt
LABEL org.opencontainers.image.version="${TT_KMD_VERSION}"
LABEL ai.npu.driver.full="${TT_KMD_VERSION}"
LABEL ai.npu.driver.vendor="tenstorrent"

# startupProbe: /tmp/driver-ready 존재 확인
# livenessProbe: /usr/local/bin/healthcheck.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
