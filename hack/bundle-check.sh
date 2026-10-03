#!/usr/bin/env bash
# ============================================================
# bundle-check.sh: 발행 목록과 저장소 실재의 정합을 검사한다.
# 상세: images.yaml 의 모든 항목에 대해 그 dir 와 Dockerfile 이 실재하는지,
#       release-bundle.yaml 의 모든 항목이 images.yaml 의 키인지, 발행 워크플로의
#       수동 실행 선택지가 images.yaml 키 집합과 같은지 본다. dockerfile 키가
#       없으면 dir 아래 Dockerfile 을 본다. 인자로 git ref 를 주면 체크아웃 대신
#       그 ref 의 트리를 검사한다(공개 브랜치 검사용). 어긋나면 종료 코드 1.
#       사용: hack/bundle-check.sh [<git ref>]
# 생성일: 2026-10-03 | 수정일: 2026-10-03 (워크플로 선택지 정합 검사 추가)
# ============================================================
set -euo pipefail

cd "$(dirname "$0")/.."
ref="${1:-}"
what="${ref:-작업 트리}"

# ref 가 없으면 체크아웃을, 있으면 그 ref 의 트리를 본다.
read_blob() {
  if [ -n "$ref" ]; then
    git show "${ref}:$1" 2>/dev/null || true
  else
    cat "$1" 2>/dev/null || true
  fi
}

dir_exists() {
  if [ -n "$ref" ]; then
    [ -n "$(git ls-tree -d "$ref" -- "$1")" ]
  else
    [ -d "$1" ]
  fi
}

file_exists() {
  if [ -n "$ref" ]; then
    # ls-tree 는 디렉터리도 출력하므로 blob 인지까지 본다.
    [ "$(git ls-tree "$ref" -- "$1" | awk '{print $2}')" = "blob" ]
  else
    [ -f "$1" ]
  fi
}

images_yaml="$(read_blob images.yaml)"
if [ -z "$images_yaml" ]; then
  echo "!! images.yaml 을 읽지 못했다 (${what})." >&2
  exit 1
fi

# snap yq 는 /tmp 를 읽지 못한다. YAML 파싱은 python3 PyYAML 로 한다.
image_entries() {
  printf '%s\n' "$images_yaml" | python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin) or {}
for k, v in (d.get("images") or {}).items():
    v = v or {}
    print("%s\t%s\t%s" % (k, v.get("dir", ""), v.get("dockerfile") or "Dockerfile"))
'
}

bundle_entries() {
  printf '%s\n' "$1" | python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin) or {}
for b, items in (d.get("bundles") or {}).items():
    for it in (items or []):
        print("%s\t%s" % (b, (it or {}).get("image", "")))
'
}

fail=0
names=""

# 프로세스 치환 안의 파싱 실패는 set -e 가 잡지 못한다. 먼저 변수로 받는다.
images_list="$(image_entries)"
if [ -z "$images_list" ]; then
  echo "!! images.yaml 에 images 항목이 없다 (${what})." >&2
  exit 1
fi

while IFS=$'\t' read -r name dir dockerfile; do
  [ -n "$name" ] || continue
  names="${names}${name}
"
  if [ -z "$dir" ]; then
    echo "!! images.yaml: ${name} 에 dir 가 없다." >&2
    fail=1
  elif ! dir_exists "$dir"; then
    # dir 가 없으면 그 아래 Dockerfile 도 없다. 한 번만 보고한다.
    echo "!! images.yaml: ${name} 의 dir ${dir} 가 없다 (${what})." >&2
    fail=1
  elif ! file_exists "${dir}/${dockerfile}"; then
    echo "!! images.yaml: ${name} 의 ${dir}/${dockerfile} 가 없다 (${what})." >&2
    fail=1
  fi
done <<< "$images_list"

# 발행 워크플로의 수동 실행 선택지는 images.yaml 키 집합과 같아야 한다. 공개 트리 변환이
# 한쪽만 고치면 빌드 경로가 없는 이미지가 선택지로 남아 고르는 순간 발행이 깨진다.
workflow=.github/workflows/publish-image.yml
workflow_yaml="$(read_blob "$workflow")"
if [ -z "$workflow_yaml" ]; then
  echo "!! ${workflow} 를 읽지 못했다 (${what})." >&2
  fail=1
else
  # YAML 1.1 예약어라 on: 이 불리언 True 로 파싱된다. 두 키를 다 본다.
  choices="$(printf '%s\n' "$workflow_yaml" | python3 -c '
import sys, yaml
w = yaml.safe_load(sys.stdin) or {}
on = w.get("on") or w.get(True) or {}
inputs = (on.get("workflow_dispatch") or {}).get("inputs") or {}
for c in ((inputs.get("image") or {}).get("options") or []):
    print(c)
')"
  if [ -z "$choices" ]; then
    echo "!! ${workflow} 에서 image 선택지를 찾지 못했다 (${what})." >&2
    fail=1
  else
    only_workflow="$(comm -23 <(sort -u <<< "$choices") <(printf '%s' "$names" | sort -u))"
    only_images="$(comm -13 <(sort -u <<< "$choices") <(printf '%s' "$names" | sort -u))"
    if [ -n "$only_workflow" ]; then
      echo "!! ${workflow} 선택지에만 있고 images.yaml 에 없다 (${what}):" \
        "$(tr '\n' ' ' <<< "$only_workflow")" >&2
      fail=1
    fi
    if [ -n "$only_images" ]; then
      echo "!! images.yaml 에만 있고 ${workflow} 선택지에 없다 (${what}):" \
        "$(tr '\n' ' ' <<< "$only_images")" >&2
      fail=1
    fi
  fi
fi

# 공개 브랜치에는 아직 이 파일이 없다. 없으면 검사할 묶음도 없다.
bundle_yaml="$(read_blob release-bundle.yaml)"
if [ -z "$bundle_yaml" ]; then
  echo ">> release-bundle.yaml 이 없어 묶음 검사는 건너뛴다 (${what})."
else
  bundle_list="$(bundle_entries "$bundle_yaml")"
  while IFS=$'\t' read -r bundle image; do
    [ -n "$bundle" ] || continue
    if [ -z "$image" ]; then
      echo "!! release-bundle.yaml: ${bundle} 묶음에 image 없는 항목이 있다." >&2
      fail=1
    elif ! printf '%s' "$names" | grep -qxF -- "$image"; then
      echo "!! release-bundle.yaml: ${bundle} 묶음의 ${image} 가 images.yaml 에 없다." >&2
      fail=1
    fi
  done <<< "$bundle_list"
fi

if [ "$fail" -ne 0 ]; then
  echo "!! 발행 목록과 실재가 어긋난다 (${what})." >&2
  exit 1
fi
echo ">> 발행 목록과 실재가 맞는다 (${what})."
