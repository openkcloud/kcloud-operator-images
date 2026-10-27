#!/usr/bin/env bash
# ============================================================
# preflight_test.sh: 설치 전 점검(run_preflight·preflight.sh)이 hold 충돌만 막고 호스트를 바꾸지 않는지 시험
# 상세: entrypoint.sh 함수만 source 하고 ns·apt_wait·nvidia_gpu_bindings 를 가짜로 둔다. 모든 ns
#       호출을 기록해 허용 목록(커널·hold 조회, 목록 갱신, 모의 설치) 밖의 호스트 명령이 한 번도 없는지
#       마지막에 단정한다. 사례 10b 는 가짜 nsenter 로 실제 entrypoint.sh 와 preflight.sh 를 프로세스로
#       실행해, 호스트 명령이 실패해도 종료 코드가 hold 충돌(3)로 새지 않고 1 인지 본다.
# 생성일: 2026-10-27 | 수정일: 2026-10-27
# ============================================================
# shellcheck disable=SC2034
# 파일 전체에 적용 — 전역 대입(DRIVER_VERSION·PREBUILT_ROOT 등)은 source 한 함수가 읽는다.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
nscalls="$tmp/nscalls"; allcalls="$tmp/allcalls"; : > "$allcalls"

ENTRYPOINT_LIB_ONLY=1
# shellcheck source=/dev/null
source "$here/entrypoint.sh"
set +eE

FIX_A=$'The following packages have unmet dependencies:\n libx11-xcb1 : Depends: libx11-6 (= 2:1.7.5-1ubuntu0.4) but 2:1.7.5-1ubuntu0.3 is to be installed\nE: Unable to correct problems, you have held broken packages.'
MADISON_178='nvidia-driver-580 | 580.178.04-0ubuntu0.22.04.1 | http://archive.ubuntu.com/ubuntu jammy-updates/restricted amd64 Packages'
MADISON_OTHER='nvidia-driver-580 | 580.126.09-0ubuntu0.22.04.1 | https://ppa.launchpadcontent.net/graphics-drivers/ppa/ubuntu jammy/main amd64 Packages'
KERNEL=5.15.0-179-generic

ns_default() {
  echo "$*" >> "$nscalls"; echo "$*" >> "$allcalls"
  case "$*" in
    "uname -r")                    echo "${KERNEL}" ;;
    *"apt-get update"*)            return "${UPDATE_RC}" ;;
    *"apt-get -s -y install"*)     printf '%s\n' "${SIM_OUT}"; return "${SIM_RC}" ;;
    *"apt-mark showhold"*)         printf '%s' "${HOLDS}" ;;
    *"apt-cache madison"*)         printf '%s\n' "${MADISON}" ;;
    *)                             return 0 ;;
  esac
}
ns() { ns_default "$@"; }
apt_wait() { return 0; }
nvidia_gpu_bindings() { echo "${GPU_BINDINGS}"; }
TERMINATION_LOG="$tmp/term"
reset() {
  : > "$nscalls"; : > "$tmp/term"; mkdir -p "$tmp/prebuilt"; PREBUILT_ROOT="$tmp/prebuilt"
  UPDATE_RC=0; SIM_OUT=""; SIM_RC=0; HOLDS=""; MADISON="$MADISON_178"; GPU_BINDINGS="1 1"
  DRIVER_VERSION=580.178.04; SKIP_ON_PASSTHROUGH=true
}
apt_called() { grep -qE 'apt-get|apt-mark|apt-cache' "$nscalls"; }

# (1) hold 충돌 → 3, 종료 메시지에 패키지, 목록 갱신과 같은 인자의 모의 설치를 거친다.
reset; SIM_OUT="$FIX_A"; SIM_RC=100; HOLDS=$'libx11-6\nlibx11-data\n'
rc=0; run_preflight >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 3 ]] || { echo "FAIL case1a: rc=$rc (3 기대)"; exit 1; }
grep -q 'libx11-6' "$tmp/term" || { echo "FAIL case1b: term=$(cat "$tmp/term")"; exit 1; }
grep -q 'apt-get update' "$nscalls" || { echo "FAIL case1c: 목록 갱신 없음"; exit 1; }
grep -q -- '-s -y install --allow-downgrades nvidia-driver-580=580.178.04-0ubuntu0.22.04.1 ' "$nscalls" \
  || { echo "FAIL case1d: $(cat "$nscalls")"; exit 1; }

# (2) 모의 설치 성공 → 0, 종료 메시지 없음.
reset; SIM_RC=0
rc=0; run_preflight >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 && ! -s "$tmp/term" ]] || { echo "FAIL case2: rc=$rc term=$(cat "$tmp/term")"; exit 1; }

# (3) hold 와 무관한 apt 실패 → 1(판정 불가).
reset; SIM_OUT="$FIX_A"; SIM_RC=100; HOLDS=""
rc=0; run_preflight >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 1 ]] && grep -q 'hold 와 무관' "$tmp/term" || { echo "FAIL case3: rc=$rc term=$(cat "$tmp/term")"; exit 1; }

# (4) 정책 버전이 저장소에 없음(PPA 추가 전 판정) → 1, 모의 설치는 부르지 않는다.
reset; MADISON="$MADISON_OTHER"
rc=0; run_preflight >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 1 ]] && grep -q '저장소' "$tmp/term" || { echo "FAIL case4a: rc=$rc"; exit 1; }
grep -q -- '-s -y install' "$nscalls" && { echo "FAIL case4b: 버전이 없는데 모의 설치"; exit 1; }

# (5) GPU 전부 vfio-pci → 0, apt 호출 없음.
reset; GPU_BINDINGS="2 0"
rc=0; run_preflight >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] && ! apt_called || { echo "FAIL case5: rc=$rc"; exit 1; }

# (6) 실행 커널용 사전 컴파일 .deb 동봉 → 0, apt 호출 없음.
reset; mkdir -p "$tmp/prebuilt/$KERNEL"
: > "$tmp/prebuilt/$KERNEL/linux-modules-nvidia-580-${KERNEL}_580.178.04-0ubuntu0.22.04.1_amd64.deb"
rc=0; run_preflight >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] && ! apt_called || { echo "FAIL case6: rc=$rc"; exit 1; }
rm -f "$tmp/prebuilt/$KERNEL/linux-modules-nvidia-580-${KERNEL}_580.178.04-0ubuntu0.22.04.1_amd64.deb"

# (7) DRIVER_VERSION 비어 있음 → 0, apt 호출 없음.
reset; DRIVER_VERSION=""
rc=0; run_preflight >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] && ! apt_called || { echo "FAIL case7: rc=$rc"; exit 1; }

# (8) apt 목록 갱신 실패 → 1.
reset; UPDATE_RC=100
rc=0; run_preflight >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 1 ]] && grep -q 'apt 목록 갱신 실패' "$tmp/term" || { echo "FAIL case8: rc=$rc"; exit 1; }

# (9) 모든 사례를 통틀어 호스트에서 실행한 명령은 허용 목록의 형태뿐이다. 금지 명령을 정규식으로 찾으면 목록에
#     없는 변형(apt-get -y --allow-downgrades install …)이 빠져나가므로 허용하는 쪽을 닫는다. 허용: 커널 조회,
#     목록 갱신, 모의 설치(옵션은 --allow-downgrades 만 — hold 를 무시하는 옵션이 붙으면 점검이 무의미하다),
#     hold 목록·dpkg·apt-cache 조회. 기록 한 줄에 &&·||·;·| 나 명령 치환으로 이어 붙인 명령은 먼저 단위로 나눠
#     각각 판정한다 — 허용 명령에 붙은 변경 명령이 허용 패턴에 묻히지 않게 하려는 것이다.
host_cmd_violations() {   # $1: 기록 파일. 허용 목록 밖의 명령 단위를 한 줄에 하나 낸다.
  local unit re ok arg='[A-Za-z0-9._+:=~/-]+' pkg='[A-Za-z0-9][A-Za-z0-9._+:=~/-]*'
  local allowed=(
    '^uname -r$'
    '^apt-get update( -y)?$'
    "^(LC_ALL=C |DEBIAN_FRONTEND=[a-z]+ )*apt-get -s -y install( --allow-downgrades)?( ${pkg})+\$"
    '^apt-mark showhold$'
    "^apt-cache( ${arg})+\$"
    "^dpkg-query( ${arg}| -f='[^']*')*( 2>/dev/null)?\$"
  )
  while IFS= read -r unit; do
    unit="${unit#"${unit%%[![:space:]]*}"}"; unit="${unit%"${unit##*[![:space:]]}"}"
    [[ -n "$unit" ]] || continue
    ok=0
    for re in "${allowed[@]}"; do [[ "$unit" =~ $re ]] && { ok=1; break; }; done
    [[ "$ok" -eq 1 ]] || printf '%s\n' "$unit"
  done < <(sed -E 's/(\$\(|[;|&`()])/\n/g' "$1")
}
# 판정 자체의 시험: 허용 형태는 통과하고, 변경 명령은 단독이든 허용 명령에 이어 붙었든 걸린다.
cat > "$tmp/probe" <<'EOF'
apt-get update -y
LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -s -y install --allow-downgrades libnvidia-compute-580:amd64=2:580.178.04-0ubuntu0.22.04.1
dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package} ${source:Package}\n' 2>/dev/null
apt-get -y --allow-downgrades install libx11-6
apt-get update -y && apt-get -y install foo
apt-get -s -y install --allow-change-held-packages foo
apt-mark hold libx11-6
dpkg --configure -a
add-apt-repository -y ppa:graphics-drivers/ppa
EOF
want=$'apt-get -y --allow-downgrades install libx11-6\napt-get -y install foo\napt-get -s -y install --allow-change-held-packages foo\napt-mark hold libx11-6\ndpkg --configure -a\nadd-apt-repository -y ppa:graphics-drivers/ppa'
[[ "$(host_cmd_violations "$tmp/probe")" == "$want" ]] \
  || { echo "FAIL case9a: 허용 목록 판정이 어긋났다:"; host_cmd_violations "$tmp/probe" | sed 's/^/  /'; exit 1; }
# 실제 기록에 적용한다. 기록이 비면 아무것도 단정하지 못하므로 모의 설치가 기록됐는지 먼저 본다.
grep -q -- 'apt-get -s -y install' "$allcalls" || { echo "FAIL case9: 모의 설치 기록이 없다 — 검사 대상이 비었다"; exit 1; }
violations="$(host_cmd_violations "$allcalls")"
[[ -z "$violations" ]] || { echo "FAIL case9: 허용 목록 밖 호스트 명령:"; sed 's/^/  /' <<< "$violations"; exit 1; }

# (10) preflight.sh 는 run_preflight 의 종료 코드를 그대로 낸다.
printf 'run_preflight() { return 3; }\n' > "$tmp/fake-entrypoint.sh"
rc=0; ENTRYPOINT_PATH="$tmp/fake-entrypoint.sh" bash "$here/preflight.sh" || rc=$?
[[ "$rc" -eq 3 ]] || { echo "FAIL case10: rc=$rc (3 기대)"; exit 1; }

# (10b) 실제 entrypoint.sh 로 판정 불가 경로의 종료 코드. entrypoint.sh 는 source 하면서 set -Eeuo pipefail 을 켜므로
#       preflight.sh 의 set +eE 가 없으면 run_preflight 안에서 실패한 호스트 명령의 종료 코드가 그대로 프로세스 종료
#       코드가 된다. 그 값이 3 이면 operator 는 hold 충돌로 읽어 설치를 막는다. 항상 3 으로 실패하는 가짜 nsenter 를
#       PATH 맨 앞에 두면 ns 가 호스트에 닿지 않아 GPU·네트워크·권한과 무관하게 같은 경로(apt_wait 실패)를 탄다.
#       SKIP_ON_PASSTHROUGH=false 로 GPU 조회를 건너뛰고, 종료 메시지는 임시 파일에 받는다. 기대: 종료 코드 1 과 사유.
#       임시 디렉터리가 noexec 이면 가짜를 실행할 수 없어 PATH 탐색이 실제 nsenter 로 넘어가므로, 가짜가 먼저
#       잡히는지 확인하고 아니면 실행하지 않는다.
mkdir -p "$tmp/fakebin"; printf '#!/bin/sh\nexit 3\n' > "$tmp/fakebin/nsenter"; chmod +x "$tmp/fakebin/nsenter"
[[ "$(PATH="$tmp/fakebin:$PATH"; command -v nsenter)" == "$tmp/fakebin/nsenter" ]] \
  || { echo "FAIL case10b: 가짜 nsenter 를 실행할 수 없다 — TMPDIR(${TMPDIR:-/tmp})이 noexec 인가? 실제 nsenter 가 호스트에 닿지 않게 중단한다"; exit 1; }
: > "$tmp/term-real"
rc=0
PATH="$tmp/fakebin:$PATH" ENTRYPOINT_PATH="$here/entrypoint.sh" TERMINATION_LOG="$tmp/term-real" \
  SKIP_ON_PASSTHROUGH=false DRIVER_VERSION=580.178.04 bash "$here/preflight.sh" >"$tmp/out-real" 2>&1 || rc=$?
[[ "$rc" -eq 1 ]] && grep -q '판정 불가' "$tmp/term-real" \
  || { echo "FAIL case10b: rc=$rc (1 기대) term=$(cat "$tmp/term-real") out=$(head -c 300 "$tmp/out-real")"; exit 1; }

# (11) 이미지가 preflight.sh 를 담고 실행 권한을 준다.
df="$here/Dockerfile.v17"
[[ "$(grep -cF 'COPY preflight.sh /usr/local/bin/preflight.sh' "$df")" == "1" ]] || { echo "FAIL case11a"; exit 1; }
grep -qF '/usr/local/bin/preflight.sh' <(sed -n '/^RUN chmod +x \/usr\/local\/bin\/entrypoint.sh/,/^$/p' "$df") \
  || { echo "FAIL case11b: chmod 목록에 없음"; exit 1; }

echo "PASS: preflight_test"
