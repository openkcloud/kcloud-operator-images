#!/usr/bin/env bash
# ============================================================
# entrypoint.sh: Furiosa NPU(Warboy·RNGD 공용) 드라이버 설치 및 상시 모니터링
# 상세: 모델 판별(FURIOSA_MODEL env 또는 PCI 자동 감지) → APT 소스 등록 → 호스트 커널 빌드
#       도구 설치 → 드라이버 패키지 설치 → DKMS 조건부 빌드 → 모듈 로드 → 장치 검증
#       → ready 마커 → 헬스 모니터링 루프.
#       furiosa-warboy/entrypoint.sh 와 furiosa-rngd/entrypoint.sh 를 하나로 합친 것이다.
#       두 스크립트는 골격이 같고 모델별 값 7가지(PCI id·패키지·hold 집합·커널 모듈·
#       헬스 장치·APT 저장소·인증)만 달랐다. 그 값은 아래 모델 표 한 곳에만 둔다.
#       안전장치(NVIDIA a/b/c 이식): (a)전량 vfio-pci passthrough 시 설치 보류+idle,
#       (b)기존 설치가 desired 보다 최신이면 다운그레이드 방지, (c)VERSION_SOURCE=Host 시 호스트 버전 존중
# 생성일: 2026-09-09
# ============================================================
set -euo pipefail

# ----- 안전장치 env (기본값은 기존 동작과 하위호환) -----
#   SKIP_ON_PASSTHROUGH (기본 true) : (a) NPU 전량 vfio-pci 바인딩 시 설치 보류
#   ALLOW_DOWNGRADE     (기본 false): (b) 하위 버전 다운그레이드 허용 여부
#   VERSION_SOURCE      (기본 Policy): (c) Host=호스트 설치 버전을 desired 로 채택
SKIP_ON_PASSTHROUGH="${SKIP_ON_PASSTHROUGH:-true}"
ALLOW_DOWNGRADE="${ALLOW_DOWNGRADE:-false}"
VERSION_SOURCE="${VERSION_SOURCE:-Policy}"
MARKER_DIR="${MARKER_DIR:-/var/lib/kcloud-operator}"

# RUN_MODE: daemonset(기본)=상주 healthcheck 루프, job=설치 후 exit 0.
RUN_MODE="${RUN_MODE:-daemonset}"

# ----- helpers -----
ns() { nsenter --target 1 --mount --uts --ipc --net --pid -- bash -lc "$*"; }

# 마커 디렉터리 개명 이관(npu-operator → kcloud-operator). 1회 수행되고 멱등이다.
# 아래 어떤 MARKER_DIR 사용보다 먼저 와야 한다.
# shellcheck source=/dev/null
. /usr/local/bin/marker-migrate.sh
migrate_marker_dir "${MARKER_DIR}"

require_host_ns() {
  if ! [ -e /proc/1/ns/mnt ]; then
    echo "[ERR] Need --pid=host & privileged to nsenter host" >&2
    exit 1
  fi
}

# ============================================================
# 모델 표. 두 모델의 차이는 전부 여기에 있다. 새 모델은 case 분기 하나로 추가한다.
# ============================================================
#   PCI_DEVICE_ID : Furiosa(0x1ed2) 아래 device id
#   PKG           : 드라이버 패키지명 (dpkg / apt / dkms 이름이 같다)
#   EXTRA_PKGS    : 드라이버와 함께 설치하는 필수 패키지
#   OPTIONAL_PKGS : 실패해도 계속 가는 선택 패키지
#   HOLD_PKGS     : apt-mark hold 로 자동 업그레이드를 막을 집합
#   MODULES       : modprobe 순서(공백 구분). 마지막 것이 헬스 판정 모듈이다
#   HEALTH_DEV    : 장치 존재 검사 셸 조각 (ns 안에서 실행)
#   APT_LIST_NAME : /etc/apt/sources.list.d/ 아래 파일명
#   APT_AUTH      : secret = /secrets 마운트 필수, anon = 인증 없음
select_model() {
  case "$1" in
    warboy)
      PCI_DEVICE_ID="0x0000"
      PKG="furiosa-driver-warboy"
      EXTRA_PKGS="furiosa-libnux furiosa-libhal-warboy"
      OPTIONAL_PKGS="furiosa-compiler furiosa-toolkit"
      HOLD_PKGS="furiosa-driver-warboy furiosa-libhal-warboy furiosa-libnux"
      MODULES="npu_mgmt npu_pdma"
      HEALTH_DEV='ls /dev/npu* >/dev/null 2>&1'
      APT_LIST_NAME="furiosa.list"
      APT_AUTH="secret"
      ;;
    rngd)
      PCI_DEVICE_ID="0x0001"
      PKG="furiosa-driver-rngd"
      EXTRA_PKGS="furiosa-smi"
      OPTIONAL_PKGS=""
      HOLD_PKGS="furiosa-driver-rngd furiosa-smi furiosa-libsmi"
      MODULES="furiosa_rngd"
      HEALTH_DEV='test -c /dev/rngd/npu0mgmt'
      APT_LIST_NAME="furiosa-rngd.list"
      APT_AUTH="anon"
      ;;
    *)
      echo "[ERR] unknown FURIOSA_MODEL '$1' (warboy|rngd)" >&2
      exit 1
      ;;
  esac
  HEALTH_MODULE="${MODULES##* }"
}

# 호스트 PCI 에서 Furiosa(0x1ed2) 장치의 device id 를 한 줄에 하나씩 출력한다.
host_furiosa_device_ids() {
  ns 'for d in /sys/bus/pci/devices/*/; do
      [ -r "${d}vendor" ] || continue
      [ "$(cat "${d}vendor" 2>/dev/null)" = "0x1ed2" ] || continue
      cat "${d}device" 2>/dev/null
    done' | sort -u
}

# FURIOSA_MODEL 이 비어 있으면 PCI 로 판별한다. 두 모델이 한 노드에 섞여 있으면 실패한다 —
# 어느 드라이버를 깔지 정할 수 없고, 잘못 고르면 다른 모델의 장치가 조용히 빠진다.
detect_model() {
  local ids
  ids="$(host_furiosa_device_ids | tr -d '\r')"
  local warboy=0 rngd=0
  while IFS= read -r id; do
    case "$id" in
      0x0000) warboy=1 ;;
      0x0001) rngd=1 ;;
    esac
  done <<<"$ids"
  if [[ "$warboy" -eq 1 && "$rngd" -eq 1 ]]; then
    echo "[ERR] Warboy 와 RNGD 가 한 노드에 함께 있다 — FURIOSA_MODEL 을 명시하라" >&2
    exit 1
  fi
  if [[ "$warboy" -eq 1 ]]; then echo warboy; return; fi
  if [[ "$rngd" -eq 1 ]]; then echo rngd; return; fi
  echo "[ERR] Furiosa 장치가 없어 모델을 정할 수 없다 — FURIOSA_MODEL 을 명시하라" >&2
  exit 1
}

# 호스트 PCI 를 순회하며 이 모델 NPU 의 "<total> <installable>" 개수를 출력한다.
#   total       : Furiosa(0x1ed2) & 이 모델 device id 장치 총 개수
#   installable : 그 중 driver 바인딩이 vfio-pci 가 아닌(=furiosa/미바인딩) 장치 개수
# 집계는 단일 ns 호출(호스트 mount namespace)에서 수행하여 왕복/쿼팅을 최소화한다.
npu_bindings() {
  ns "total=0; installable=0
    for d in /sys/bus/pci/devices/*/; do
      [ -r \"\${d}vendor\" ] || continue
      vendor=\$(cat \"\${d}vendor\" 2>/dev/null || echo \"\")
      device=\$(cat \"\${d}device\" 2>/dev/null || echo \"\")
      [ \"\$vendor\" = \"0x1ed2\" ] || continue
      [ \"\$device\" = \"${PCI_DEVICE_ID}\" ] || continue
      total=\$((total+1))
      bound=\"\"
      if [ -L \"\${d}driver\" ]; then
        bound=\$(basename \"\$(readlink \"\${d}driver\")\" 2>/dev/null || echo \"\")
      fi
      [ \"\$bound\" != \"vfio-pci\" ] && installable=\$((installable+1))
    done
    echo \"\$total \$installable\""
}

# 설치 대상 NPU 존재 여부.
#   반환 0(true)  : installable NPU 가 1개 이상 있거나, NPU 가 아예 없는 비-NPU 노드(가드 미적용)
#   반환 1(false) : NPU 는 있으나 전량 vfio-pci 바인딩(passthrough)
has_installable_npu() {
  local out total installable
  out=$(npu_bindings 2>/dev/null | tail -n1 || echo "0 0")
  # POSIX 파라미터 확장으로 파싱(awk 의존 제거 — nsenter 컨텍스트 PATH 문제 회피)
  total=${out%% *}; installable=${out##* }
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  case "$installable" in ''|*[!0-9]*) installable=0 ;; esac
  [ "${total:-0}" -eq 0 ] && return 0
  [ "${installable:-0}" -gt 0 ] && return 0
  return 1
}

health_check() {
  ns "${HEALTH_DEV} || exit 1"
  ns "lsmod | grep -q ${HEALTH_MODULE} || exit 1"
}

pkg_version() { ns "dpkg-query -W -f='\${Version}' ${PKG} 2>/dev/null" || echo ""; }
pkg_state()   { ns "dpkg-query -W -f='\${db:Status-Status}' ${PKG} 2>/dev/null" || echo ""; }

# DKMS 빌드 실패 시 make.log tail 출력.
print_dkms_logs_if_any() {
  local kver="$1" pkg_ver
  pkg_ver=$(pkg_version)
  if [ -z "${pkg_ver}" ]; then
    echo "[DEBUG] ${PKG} 미설치 상태 — DKMS 로그 없음"
    return 0
  fi
  local build_dir="/var/lib/dkms/${PKG}/${pkg_ver}/build"
  local kver_log_dir="/var/lib/dkms/${PKG}/${pkg_ver}/${kver}/x86_64/log"
  echo "[DEBUG] DKMS build log dump (pkg=${pkg_ver}, kernel=${kver}):"
  ns "ls -la ${build_dir} 2>/dev/null" || true
  echo "[DEBUG] --- tail -n 80 ${build_dir}/make.log ---"
  ns "tail -n 80 ${build_dir}/make.log 2>/dev/null" || echo "[DEBUG] ${build_dir}/make.log not readable"
  if ns "[ -d ${kver_log_dir} ]"; then
    echo "[DEBUG] --- tail -n 40 ${kver_log_dir}/make.log ---"
    ns "tail -n 40 ${kver_log_dir}/make.log 2>/dev/null" || true
  fi
}

# 호스트에서 apt 락 대기 & 정리
apt_lock_wait_and_fix() {
  ns '
    set -e
    for i in $(seq 1 30); do
      if fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        echo "[INFO] apt busy, wait 10s ($i/30)"
        sleep 10
      else
        break
      fi
    done
    if fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
      systemctl stop apt-daily.service apt-daily-upgrade.service || true
      systemctl kill --kill-who=all apt apt-get || true
      sleep 3
    fi
    rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend || true
    dpkg --configure -a || true
  '
}

# 호스트 codename 감지 (ubuntu 가정)
detect_codename() {
  local codename
  codename=$(ns 'source /etc/os-release 2>/dev/null || true; echo ${VERSION_CODENAME:-}' | tr -d '\r')
  [[ -z "${codename}" ]] && codename="jammy"
  echo "${codename}"
}

# APT 저장소 등록. 모델마다 저장소와 인증 방식이 다르다.
#   warboy: archive.furiosa.ai (restricted, /secrets 의 auth.conf 필수)
#   rngd  : Google Artifact Registry (anonymous)
setup_apt_source() {
  local tmpdir="$1" codename
  codename="$(detect_codename)"
  case "${APT_AUTH}" in
    secret)
      ns 'mkdir -p /etc/apt/keyrings /etc/apt/auth.conf.d /etc/apt/sources.list.d'
      if [[ ! -f /secrets/furiosa.conf ]]; then
        echo "[ERR] /secrets/furiosa.conf not found (mount Secret) — ${MODEL} 저장소는 인증이 필요하다"; exit 1
      fi
      if [[ -f /secrets/furiosa-apt-key.gpg ]]; then
        cp /secrets/furiosa-apt-key.gpg "${tmpdir}/furiosa-apt-key.gpg"
      else
        echo "[INFO] Fetching Furiosa public key (container side)..."
        wget -qO- https://archive.furiosa.ai/furiosa-apt-key.gpg | gpg --dearmor > "${tmpdir}/furiosa-apt-key.gpg"
      fi
      ns 'cat >/etc/apt/keyrings/furiosa-apt-key.gpg' < "${tmpdir}/furiosa-apt-key.gpg"
      ns 'cat >/etc/apt/auth.conf.d/furiosa.conf' < /secrets/furiosa.conf
      ns 'chmod 400 /etc/apt/auth.conf.d/furiosa.conf'
      if [[ -f /secrets/furiosa.list ]]; then
        ns "cat >/etc/apt/sources.list.d/${APT_LIST_NAME}" < /secrets/furiosa.list
      else
        printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/furiosa-apt-key.gpg] https://archive.furiosa.ai/ubuntu %s restricted\n' "${codename}" > "${tmpdir}/${APT_LIST_NAME}"
        ns "cat >/etc/apt/sources.list.d/${APT_LIST_NAME}" < "${tmpdir}/${APT_LIST_NAME}"
      fi
      ;;
    anon)
      ns 'mkdir -p /etc/apt/trusted.gpg.d /etc/apt/sources.list.d'
      echo "[INFO] Fetching APT key (container side)..."
      if ! curl -fsSL "https://packages.cloud.google.com/apt/doc/apt-key.gpg" \
           | gpg --dearmor > "${tmpdir}/furiosa-cloud.google.gpg" 2>/dev/null; then
        echo "[ERR] APT GPG 키 fetch 실패"; exit 1
      fi
      ns 'cat >/etc/apt/trusted.gpg.d/furiosa-cloud.google.gpg' < "${tmpdir}/furiosa-cloud.google.gpg"
      printf 'deb [arch=amd64] http://asia-northeast3-apt.pkg.dev/projects/furiosa-ai %s main\n' "${codename}" > "${tmpdir}/${APT_LIST_NAME}"
      ns "cat >/etc/apt/sources.list.d/${APT_LIST_NAME}" < "${tmpdir}/${APT_LIST_NAME}"
      ;;
  esac
}

# ----- main -----
require_host_ns

MODEL="${FURIOSA_MODEL:-}"
if [[ -z "${MODEL}" ]]; then
  MODEL="$(detect_model)"
  echo "[INFO] FURIOSA_MODEL 미지정 — PCI 로 판별: ${MODEL}"
fi
select_model "${MODEL}"
echo "[INFO] model=${MODEL} pkg=${PKG} modules=(${MODULES})"

ns "mkdir -p ${MARKER_DIR}"

KVER=$(ns 'uname -r')
echo "[INFO] Host kernel: ${KVER}"

# --- PASSTHROUGH GUARD (a) ---
if [[ "${SKIP_ON_PASSTHROUGH}" != "false" ]] && ! has_installable_npu; then
  echo "[INFO] 모든 ${MODEL} NPU 가 vfio-pci(passthrough) 바인딩 — 드라이버 설치 보류"
  ns "touch ${MARKER_DIR}/passthrough-skip" || true
  ns "touch ${MARKER_DIR}/driver.ready" || true
  touch /tmp/driver-ready
  if [[ "${RUN_MODE}" == "job" ]]; then
    echo "[INFO] RUN_MODE=job + passthrough skip — 설치 대상 없음, exit 0"
    exit 0
  fi
  echo "[INFO] passthrough 노드 — idle 루프 진입 (드라이버 설치/모듈 로드 미수행)"
  while true; do sleep "${HEALTH_CHECK_INTERVAL:-30}"; done
fi

# 기존 설치 버전·dpkg 상태 감지 (a/b/c 가드 및 idempotency 공용)
# 상태를 함께 읽는 이유: `dpkg -s` 는 설정이 끝나지 않은 패키지에도 성공하고 버전도 그대로
# 돌려준다. 버전만 보면 half-configured 를 "정상 설치" 로 오인해 손대지 않는다.
EXISTING_VER=""
EXISTING_STATE=""
if ns "dpkg -s ${PKG} >/dev/null 2>&1"; then
  EXISTING_VER=$(pkg_version)
  EXISTING_STATE=$(pkg_state)
  [ -n "${EXISTING_VER}" ] && echo "[INFO] 기존 ${PKG} 설치 감지: ${EXISTING_VER} (dpkg 상태=${EXISTING_STATE:-unknown})"
fi

# --- HOST VERSION RESPECT (c) ---
if [[ "${VERSION_SOURCE}" == "Host" ]]; then
  if [[ -n "${EXISTING_VER}" ]]; then
    echo "[INFO] VERSION_SOURCE=Host — 기존 호스트 드라이버 ${EXISTING_VER} 를 desired 로 채택 (설치 skip)"
    DRIVER_VERSION="${EXISTING_VER}"
  else
    echo "[INFO] VERSION_SOURCE=Host 지만 호스트 드라이버 없음 — policy DRIVER_VERSION=${DRIVER_VERSION:-<unset>} 로 fallback"
  fi
fi

# idempotency guard + 다운그레이드 가드 + 설정 미완 복구.
# 판단은 install-decision.sh 의 순수 함수 하나가 내린다(시험: install-decision_test.sh).
# shellcheck source=install-decision.sh
source /usr/local/bin/install-decision.sh

ACTION="$(decide_install_action "${EXISTING_VER}" "${EXISTING_STATE}" "${DRIVER_VERSION:-}" "${ALLOW_DOWNGRADE}")"

# 설정이 끝나지 않은 패키지는 먼저 마무리를 시도한다. 이 상태로 두면 dpkg 가 버전을 정상
# 보고하지 못해 operator 의 업그레이드 검증이 영원히 실패한다(2026-08-10 라이브).
if [[ "${ACTION}" == "repair" ]]; then
  echo "[WARN] ${PKG} ${EXISTING_VER} 이 dpkg 상태 '${EXISTING_STATE}' 로 남아 있다 — 설정 마무리 시도"
  apt_lock_wait_and_fix
  EXISTING_VER=$(pkg_version)
  EXISTING_STATE=$(pkg_state)
  if [[ "${EXISTING_STATE}" == "installed" ]]; then
    echo "[INFO] dpkg 설정 마무리 완료: ${EXISTING_VER}"
    ACTION="$(decide_install_action "${EXISTING_VER}" "${EXISTING_STATE}" "${DRIVER_VERSION:-}" "${ALLOW_DOWNGRADE}")"
  else
    echo "[WARN] 설정 마무리 실패 (dpkg 상태='${EXISTING_STATE:-unknown}') — 전량 재설치로 승격"
    EXISTING_VER=""
    ACTION="install"
  fi
fi

SKIP_INSTALL=0
case "${ACTION}" in
  skip)
    echo "[INFO] ${PKG} ${EXISTING_VER} 이미 설치됨 — APT 설치 skip"
    SKIP_INSTALL=1
    ;;
  skip-downgrade)
    echo "[WARN] 기존 드라이버 ${EXISTING_VER} > desired ${DRIVER_VERSION}; 다운그레이드 비활성(ALLOW_DOWNGRADE=false) → 기존 유지, 설치 skip"
    if refusal_is_fatal "${RUN_MODE}"; then
      echo "[ERR] job 모드에서 요청받은 버전을 설치하지 못했다 — 성공으로 보고하지 않는다"
      exit 1
    fi
    SKIP_INSTALL=1
    ;;
  *)
    [[ -n "${EXISTING_VER}" ]] && echo "[INFO] 버전 변경 감지: ${EXISTING_VER} → ${DRIVER_VERSION}"
    ;;
esac

if [[ "${SKIP_INSTALL}" -eq 0 ]]; then
  TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR"' EXIT

  setup_apt_source "${TMPDIR}"

  echo "[INFO] Waiting for APT locks & pre-fix..."
  apt_lock_wait_and_fix

  echo "[INFO] Installing ${PKG} on host..."
  ns 'apt-get update'

  # 커널 빌드 의존을 드라이버보다 먼저 깐다. 드라이버 postinst 의 DKMS 빌드가 헤더를 요구한다.
  echo "[INFO] 호스트 커널 빌드 의존 패키지 설치 (kernel=${KVER})..."
  ns "DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential linux-modules-extra-${KVER} linux-headers-${KVER}" \
    || echo "[WARN] 커널 빌드 의존 설치 실패 — pre-built .ko 인 경우 무시 가능"

  # DKMS 빌드 전: 이전 실패한 빌드가 남긴 crash report 삭제.
  # 남아있으면 apport 가 동일 파일 재기록을 거부하여 "File exists" 에러가 로그를 덮는다.
  ns "rm -f /var/crash/${PKG}*.crash 2>/dev/null || true"

  if [ -n "${DRIVER_VERSION:-}" ]; then
    echo "[INFO] 지정 버전 설치: ${PKG}=${DRIVER_VERSION}"
    ns "apt-mark unhold ${HOLD_PKGS} 2>/dev/null || true"
    ns "DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades ${PKG}=${DRIVER_VERSION} ${EXTRA_PKGS}"
  else
    ns "DEBIAN_FRONTEND=noninteractive apt-get install -y ${PKG} ${EXTRA_PKGS}"
  fi

  if [ -n "${OPTIONAL_PKGS}" ]; then
    ns "DEBIAN_FRONTEND=noninteractive apt-get install -y ${OPTIONAL_PKGS} || true"
  fi

  if ! ns "dpkg -s ${PKG} >/dev/null 2>&1"; then
    echo "[ERR] ${PKG} not installed"; exit 1
  fi

  WANT_VER="${DRIVER_VERSION:-}"
  HOST_VER=$(pkg_version)
  if [ -n "${WANT_VER}" ] && [ -n "${HOST_VER}" ] && [ "${WANT_VER}" != "${HOST_VER}" ]; then
    echo "[WARN] Driver version drift: chart declares '${WANT_VER}', host has '${HOST_VER}'"
  fi
fi

# hold 재적용은 설치 분기 **밖**이다. 설치를 건너뛴 회차나 도중에 죽었다 복구된 회차에도
# hold 가 빠진 채로 남으면 노드의 apt 자동 업그레이드가 드라이버를 갈아 끼운다
# (2026-08-10 라이브에서 실제로 빠진 채 남았다).
if ns "dpkg -s ${PKG} >/dev/null 2>&1"; then
  ns "apt-mark hold ${HOLD_PKGS} 2>/dev/null || true"
fi

# --- DKMS 빌드 확인 ---
echo "[INFO] DKMS 상태 확인 (${PKG}, kernel=${KVER})..."
DKMS_STATUS=$(ns "dkms status ${PKG} 2>/dev/null" || true)
if ! echo "${DKMS_STATUS}" | grep -q "${KVER}"; then
  if [ -z "${DKMS_STATUS}" ]; then
    echo "[INFO] DKMS 등록 없음 — pre-built .ko 가정, skip"
  else
    echo "[INFO] Running dkms autoinstall for kernel ${KVER}..."
    ns "dkms autoinstall -k ${KVER}" || {
      echo "[ERR] DKMS 빌드 실패"
      print_dkms_logs_if_any "${KVER}"
      exit 1
    }
  fi
fi

# 사전 의존 모듈 (videobuf2_common → frame_vector 심볼 제공). 실패는 무시.
ns 'modprobe videobuf2_common 2>/dev/null || true'

# --- 커널 모듈 로드 (모델 표의 순서대로) ---
for mod in ${MODULES}; do
  echo "[INFO] Loading ${mod} kernel module..."
  if ! ns "modprobe ${mod} 2>/dev/null"; then
    echo "[ERR] Failed to load ${mod} module"
    ns "dmesg | grep -i ${mod%%_*} | tail -10" || true
    exit 1
  fi
done
if ! ns "lsmod | grep -q ${HEALTH_MODULE}"; then
  echo "[ERR] ${HEALTH_MODULE} module not loaded after modprobe"
  exit 1
fi
echo "[INFO] kernel modules loaded: ${MODULES}"

# 장치 검증
if ! ns "${HEALTH_DEV}"; then
  echo "[ERR] ${MODEL} device not ready (${HEALTH_DEV})"
  ns 'ls /dev/npu* /dev/rngd/ 2>/dev/null' || true
  exit 1
fi
echo "[INFO] ${MODEL} device verified"

# 마커/로그
ns "dpkg -l | grep -i furiosa > ${MARKER_DIR}/furiosa-${MODEL}.dpkg 2>/dev/null || true"
ns "echo ok >${MARKER_DIR}/driver.ok"

echo "[INFO] Done. ${MODEL} driver installed and loaded."

# ----- DaemonSet 모드: Ready 마커 + 상시 모니터링 루프 -----
touch "${MARKER_DIR}/driver.ready"
touch /tmp/driver-ready

if [[ "${RUN_MODE}" == "job" ]]; then
  echo "[INFO] RUN_MODE=job — 설치 완료, health_check self-check 후 exit 0"
  if ! health_check; then
    echo "[ERR] RUN_MODE=job self-check 실패 — Job 실패(exit 1)" >&2
    exit 1
  fi
  echo "[INFO] RUN_MODE=job self-check 통과 — install Job 정상 종료(exit 0)"
  exit 0
fi

echo "[INFO] Ready marker created. Starting health monitoring loop..."
while true; do
  sleep "${HEALTH_CHECK_INTERVAL:-30}"
  if ! health_check; then
    echo "[ERR] ${MODEL} driver unhealthy (${HEALTH_MODULE} not loaded or device missing), exiting..." >&2
    exit 1
  fi
done
