#!/usr/bin/env bash
# ============================================================
# crossmajor-marker-selfcheck.sh: entrypoint.sh 의 cross-major reboot-deferred 분기 판정 self-check
# 상세: 타겟 패키지 설치됨 + (loaded major != target major) 조건에서만 needs-reboot 마커+정상종료로
#       위임하고, 그 외(실패/major 일치/패키지 미설치)에는 install 실패로 유지하는지 검증.
# 생성일: 2026-07-20
# ============================================================
set -euo pipefail

# entrypoint.sh 의 판정식을 그대로 복제한 순수 함수(로직 회귀 감시용).
# 인자: EXPECTED_MAJOR TARGET_PKG_OK DISK_MOD_MAJOR ACTIVE_MAJOR [REBOOT_STRATEGY]
decide() {
  local EXPECTED_MAJOR="$1" TARGET_PKG_OK="$2" DISK_MOD_MAJOR="$3" ACTIVE_MAJOR="$4" REBOOT_STRATEGY="${5:-IfNeeded}"
  if [[ -n "${EXPECTED_MAJOR}" && "${TARGET_PKG_OK}" -ge 1 \
        && "${DISK_MOD_MAJOR}" == "${EXPECTED_MAJOR}" \
        && "${ACTIVE_MAJOR}" != "${EXPECTED_MAJOR}" ]]; then
    case "${REBOOT_STRATEGY}" in
      Never) echo "FAIL" ;;      # 재부팅 금지 → install 실패 유지
      *)     echo "MARKER" ;;    # 마커 생성 + 정상 종료(reboot 위임)
    esac
  else
    echo "FAIL"                  # 실 install 실패 → exit 1 유지
  fi
}

fail=0
check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "NG: $1 (want $2 got $3)"; fail=1; fi
}

# 타겟 535 모듈 디스크 준비 완료 + 구 580 active → 마커 위임 (/proc active 존재)
check "cross-major stuck (active=old) → MARKER" MARKER "$(decide 535 1 535 580 IfNeeded)"
# 타겟 580 모듈 준비 + active 비어있음(broken half-load, /proc empty) → 마커 위임 (핵심 개선: /proc empty 케이스)
check "cross-major stuck (active=empty/broken) → MARKER" MARKER "$(decide 580 1 580 '' IfNeeded)"
# 위 케이스 + rebootStrategy=Never → 실패 유지
check "cross-major stuck + Never → FAIL" FAIL "$(decide 535 1 535 580 Never)"
# 타겟 패키지 미설치(진짜 install 실패) → 실패 유지
check "target pkg 미설치 → FAIL" FAIL "$(decide 535 0 535 580 IfNeeded)"
# 디스크 모듈이 타겟 major 아님(DKMS 빌드 실패=진짜 실패) → 마커 미발동
check "DKMS build fail (disk mod != target) → FAIL" FAIL "$(decide 535 1 580 580 IfNeeded)"
# 타겟이 이미 active(마커 불필요) → FAIL 경로(여기 도달 자체가 비정상이나 안전상 exit1)
check "target already active → FAIL" FAIL "$(decide 580 1 580 580 IfNeeded)"

exit $fail
