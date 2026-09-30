#!/usr/bin/env bash
# ============================================================
# marker-migrate.sh: 마커 디렉터리 옛 경로 → 새 경로 1회 이관 (세 벤더 설치기 공용)
# 상세: 프로젝트가 npu-operator 에서 kcloud-operator 로 개명되기 전에 설치된 노드는
#       /var/lib/npu-operator 아래에 마커(driver.ok·driver.ready·needs-reboot·
#       furiosa.dpkg 등)를 갖고 있다. 설치기가 시작할 때 migrate_marker_dir 를 한 번
#       불러 호스트 네임스페이스에서 새 경로로 옮긴다. 멱등이므로 매 기동 호출해도 된다.
#       디렉터리를 통째로 mv 하지 않는다 — kubelet 이 hostPath 볼륨을 컨테이너 기동 전에
#       미리 만들어 두므로 새 경로가 이미 존재하고, 통째 mv 는 그 안에 npu-operator/ 로
#       중첩된다. 파일 단위로 옮기고 비워진 옛 디렉터리만 지운다.
#       세 설치기 이미지의 docker 빌드 컨텍스트가 서로 달라(각 벤더 디렉터리) 한 파일을
#       공유 COPY 할 수 없다. 그래서 각 컨텍스트에 같은 내용으로 두고, 사본이 갈라지지
#       않는지는 driver-installer/marker-migrate_test.sh 가 지킨다.
# 생성일: 2026-09-09
# ============================================================

# 개명 전 마커 경로. 시험에서 덮어쓸 수 있게 env 로 연다.
LEGACY_MARKER_DIR="${LEGACY_MARKER_DIR:-/var/lib/npu-operator}"

# migrate_marker_dir <새 마커 경로>
#   호출부가 ns() (nsenter 로 호스트에서 실행하는 래퍼)를 미리 정의해야 한다.
#   ns 가 없으면 경고만 남기고 물러난다(설치 자체를 막지 않는다).
migrate_marker_dir() {
  local new="${1:-}"
  if [ -z "${new}" ]; then
    echo "[WARN] marker-migrate: 새 마커 경로 인자가 없어 이관을 건너뛴다" >&2
    return 0
  fi
  if [ "${LEGACY_MARKER_DIR}" = "${new}" ]; then
    return 0
  fi
  if ! declare -F ns >/dev/null 2>&1; then
    echo "[WARN] marker-migrate: ns 헬퍼가 없어 옛 마커 이관을 건너뛴다" >&2
    return 0
  fi

  local script
  script=$(cat <<EOS
set -u
[ -d '${LEGACY_MARKER_DIR}' ] || exit 0
mkdir -p '${new}' || exit 0
moved=0
for f in '${LEGACY_MARKER_DIR}'/* '${LEGACY_MARKER_DIR}'/.[!.]*; do
  [ -e "\$f" ] || continue
  t='${new}'/\$(basename "\$f")
  # 새 경로에 같은 이름이 이미 있으면 그쪽이 최신이다 — 덮어쓰지 않는다.
  if [ ! -e "\$t" ]; then
    mv "\$f" "\$t" 2>/dev/null && moved=\$((moved+1))
  fi
done
rmdir '${LEGACY_MARKER_DIR}' 2>/dev/null || true
[ "\$moved" -gt 0 ] && echo "[INFO] marker-migrate: '${LEGACY_MARKER_DIR}' → '${new}' 로 \$moved 개 이관"
exit 0
EOS
)
  ns "${script}" || echo "[WARN] marker-migrate: 옛 마커 이관 실패(설치는 계속한다)" >&2
  return 0
}
