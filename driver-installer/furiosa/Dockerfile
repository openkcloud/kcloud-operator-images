# ============================================================
# Dockerfile: Furiosa NPU(Warboy·RNGD 공용) 드라이버 설치 컨테이너 — furiosa-driver-ds
# 상세: entrypoint.sh 가 모델(FURIOSA_MODEL env 또는 PCI 자동 감지)에 맞는 드라이버 패키지를
#       nsenter 로 호스트에 설치하고 커널 모듈을 로드한다. 드라이버 패키지는 이미지에
#       담지 않고 런타임에 APT 저장소에서 받는다.
#       furiosa-warboy/ 와 furiosa-rngd/ 두 설치기를 하나로 합친 것이다.
#       Warboy 저장소는 인증이 필요해 /secrets 마운트를 요구하고 RNGD 는 익명이다 —
#       그 분기는 entrypoint.sh 의 모델 표가 가른다.
# 생성일: 2026-09-09 | 수정일: 2026-09-23
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

# 사전 컴파일(prebuilt) 옵션: PREBUILD_KERNEL 과 PREBUILD_VARIANT 가 모두 지정되면 그 커널용
# 드라이버 모듈을 빌드해 이미지에 함께 굽는다. Furiosa 드라이버는 벤더가 DKMS 소스 패키지로
# 배포하므로(furiosa-driver-rngd 의 dkms.conf), 대상 커널 헤더를 받아 그 소스를 직접 컴파일한다.
# 산출물은 /opt/furiosa-ko/<variant>/<kernel>/ 아래에 .ko 와 vermagic 파일로 둔다. 값이 비어
# 있으면 기존 런타임 설치(호스트 apt → DKMS) 이미지와 동일하게 동작한다. 태그 규약은
# <pkgVersion>-<variant>-k<kernel>-vN 이며, Makefile 이 BUILD_VARIANT 로 이 태그를 넣는다.
# RNGD 저장소는 공개(Google Artifact Registry)라 자격 증명 없이 빌드된다. Warboy 는 인증이
# 필요한 사설 저장소(archive.furiosa.ai)에 있어 이 경로로 빌드할 수 없다 — 이미지에 secret 을
# 담지 않으므로 Warboy 사전 컴파일은 지원 대상에서 제외한다.
# 벤더 src/Makefile 은 최소 커널 판정에 KERNELDIR 이 아니라 KERNEL_VERSION(기본값 uname -r)을
# 쓰므로, 빌드 호스트가 아닌 대상 커널로 컴파일하려면 KERNEL_VERSION=<대상 커널> 을 넘긴다.
# 산출 .ko 의 vermagic 이 대상 커널로 시작하는지 빌드 시 확인해 잘못된 커널 산출물을 차단한다.
# 빌드 후 linux-headers·build-essential 은 purge 해 이미지 크기를 런타임 전용본 수준으로
# 유지한다(kmod·dkms 는 런타임 비-prebuilt 경로가 쓰므로 유지).
ARG PREBUILD_KERNEL=""
ARG PREBUILD_VARIANT=""
ARG PREBUILD_PKG_VERSION=""
RUN if [ -n "${PREBUILD_KERNEL}" ] && [ -n "${PREBUILD_VARIANT}" ]; then \
      set -eu; \
      test -n "${PREBUILD_PKG_VERSION}" || { echo "PREBUILD_PKG_VERSION 필수 (예: 2026.3.1)"; exit 1; }; \
      mkdir -p /etc/apt/trusted.gpg.d /etc/apt/sources.list.d; \
      curl -fsSL "https://packages.cloud.google.com/apt/doc/apt-key.gpg" \
        | gpg --dearmor > /etc/apt/trusted.gpg.d/furiosa-cloud.google.gpg; \
      echo 'deb [arch=amd64] http://asia-northeast3-apt.pkg.dev/projects/furiosa-ai jammy main' \
        > /etc/apt/sources.list.d/furiosa-rngd.list; \
      apt-get update; \
      apt-get install -y --no-install-recommends build-essential "linux-headers-${PREBUILD_KERNEL}"; \
      cd /tmp; \
      apt-get download "furiosa-driver-${PREBUILD_VARIANT}=${PREBUILD_PKG_VERSION}"; \
      dpkg-deb -x furiosa-driver-${PREBUILD_VARIANT}_${PREBUILD_PKG_VERSION}_*.deb /; \
      src="/usr/src/furiosa-driver-${PREBUILD_VARIANT}-${PREBUILD_PKG_VERSION}"; \
      ( cd "${src}/src" && make KERNELDIR="/lib/modules/${PREBUILD_KERNEL}/build" KERNEL_VERSION="${PREBUILD_KERNEL}" vf=0 ); \
      dest="/opt/furiosa-ko/${PREBUILD_VARIANT}/${PREBUILD_KERNEL}"; \
      mkdir -p "${dest}"; \
      cp "${src}/src"/*.ko "${dest}/"; \
      vm="$(modinfo -F vermagic "${dest}"/*.ko | head -1)"; \
      case "${vm}" in "${PREBUILD_KERNEL} "*) : ;; *) echo "[ERR] vermagic '${vm}' 가 대상 커널 ${PREBUILD_KERNEL} 로 시작하지 않는다"; exit 1 ;; esac; \
      echo "${vm}" > "${dest}/vermagic"; \
      echo "[INFO] prebuilt ${PREBUILD_VARIANT} ${PREBUILD_PKG_VERSION} for ${PREBUILD_KERNEL}: ${vm}"; \
      rm -rf "${src}"; \
      apt-get purge -y build-essential "linux-headers-${PREBUILD_KERNEL}"; \
      apt-get autoremove -y; \
      rm -rf /var/lib/apt/lists/* /tmp/*.deb; \
    fi

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
