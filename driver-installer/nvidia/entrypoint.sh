#!/usr/bin/env bash
# ============================================================
# entrypoint.sh: NVIDIA 드라이버 및 컨테이너 툴킷 설치 스크립트
# 상세: Host namespace(nsenter)에서 GPU 드라이버 설치, nvidia-ctk 설정, containerd/docker 런타임 구성
# 생성일: 2026-04-17 | 수정일: 2026-09-09
# ============================================================
set -Eeuo pipefail
[[ "${DEBUG:-0}" == "1" ]] && set -x

# ============================================================================ #
# Host namespace helper
# ============================================================================ #
ns() { nsenter --target 1 --mount --uts --ipc --net --pid -- bash -lc "$*"; }

log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*" >&2; }
log_error() { echo "[ERR]  $*" >&2; }

# 마커 디렉토리 (passthrough 가드가 하위 MAIN FLOW 보다 먼저 참조하므로 상단에서 정의)
MARKER_DIR="${MARKER_DIR:-/var/lib/kcloud-operator}"

# 마커 디렉터리 개명 이관(npu-operator → kcloud-operator). 1회 수행되고 멱등이다.
# 아래 어떤 MARKER_DIR 사용보다 먼저 와야 한다.
# shellcheck source=/dev/null
. /usr/local/bin/marker-migrate.sh
migrate_marker_dir "${MARKER_DIR}"

# ============================================================================ #
# 안전장치 동작 env (기본값 = 기존 동작 보존, 하위호환)
#   SKIP_ON_PASSTHROUGH (기본 true) : (a) GPU 전량 vfio-pci 바인딩 시 설치 보류
#   ALLOW_DOWNGRADE     (기본 false): (b) 하위 버전 다운그레이드 허용 여부
#   VERSION_SOURCE      (기본 Policy): (c) Host=호스트 설치 버전을 desired 로 채택
# ============================================================================ #
SKIP_ON_PASSTHROUGH="${SKIP_ON_PASSTHROUGH:-true}"
ALLOW_DOWNGRADE="${ALLOW_DOWNGRADE:-false}"
VERSION_SOURCE="${VERSION_SOURCE:-Policy}"

# RUN_MODE (WP-C-1): 설치 완료 후 동작을 결정한다.
#   daemonset (기본) : 기존 동작 — 상주 healthcheck 루프로 무한 대기(회귀 0).
#   job              : 순간 install Job — 설치/skip 완료 후 exit 0(상주 안 함).
# 미지정 시 daemonset 으로 동작하여 기존 DS 이미지와 완전 하위호환.
RUN_MODE="${RUN_MODE:-daemonset}"

# MANAGE_CONTAINER_TOOLKIT (#17 a1/조건3): 이 드라이버 설치기가 컨테이너 툴킷 설치·
# containerd/CDI 런타임 설정·containerd/kubelet 재시작을 수행할지 여부.
#   기본 false — 런타임 설정 소유권은 상주 nvidia-container-toolkit DS 단독(이중 소유 금지).
#   드라이버 설치기는 커널 모듈 + userspace(host apt) 설치와 /dev 노드 생성까지만 책임진다.
#   true 로 설정하면 legacy 동작(설치기가 툴킷·런타임까지 구성) 복원 — toolkit DS 미상주
#   클러스터용 opt-in.
MANAGE_CONTAINER_TOOLKIT="${MANAGE_CONTAINER_TOOLKIT:-false}"

# ============================================================================ #
# 드라이버 선택 우선순위
#   1) LOCAL_DRIVER_CHOICE        (로컬 docker run 테스트용)
#   2) NVIDIA_DRIVER_CHOICE       (수동 env 지정 시)
#   3) DRIVER_VERSION             (DriverInstallPolicy.spec.driver.version)
#   4) ubuntu-drivers devices 기반 recommended 계열 + autoinstall
# ============================================================================ #


choose_driver_candidates() {
  local candidates=()

  # 우선순위: 1) DRIVER_VERSION, 2) LOCAL_DRIVER_CHOICE, 3) NVIDIA_DRIVER_CHOICE
  local driver_version="${DRIVER_VERSION:-}"
  local local_choice="${LOCAL_DRIVER_CHOICE:-}"
  local policy_choice="${NVIDIA_DRIVER_CHOICE:-}"

  # 1) DRIVER_VERSION (Operator DriverInstallPolicy.spec.driver.version → env로 들어온 값)
  #    버전 번호(예: 590.48.01)이면 메이저 버전을 추출하여 패키지명으로 변환
  if [[ -n "${driver_version}" ]]; then
    log_info "DRIVER_VERSION specified (from policy): ${driver_version}"
    local major_ver="${driver_version%%.*}"
    if [[ "${major_ver}" =~ ^[0-9]+$ ]]; then
      # 숫자로 시작하면 버전 번호 → 패키지명 변환 (nvidia-driver-590)
      local pkg_name="nvidia-driver-${major_ver}"
      log_info "Resolved DRIVER_VERSION ${driver_version} → package: ${pkg_name}"
      candidates+=("${pkg_name}")
    else
      # 이미 패키지명 형태 (nvidia-driver-590 등)
      candidates+=("${driver_version}")
    fi
  fi

  # 2) LOCAL_DRIVER_CHOICE (로컬 docker run 테스트용 최우선 수동 오버라이드)
  if [[ -n "${local_choice}" ]]; then
    if [[ "${local_choice}" != "${driver_version}" ]]; then
      log_info "LOCAL_DRIVER_CHOICE specified: ${local_choice}"
      candidates+=("${local_choice}")
    else
      log_info "LOCAL_DRIVER_CHOICE '${local_choice}' == DRIVER_VERSION; skipping duplicate"
    fi
  fi

  # 3) NVIDIA_DRIVER_CHOICE (Operator에서 env로 직접 세팅하는 경우)
  if [[ -n "${policy_choice}" ]]; then
    if [[ "${policy_choice}" != "${driver_version}" && "${policy_choice}" != "${local_choice}" ]]; then
      log_info "NVIDIA_DRIVER_CHOICE (env) specified: ${policy_choice}"
      candidates+=("${policy_choice}")
    else
      log_info "NVIDIA_DRIVER_CHOICE '${policy_choice}' already in candidates; skipping duplicate"
    fi
  fi

  # 4) 위 세 가지 모두 없으면 ubuntu-drivers devices 기반 추천 사용
  if [[ ${#candidates[@]} -eq 0 ]]; then
    log_info "No explicit driver choice; using ubuntu-drivers devices recommended order"

    local rec ver server_pkg server_open_pkg
    rec="$(ns "ubuntu-drivers devices 2>/dev/null | awk '/recommended/ {print \$3}' | tail -n1" || true)"

    if [[ -z "${rec}" ]]; then
      log_warn "No recommended driver found by ubuntu-drivers; falling back to ubuntu-drivers autoinstall later"
    else
      log_info "ubuntu-drivers recommended: ${rec}"
      if [[ "${rec}" =~ ^nvidia-driver-([0-9]+) ]]; then
        ver="${BASH_REMATCH[1]}"
        server_pkg="nvidia-driver-${ver}-server"
        server_open_pkg="nvidia-driver-${ver}-server-open"

        # 요구 순서: <ver>-server -> <ver>-server-open -> <ver>(=rec)
        candidates+=("${server_pkg}" "${server_open_pkg}" "${rec}")
      else
        log_warn "Could not parse version from recommended (${rec}); using it as single candidate"
        candidates+=("${rec}")
      fi
    fi
  fi

  # 5) DRIVER_VERSION이 명시되지 않은 경우에만 ubuntu-drivers autoinstall fallback 추가
  #    명시된 경우 잘못된 버전이 설치되는 것을 방지
  if [[ -z "${driver_version}" ]]; then
    candidates+=("__UBUNTU_DRIVERS_AUTOINSTALL__")
  fi

  # 배열을 전역 변수로 넘김
  DRIVER_CANDIDATES=("${candidates[@]}")
}

# ============================================================================ #
# apt / dpkg helpers
# ============================================================================ #
apt_wait() {
  ns "bash -lc '
    for i in {1..180}; do
      if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
         && ! fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
         && ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
        exit 0
      fi
      sleep 2
    done
    echo \"[ERR] dpkg/apt lock held too long\" >&2
    exit 1
  '"
}

apt_update() {
  apt_wait
  ns "apt-get update -y" || { log_error "apt-get update failed"; return 1; }
}

apt_install() {
  apt_wait
  ns "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $*" || return 1
}

# ============================================================================ #
# Driver health check
# ============================================================================ #
driver_healthy() {
  local expected_major="${1:-}"
  if ! ns "test -f /proc/driver/nvidia/version" 2>/dev/null; then
    log_warn "/proc/driver/nvidia/version not found"
    return 1
  fi
  if ! ns "nvidia-smi -L >/dev/null 2>&1"; then
    log_warn "nvidia-smi query failed"
    return 1
  fi
  # 기대 메이저 버전이 지정된 경우 로드된 버전과 비교
  if [[ -n "${expected_major}" ]]; then
    local loaded_ver
    loaded_ver=$(ns "cat /proc/driver/nvidia/version 2>/dev/null" | grep -oP 'NVRM version: \K[0-9]+\.[0-9]+\.[0-9]+' || true)
    local loaded_major="${loaded_ver%%.*}"
    if [[ "${loaded_major}" != "${expected_major}" ]]; then
      log_warn "Version mismatch: loaded=${loaded_ver} (major ${loaded_major}), expected major=${expected_major}"
      return 1
    fi
    log_info "Version verified: loaded=${loaded_ver}, expected major=${expected_major}"
  fi
  return 0
}

# ============================================================================ #
# 안전장치 헬퍼: passthrough 감지 · 버전 비교
# ============================================================================ #

# 호스트 PCI 를 순회하며 NVIDIA GPU 의 "<total> <installable>" 개수를 출력한다.
#   total       : NVIDIA(0x10de) & display class(0x03xxxx) 장치 총 개수
#   installable : 그 중 driver 바인딩이 vfio-pci 가 아닌(=nvidia/미바인딩) 장치 개수
# 집계는 단일 ns 호출(호스트 mount namespace)에서 수행하여 왕복/쿼팅을 최소화한다.
nvidia_gpu_bindings() {
  ns 'total=0; installable=0
    for d in /sys/bus/pci/devices/*/; do
      [ -r "${d}vendor" ] || continue
      vendor=$(cat "${d}vendor" 2>/dev/null || echo "")
      class=$(cat "${d}class" 2>/dev/null || echo "")
      [ "$vendor" = "0x10de" ] || continue
      case "$class" in 0x03*) ;; *) continue ;; esac
      total=$((total+1))
      bound=""
      if [ -L "${d}driver" ]; then
        bound=$(basename "$(readlink "${d}driver")" 2>/dev/null || echo "")
      fi
      [ "$bound" != "vfio-pci" ] && installable=$((installable+1))
    done
    echo "$total $installable"'
}

# 설치 대상 GPU 존재 여부.
#   반환 0(true)  : installable GPU 가 1개 이상 있거나, GPU 가 아예 없는 비-GPU 노드(가드 미적용)
#   반환 1(false) : GPU 는 있으나 전량 vfio-pci 바인딩(passthrough)
nvidia_has_installable_gpu() {
  local out total installable
  out=$(nvidia_gpu_bindings 2>/dev/null | tail -n1 || echo "0 0")
  total=$(echo "$out" | awk '{print $1+0}')
  installable=$(echo "$out" | awk '{print $2+0}')
  # 비-GPU 노드는 가드 미적용 → 기존 동작 유지
  [ "${total:-0}" -eq 0 ] && return 0
  [ "${installable:-0}" -gt 0 ] && return 0
  return 1
}

# 버전 비교: $1 > $2 이면 0(true). dpkg 로 정상 비교되면 그 결과, 형식오류 등으로
# dpkg 가 판정 불가하면 major 정수 비교로 fallback.
ver_gt() {
  local a="$1" b="$2" am bm
  if ns "dpkg --compare-versions '${a}' gt '${b}'" >/dev/null 2>&1; then
    return 0
  elif ns "dpkg --compare-versions '${a}' le '${b}'" >/dev/null 2>&1; then
    return 1
  fi
  # dpkg 가 gt/le 모두 판정 실패 → 형식 문제로 간주, major 정수 비교 fallback
  am="${a%%.*}"; bm="${b%%.*}"
  if [[ "$am" =~ ^[0-9]+$ && "$bm" =~ ^[0-9]+$ ]] && [[ "$am" -gt "$bm" ]]; then
    return 0
  fi
  return 1
}

print_dkms_logs_if_any() {
  ns "bash -lc '
    shopt -s nullglob
    for d in /var/lib/dkms/nvidia*/[0-9]*/build; do
      if [ -f \"\$d/make.log\" ]; then
        echo
        echo \"========== DKMS make.log from \$d ==========\"
        tail -n 60 \"\$d/make.log\" || true
        echo \"==========================================\"
        echo
      fi
    done
  '" || true
}

# ============================================================================ #
# 하나의 driver 패키지 설치 + DKMS + 모듈 로드 + health 체크
# ============================================================================ #
install_and_activate_driver() {
  local pkg="$1"
  local expected_major="${2:-}"

  if [[ "${pkg}" == "__UBUNTU_DRIVERS_AUTOINSTALL__" ]]; then
    log_info "Trying ubuntu-drivers autoinstall as fallback"
    apt_wait
    ns "DEBIAN_FRONTEND=noninteractive ubuntu-drivers autoinstall || true"
  else
    log_info "Installing driver package: ${pkg}"
    ns "rm -f /var/crash/nvidia-kernel-source-* /var/crash/*nvidia*.crash 2>/dev/null || true"
    # 드라이버 패키지는 --no-install-recommends 없이 설치 (커널 모듈 패키지 포함 필요)
    apt_wait
    if ! ns "DEBIAN_FRONTEND=noninteractive apt-get install -y ${pkg}"; then
      log_error "apt-get install ${pkg} failed"
      return 1
    fi
  fi

  # 설치된 드라이버 패키지를 manual로 마킹 (autoremove 방지)
  if [[ -n "${expected_major}" ]]; then
    log_info "Marking nvidia-driver-${expected_major} packages as manually installed..."
    ns "apt-mark manual nvidia-driver-${expected_major} nvidia-dkms-${expected_major} nvidia-kernel-source-${expected_major} 2>/dev/null || true"
  fi

  # stale 모듈이 남아있으면 제거 후 새 모듈 로드
  log_info "Removing any stale nvidia kernel modules before modprobe..."
  ns "rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null || true"

  # dpkg configure 완료 대기 (nvidia-dkms 패키지가 iU 상태일 수 있음)
  log_info "Ensuring all packages are fully configured (dpkg --configure -a)..."
  ns "dpkg --configure -a 2>/dev/null || true"

  # DKMS / depmod / modprobe
  log_info "Running 'dkms autoinstall -k ${CURRENT_KERNEL}'..."
  ns "dkms autoinstall -k ${CURRENT_KERNEL} || true"

  log_info "Running 'depmod -a ${CURRENT_KERNEL}'..."
  ns "depmod -a ${CURRENT_KERNEL} || true"

  log_info "Trying to load NVIDIA kernel modules..."
  ns "modprobe nvidia || true"
  ns "modprobe nvidia_uvm || true"
  ns "modprobe nvidia_drm || true"

  if driver_healthy "${expected_major}"; then
    log_info "Driver '${pkg}' installed and GPU is healthy (major: ${expected_major:-any})"
    return 0
  fi

  log_error "Driver '${pkg}' installed but GPU not healthy or version mismatch"
  print_dkms_logs_if_any
  # 실패한 모듈 정리
  ns "rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null || true"
  return 1
}

# ============================================================================ #
# CRI detection (containerd / docker)
# ============================================================================ #
detect_cri() {
  local cri="${NVIDIA_CRI:-auto}"
  case "${cri}" in
    containerd|docker) echo "${cri}"; return 0 ;;
    auto) ;;
    *) echo "containerd"; return 0 ;;
  esac
  if ns "systemctl is-active --quiet containerd"; then echo "containerd"; return 0; fi
  if ns "systemctl is-active --quiet docker"; then echo "docker"; return 0; fi
  echo "containerd"
}

# ============================================================================ #
# 디바이스 노드 보장 (#17 ④)
# 모듈만 로드되고 노드 생성 프로세스가 없으면 /dev/nvidia0·nvidiactl·nvidia-uvm 이
# 부재하여 toolkit CDI generate·GPU 파드가 데드락한다(idempotent-skip 경로에서 특히).
# 설치/skip 무관하게 nvidia-modprobe 로 노드를 생성하고, 부재 시 nvidia-smi 로 fallback.
# host namespace(nsenter)에서 host userspace 바이너리를 사용 — a1 host-install 전제와 정합.
# ============================================================================ #
ensure_device_nodes() {
  log_info "Ensuring /dev/nvidia* device nodes (nvidia-modprobe)"
  # -c0: control 0 + /dev/nvidia0, -u: nvidia-uvm 노드, -m: modeset 노드
  ns "nvidia-modprobe -c0 -u -m 2>/dev/null || true"
  # nvidia-smi 는 모든 GPU minor 에 대해 /dev/nvidiaN 을 생성한다(다중 GPU 커버).
  # nvidia-modprobe 부재/실패 시 fallback.
  ns "test -e /dev/nvidia0 || nvidia-smi >/dev/null 2>&1 || true"
  if ns "test -e /dev/nvidia0"; then
    log_info "device node /dev/nvidia0 present"
  else
    log_warn "device node /dev/nvidia0 여전히 부재 — GPU 파드가 실패할 수 있음(수동 확인 필요)"
  fi
}

# ============================================================================ #
# MAIN FLOW
# ============================================================================ #

log_info "Starting NVIDIA driver installation"

CURRENT_KERNEL=$(ns "uname -r")
log_info "CURRENT_KERNEL=${CURRENT_KERNEL}"

# --- PASSTHROUGH GUARD (a) ---
# 호스트의 모든 NVIDIA GPU 가 vfio-pci(passthrough)에 바인딩된 노드면 드라이버 설치를 보류한다.
# GPU 가 없는 비-GPU 노드는 가드 미적용(기존 동작 유지). installable GPU 가 1개라도 있으면 정상 진행.
if [[ "${SKIP_ON_PASSTHROUGH:-true}" != "false" ]] && ! nvidia_has_installable_gpu; then
  log_info "All NVIDIA GPUs bound to vfio-pci (passthrough) — skipping driver install"
  ns "mkdir -p ${MARKER_DIR}" || true
  ns "touch ${MARKER_DIR}/passthrough-skip" || true
  SKIP_DRIVER_INSTALL=1
  # 설치/toolkit/modprobe 를 모두 건너뛰고 Pod 는 Running 유지 (idle 루프)
  ns "touch ${MARKER_DIR}/driver.ready" || true
  touch /tmp/driver-ready
  if [[ "${RUN_MODE}" == "job" ]]; then
    log_info "RUN_MODE=job + passthrough skip — 설치 대상 없음, exit 0"
    exit 0
  fi
  log_info "passthrough 노드 — idle 루프 진입 (드라이버 설치/toolkit 미수행, modprobe 없음)"
  while true; do sleep "${HEALTH_CHECK_INTERVAL:-30}"; done
fi

# --- PRE-INSTALL CLEANUP ---
log_info "Pre-install cleanup: dpkg state, locks, crash reports"
ns "bash -lc '
  dpkg --configure -a 2>/dev/null || true
  rm -f /var/lib/dpkg/lock* /var/cache/apt/archives/lock 2>/dev/null || true
  rm -f /var/crash/nvidia-kernel-source-*.crash /var/crash/*nvidia*.crash 2>/dev/null || true
'"

# --- BASE TOOLS ---
log_info "Apt update + base tools"
apt_update
apt_install ubuntu-drivers-common jq curl gnupg ca-certificates software-properties-common build-essential dkms || true

log_info "Ensuring NVIDIA PPA"
ns "add-apt-repository -y ppa:graphics-drivers/ppa >/dev/null 2>&1 || true"
apt_update

# --- KERNEL HEADERS & MODULES ---
log_info "Checking kernel headers and modules for ${CURRENT_KERNEL}"

if ns "[[ -d /usr/src/linux-headers-${CURRENT_KERNEL} ]]"; then
  log_info "Found kernel headers: /usr/src/linux-headers-${CURRENT_KERNEL}"
else
  log_info "linux-headers-${CURRENT_KERNEL} not found; trying to install..."
  if ! apt_install "linux-headers-${CURRENT_KERNEL}"; then
    log_warn "Failed to install linux-headers-${CURRENT_KERNEL}; trying linux-headers-generic"
    apt_install linux-headers-generic || log_warn "linux-headers-generic install failed as well"
  fi
fi

if ns "[[ -d /lib/modules/${CURRENT_KERNEL} ]]"; then
  log_info "Found /lib/modules/${CURRENT_KERNEL}"
else
  log_warn "/lib/modules/${CURRENT_KERNEL} not found; trying linux-modules-extra-${CURRENT_KERNEL}"
  apt_install "linux-modules-extra-${CURRENT_KERNEL}" || log_warn "linux-modules-extra-${CURRENT_KERNEL} install failed"
fi

log_info "Holding kernel packages to prevent unintended upgrades"
ns "apt-mark hold linux-image-generic linux-headers-generic || true"
ns "apt-mark hold linux-image-${CURRENT_KERNEL} || true"
ns "apt-mark hold linux-headers-${CURRENT_KERNEL} || true"
ns "apt-mark hold linux-modules-extra-${CURRENT_KERNEL} || true"

apt_install build-essential dkms gcc make || true

# --- EXISTING DRIVER CHECK ---
EXISTING_VER=""
if ns "test -f /proc/driver/nvidia/version" 2>/dev/null; then
  EXISTING_VER=$(ns "cat /proc/driver/nvidia/version 2>/dev/null" | grep -oP 'NVRM version: \K[0-9]+\.[0-9]+\.[0-9]+' || true)
  log_info "Existing NVIDIA driver detected (loaded): ${EXISTING_VER}"
fi

# driver-manager가 모듈을 해제한 경우에도 설치된 패키지 버전 확인
if [[ -z "${EXISTING_VER}" ]]; then
  INSTALLED_PKG_VER=$(ns "dpkg-query -W -f='\${Status} \${Version}\n' 'nvidia-driver-*' 2>/dev/null | grep '^install' | awk '{print \$4}' | head -1" || true)
  if [[ -n "${INSTALLED_PKG_VER}" ]]; then
    # dpkg 버전에서 upstream 버전만 추출 (580.126.09-0ubuntu... → 580.126.09)
    EXISTING_VER=$(echo "${INSTALLED_PKG_VER}" | grep -oP '^[0-9]+\.[0-9]+\.[0-9]+' || echo "${INSTALLED_PKG_VER}")
    log_info "Existing NVIDIA driver detected (package): ${EXISTING_VER}"
  fi
fi

# --- HOST VERSION RESPECT (c) ---
# VERSION_SOURCE=Host 이고 호스트에 드라이버가 설치돼 있으면 그 버전을 effective desired 로
# 채택하고 설치를 보류(존중)한다. 호스트에 드라이버가 없으면 policy DRIVER_VERSION 으로 fallback.
if [[ "${VERSION_SOURCE:-Policy}" == "Host" ]]; then
  if [[ -n "${EXISTING_VER}" ]]; then
    log_info "VERSION_SOURCE=Host, adopting existing host driver ${EXISTING_VER} as desired (skip install)"
    DRIVER_VERSION="${EXISTING_VER}"
    SKIP_DRIVER_INSTALL=1
  else
    log_info "VERSION_SOURCE=Host but no host driver detected — falling back to policy DRIVER_VERSION=${DRIVER_VERSION:-<unset>}"
  fi
fi

# If requested version matches existing, skip driver install
if [[ -n "${DRIVER_VERSION:-}" && -n "${EXISTING_VER}" && "${DRIVER_VERSION}" == "${EXISTING_VER}" ]]; then
  if driver_healthy; then
    log_info "Requested driver version ${DRIVER_VERSION} already installed and healthy, skipping driver install"
    # Jump to toolkit section
    SKIP_DRIVER_INSTALL=1
  fi
fi

# If different version exists, purge first
# 동일 버전이지만 unhealthy한 경우 purge하지 않고 repair (dpkg --configure + dkms)
DESIRED_MAJOR="${DRIVER_VERSION%%.*}"
EXISTING_MAJOR="${EXISTING_VER%%.*}"

# --- DOWNGRADE GUARD (b) ---
# 기존 설치 버전이 desired 보다 최신이면(major 동일/상이 무관) 다운그레이드를 방지하고 기존을 유지한다.
# ALLOW_DOWNGRADE=true 일 때만 하위 버전 설치(purge→install)를 허용.
if [[ -n "${EXISTING_VER}" && "${SKIP_DRIVER_INSTALL:-0}" != "1" && -n "${DRIVER_VERSION:-}" ]]; then
  if ver_gt "${EXISTING_VER}" "${DRIVER_VERSION}" && [[ "${ALLOW_DOWNGRADE:-false}" != "true" ]]; then
    log_warn "Existing driver ${EXISTING_VER} > desired ${DRIVER_VERSION}; downgrade disabled (ALLOW_DOWNGRADE=false) → keep existing, skip install"
    SKIP_DRIVER_INSTALL=1
  fi
fi

if [[ -n "${EXISTING_VER}" && "${SKIP_DRIVER_INSTALL:-0}" != "1" && "${EXISTING_MAJOR}" != "${DESIRED_MAJOR}" ]]; then
  # 기존 메이저 버전 추출
  OLD_MAJOR="${EXISTING_VER%%.*}"
  log_info "Purging existing NVIDIA driver ${EXISTING_VER} (major: ${OLD_MAJOR})"

  # driver-manager initContainer가 이미 모듈을 해제했는지 확인
  if ns "lsmod | grep -q '^nvidia '"; then
    log_info "nvidia 모듈이 아직 로드됨 — rmmod 후 purge"
    ns "bash -lc '
      systemctl stop nvidia-persistenced 2>/dev/null || true
      rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null || true
    '"
  else
    log_info "nvidia 모듈 이미 해제됨 (driver-manager initContainer)"
  fi

  # 기존 버전의 모든 nvidia 패키지 제거 (libnvidia-* 포함)
  log_info "Purging all nvidia packages with major version ${OLD_MAJOR}"
  ns "bash -lc '
    DEBIAN_FRONTEND=noninteractive apt-get purge -y \$(dpkg-query -W -f=\"\\\${Package}\\n\" 2>/dev/null | grep -i nvidia | grep \"${OLD_MAJOR}\") 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get purge -y \$(dpkg-query -W -f=\"\\\${Package}\\n\" 2>/dev/null | grep -i \"linux-modules-nvidia.*${OLD_MAJOR}\") 2>/dev/null || true
    dkms remove nvidia/${OLD_MAJOR} --all 2>/dev/null || true
    depmod -a 2>/dev/null || true
    rm -f /var/lib/kcloud-operator/nvidia.ok 2>/dev/null || true
  '"

  # 잔여 패키지 확인
  REMAINING=$(ns "dpkg-query -W -f='\${Status} \${Package}\n' 2>/dev/null | grep '^install' | grep -i nvidia | grep '${OLD_MAJOR}' | wc -l" || echo "0")
  if [[ "${REMAINING}" -gt 0 ]]; then
    log_warn "Remaining ${OLD_MAJOR} packages after purge: ${REMAINING}"
    ns "dpkg-query -W -f='\${Status} \${Package}\n' 2>/dev/null | grep '^install' | grep -i nvidia | grep '${OLD_MAJOR}'" || true
  fi

  apt_update
fi

# --- DRIVER SELECTION & INSTALL ---
if [[ "${SKIP_DRIVER_INSTALL:-0}" != "1" ]]; then
  choose_driver_candidates
  log_info "Driver candidate order: ${DRIVER_CANDIDATES[*]}"

  # DRIVER_VERSION에서 기대 메이저 버전 추출 (버전 검증용)
  EXPECTED_MAJOR=""
  if [[ -n "${DRIVER_VERSION:-}" ]]; then
    EXPECTED_MAJOR="${DRIVER_VERSION%%.*}"
  fi

  INSTALL_SUCCESS=0
  for cand in "${DRIVER_CANDIDATES[@]}"; do
    if [[ "${cand}" == "__UBUNTU_DRIVERS_AUTOINSTALL__" ]]; then
      log_info "Trying ubuntu-drivers autoinstall as last resort"
    else
      log_info "Trying driver candidate: ${cand}"
    fi

    if install_and_activate_driver "${cand}" "${EXPECTED_MAJOR}"; then
      INSTALL_SUCCESS=1
      break
    else
      log_warn "Driver candidate failed: ${cand}"
    fi
  done

  if [[ "${INSTALL_SUCCESS}" -ne 1 ]]; then
    # --- S2-5 WP-R2 (P2 fix): cross-major 로드 지연은 install 실패가 아니다 -------------------
    # 실 cross-major 전환에서는 구 major 모듈이 busy(GPU 홀더/커널 refcount)라 in-container rmmod 가
    # 실패하고, 신 모듈 modprobe 가 "Unknown symbol" 로 실패한다 → driver_healthy 가 version-mismatch 로
    # 판정해 모든 candidate 가 실패한다. 그러나 타겟 드라이버 패키지는 이미 설치 완료됐고 신 모듈은
    # "재부팅 후" 로드된다. 이 상태를 install 실패(exit 1 → rollback → Failed)로 처리하면 자연 마커가
    # 생성되지 않아 operator 의 RebootRequired→reboot 경로가 절대 발화하지 못한다(자연 마커 unreachable 결함).
    # → 타겟 패키지 설치됨 + 서로 다른 major 모듈이 로드된 상태면 needs-reboot 마커를 남기고 정상 종료하여
    #   재부팅으로 신 모듈 로드를 위임한다(detector→NDR.needsReboot→RebootRequired→reboot Job).
    # 판정 신호(견고성): /proc 는 구 모듈이 broken half-load 상태면 비어 있을 수 있으므로 신뢰하지 않는다.
    #   - TARGET_PKG_OK: 타겟 드라이버 패키지가 dpkg 상 설치 완료.
    #   - TARGET_MOD_READY: 디스크의 nvidia.ko(modprobe 가 로드할 모듈)의 버전 major == 타겟 major
    #       → DKMS 빌드가 성공해 "재부팅하면 로드될 신 모듈"이 준비됨(진짜 빌드 실패면 이 값이 타겟과 불일치 → 가드 미발동).
    #   - ACTIVE_IS_TARGET: 현재 /proc 로 관측되는 실행 중 버전 major == 타겟 major (이미 로드됐으면 마커 불필요).
    # 신 모듈은 준비됐으나(빌드됨) 현재 구 모듈이 busy/broken 이라 로드 안 된 상태 → 재부팅 위임.
    TARGET_PKG_OK=$(ns "dpkg-query -W -f='\${Status}' nvidia-driver-${EXPECTED_MAJOR} 2>/dev/null" | grep -c 'install ok installed' || echo 0)
    DISK_MOD_VER=$(ns "modinfo -k ${CURRENT_KERNEL} -F version nvidia 2>/dev/null" | head -1)
    DISK_MOD_MAJOR="${DISK_MOD_VER%%.*}"
    ACTIVE_NVRM=$(ns "cat /proc/driver/nvidia/version 2>/dev/null" | grep -oP 'NVRM version: \K[0-9]+\.[0-9]+\.[0-9]+' || echo "")
    ACTIVE_MAJOR="${ACTIVE_NVRM%%.*}"
    if [[ -n "${EXPECTED_MAJOR}" && "${TARGET_PKG_OK}" -ge 1 \
          && "${DISK_MOD_MAJOR}" == "${EXPECTED_MAJOR}" \
          && "${ACTIVE_MAJOR}" != "${EXPECTED_MAJOR}" ]]; then
      case "${REBOOT_STRATEGY:-IfNeeded}" in
        Never)
          log_error "cross-major reboot-deferred(target ${EXPECTED_MAJOR} 모듈 준비됨, active=${ACTIVE_MAJOR:-none}) 이나 rebootStrategy=Never — 재부팅 없이 신 모듈 로드 불가 → install 실패"
          exit 1 ;;
        *)
          log_warn "cross-major reboot-deferred(target ${EXPECTED_MAJOR} 모듈 디스크 준비 완료, 현재 active=${ACTIVE_MAJOR:-none/broken} — 구 모듈 busy/broken) — needs-reboot 마커 생성 후 정상 종료(reboot 위임)."
          ns "mkdir -p ${MARKER_DIR}; touch ${MARKER_DIR}/needs-reboot" || true
          if [ "${RUN_MODE}" = "job" ]; then
            log_info "RUN_MODE=job — cross-major reboot-deferred, install Job 정상 종료(exit 0)"
            exit 0
          fi
          exec sleep infinity ;;
      esac
    fi
    # ------------------------------------------------------------------------------------------
    log_error "All driver candidates failed; please inspect DKMS logs above."
    exit 1
  fi
fi

# ============================================================================ #
# 디바이스 노드 보장 (#17 ④) — 설치/skip 무관, toolkit/runtime 설정 이전에 수행
# ============================================================================ #
ensure_device_nodes

# ============================================================================ #
# NVIDIA CONTAINER TOOLKIT + RUNTIME 설정 (#17 조건3.1 — 기본 비활성)
# 런타임(containerd/CDI) 설정 소유권은 상주 nvidia-container-toolkit DS 단독(이중 소유 금지).
# MANAGE_CONTAINER_TOOLKIT=true 일 때만 legacy 경로(설치기가 툴킷·런타임까지 구성)를 수행한다.
# ============================================================================ #
if [[ "${MANAGE_CONTAINER_TOOLKIT}" == "true" ]]; then
log_info "MANAGE_CONTAINER_TOOLKIT=true — 컨테이너 툴킷 설치 + 런타임 설정 수행(legacy 경로)"
log_info "Installing NVIDIA Container Toolkit"

apt_wait
ns "curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor --batch --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
ns "curl -sSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list"
ns "sed -i -e '/experimental/ s/^#//g' /etc/apt/sources.list.d/nvidia-container-toolkit.list"
apt_update

CTK_VER="${NVIDIA_CONTAINER_TOOLKIT_VERSION:-}"
if [[ -n "${CTK_VER}" ]]; then
  log_info "Installing pinned CTK version: ${CTK_VER}"
  apt_wait
  ns "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --allow-downgrades \
      nvidia-container-toolkit=${CTK_VER} nvidia-container-toolkit-base=${CTK_VER}"
else
  log_info "Installing latest CTK"
  apt_install nvidia-container-toolkit nvidia-container-toolkit-base
fi

# ============================================================================ #
# RUNTIME CONFIGURE & CDI
# ============================================================================ #
RUNTIME="$(detect_cri)"
log_info "Configuring nvidia-ctk for runtime: ${RUNTIME}"

case "${RUNTIME}" in
  containerd)
    ns "nvidia-ctk runtime configure --runtime=containerd --set-as-default || true"
    # config_path 와 mirrors/configs 공존 시 containerd 1.7+ 에서 CRI plugin 로드 실패.
    # nvidia-ctk 가 남긴 registry.mirrors/configs 블록을 제거하여 재발 방지.
    # nvidia-ctk v1.19+ → conf.d drop-in, v1.17 이하 → main config 대상 — 둘 다 처리.
    for cfg in /etc/containerd/config.toml /etc/containerd/conf.d/99-nvidia.toml; do
      ns "[[ -f '${cfg}' ]]" || continue
      ns "grep -q 'config_path' '${cfg}'" || continue
      ns "python3 -c \"
import re
p='${cfg}'
c=open(p).read()
c=re.sub(r'\\n\\s*\\[plugins\\.\\\"io\\.containerd\\.grpc\\.v1\\.cri\\\"\\.registry\\.(mirrors|configs)[^\\n]*\\][\\s\\S]*?(?=\\n\\s*\\[|\\Z)','',c)
open(p,'w').write(c)\""
      log_info "Stripped registry.mirrors/configs from ${cfg} (config_path present)"
    done
    # nvidia-ctk 가 runc 의 binaryName 을 복사해 두 키가 공존하는 현상 정리.
    # lowercase binaryName 제거, 대문자 BinaryName 유지.
    for cfg in /etc/containerd/config.toml /etc/containerd/conf.d/99-nvidia.toml; do
      ns "[[ -f '${cfg}' ]]" || continue
      ns "python3 -c \"
import re
p='${cfg}'
c=open(p).read()
c=re.sub(r'(\\[plugins\\.\\\"io\\.containerd\\.grpc\\.v1\\.cri\\\"\\.containerd\\.runtimes\\.nvidia\\.options\\]\\n(?:.*\\n)*?)\\s*binaryName\\s*=\\s*\\\"[^\\\"]*\\\"\\n',r'\\1',c)
open(p,'w').write(c)\""
      log_info "Removed stale binaryName from ${cfg} (kept BinaryName)"
    done
    ns 'mkdir -p /etc/containerd/config.d'
    ns "cat > /etc/containerd/config.d/99-nvidia.toml <<EOF
[plugins.\"io.containerd.grpc.v1.cri\".containerd]
  default_runtime_name = \"nvidia\"
EOF"
    ;;
  docker)
    ns "nvidia-ctk runtime configure --runtime=docker --set-as-default || true"
    ;;
esac

# Verify containerd can see NVIDIA runtime
if [[ "${RUNTIME}" == "containerd" ]]; then
  log_info "Verifying containerd NVIDIA runtime configuration..."
  sleep 3
  if ns "crictl info 2>/dev/null | grep -q nvidia" 2>/dev/null; then
    log_info "containerd NVIDIA runtime verified"
  else
    log_warn "containerd NVIDIA runtime not yet visible in crictl info; restarting containerd"
    ns "systemctl restart containerd || true"
    sleep 5
    if ns "crictl info 2>/dev/null | grep -q nvidia" 2>/dev/null; then
      log_info "containerd NVIDIA runtime verified after restart"
    else
      log_warn "containerd NVIDIA runtime still not visible; kubelet restart may be needed"
    fi
  fi
fi

log_info "Generating CDI spec..."
ns 'mkdir -p /etc/cdi /var/run/cdi'
ns 'nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml || true'
ns 'test -s /var/run/cdi/nvidia.yaml || cp -f /etc/cdi/nvidia.yaml /var/run/cdi/nvidia.yaml || true'
ns 'test -s /etc/cdi/nvidia.yaml || cp -f /var/run/cdi/nvidia.yaml /etc/cdi/nvidia.yaml || true'
ns 'ln -sf /etc/cdi/nvidia.yaml /var/run/cdi/nvidia.yaml || true'
else
  log_info "MANAGE_CONTAINER_TOOLKIT=false — 툴킷 설치/런타임(containerd/CDI) 설정 skip (toolkit DS 소유)"
fi

# ============================================================================ #
# MARKERS & DIAGNOSTICS
# ============================================================================ #
MARKER_DIR="/var/lib/kcloud-operator"
MARKER_NOUVEAU="${MARKER_DIR}/nvidia.nouveau.blacklisted"
MARKER_RUNTIME="${MARKER_DIR}/nvidia.runtime.configured"
ns "mkdir -p ${MARKER_DIR}"

if ! ns "test -f ${MARKER_NOUVEAU}"; then
  log_info "Disabling nouveau (one-time)..."
  ns "bash -lc '
    cat > /etc/modprobe.d/blacklist-nouveau.conf <<EOF
blacklist nouveau
options nouveau modeset=0
EOF
    update-initramfs -u || true
    touch ${MARKER_NOUVEAU}
  '"
else
  log_info "nouveau already blacklisted"
fi

# containerd/kubelet 재시작 (#17 조건3.1 — 기본 비활성).
# 런타임 lifecycle(재시작 포함)은 상주 toolkit DS 소유. 설치기가 재시작하면 이중 소유 +
# cordoned 노드 hang(③) 위험. MANAGE_CONTAINER_TOOLKIT=true 일 때만 수행.
if [[ "${MANAGE_CONTAINER_TOOLKIT}" == "true" ]]; then
  if ! ns "test -f ${MARKER_RUNTIME}"; then
    log_info "Restarting runtime and kubelet (one-time)..."
    case "${RUNTIME}" in
      containerd) ns "systemctl restart containerd || true" ;;
      docker)     ns "systemctl restart docker || true" ;;
    esac
    ns "systemctl restart kubelet || true"
    ns "touch ${MARKER_RUNTIME}"
  else
    log_info "Runtime already configured"
  fi
else
  log_info "MANAGE_CONTAINER_TOOLKIT=false — containerd/kubelet 재시작 skip (toolkit DS 소유)"
fi

ns "nvidia-smi -a > ${MARKER_DIR}/nvidia.smi 2>/dev/null || true"
ns "modinfo nvidia > ${MARKER_DIR}/nvidia.modinfo 2>/dev/null || true"
INSTALLED_VER=$(ns "cat /proc/driver/nvidia/version 2>/dev/null" | grep -oP 'NVRM version: \K[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
ns "echo ${INSTALLED_VER} > ${MARKER_DIR}/nvidia.ok"

log_info "NVIDIA driver installation completed successfully (runtime 설정은 toolkit DS 소유)."

# --- S2-5 WP-R2: cross-major 재부팅 마커 (job/daemonset 공통) ------------------
# 설치는 성공했으나 구 모듈이 rmmod 실패로 물려 있으면(로드 major != 설치 타겟 major),
# 새 모듈은 재부팅 후에만 로드된다 → detector(WP-R1)가 read 할 needs-reboot 마커를 남긴다.
# same-major 재설치는 rmmod/재로드로 수렴하므로 대상 아님(불필요 재부팅 방지).
LOADED_MAJOR="${INSTALLED_VER%%.*}"   # /proc = 현재 로드된 모듈
TARGET_MAJOR="${DRIVER_VERSION%%.*}"  # env = Job 이 설치한 타겟
if [[ "${INSTALLED_VER}" != "unknown" && -n "${DRIVER_VERSION}" && "${LOADED_MAJOR}" != "${TARGET_MAJOR}" ]]; then
  case "${REBOOT_STRATEGY:-IfNeeded}" in
    Never)
      log_warn "cross-major 모듈 stuck(loaded ${LOADED_MAJOR} != target ${TARGET_MAJOR}) — rebootStrategy=Never, 마커 생략" ;;
    *)
      log_warn "cross-major 모듈 stuck(loaded ${LOADED_MAJOR} != target ${TARGET_MAJOR}) — needs-reboot 마커 생성(재부팅 후 신 모듈 로드)"
      ns "mkdir -p ${MARKER_DIR}; touch ${MARKER_DIR}/needs-reboot" || true ;;
  esac
else
  # major 일치(신 모듈 정상 로드) → stale needs-reboot 마커 제거(재부팅 후 재실행 시 수렴).
  # ponytail: 재부팅 후 수렴은 operator 가 handleRebooting→install 재실행(entrypoint 재진입)으로
  #   마커를 지우는 흐름 전제. E2E(동결 해제 후)에서 최종 확정.
  ns "rm -f ${MARKER_DIR}/needs-reboot 2>/dev/null" || true
fi
# -----------------------------------------------------------------------------

# ============================================================================ #
# DAEMONSET 모드: Ready 마커 생성 + 상시 모니터링 루프
# startupProbe는 /tmp/driver-ready 파일 존재 여부를 확인한다.
# livenessProbe는 healthcheck.sh를 주기적으로 실행한다.
# ============================================================================ #
log_info "Ready 마커 생성 중..."
ns "touch ${MARKER_DIR}/driver.ready"
touch /tmp/driver-ready

# RUN_MODE=job: 설치 완료 → healthcheck self-check 1회 후 exit 0 (상주 루프 없음).
if [[ "${RUN_MODE}" == "job" ]]; then
  log_info "RUN_MODE=job — 설치 완료, healthcheck self-check 후 exit 0"
  if ! /usr/local/bin/healthcheck.sh; then
    log_error "RUN_MODE=job self-check 실패 — Job 실패(exit 1)"
    exit 1
  fi
  log_info "RUN_MODE=job self-check 통과 — install Job 정상 종료(exit 0)"
  exit 0
fi

log_info "DaemonSet 모드: startupProbe 통과 — 상시 모니터링 루프 시작 (interval=${HEALTH_CHECK_INTERVAL:-30}s)"
while true; do
  sleep "${HEALTH_CHECK_INTERVAL:-30}"
  if ! /usr/local/bin/healthcheck.sh; then
    log_error "드라이버 상태 이상 감지 — livenessProbe 재시작 트리거를 위해 종료"
    exit 1
  fi
done

