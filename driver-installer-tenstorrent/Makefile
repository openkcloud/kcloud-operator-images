# ============================================================
# Makefile: Tenstorrent tt-kmd 드라이버 컨테이너 빌드/배포 자동화
# 상세: baked-source(air-gap) + job모드 이미지. REGISTRY 가 가리키는 레지스트리로 push.
#       버전별 태그 0.2.0-kmd<ver> (기존 0.1.x 태그 재사용 금지).
#       사내 미러는 REGISTRY=<사내 미러>/kcloud make ... 로 덮어쓴다.
# 생성일: 2026-04-22 | 수정일: 2026-09-09
# ============================================================

REGISTRY  ?= ghcr.io/openkcloud
REPO      ?= tenstorrent-driver-ds

# 빌드할 tt-kmd 버전 (override: make build TT_KMD_VERSION=2.9.0 TT_KMD_GIT_TAG=ttkmd-2.9.0)
TT_KMD_VERSION ?= 2.8.0
TT_KMD_GIT_TAG ?= ttkmd-$(TT_KMD_VERSION)
IMAGE_TAG      ?= 0.2.0-kmd$(TT_KMD_VERSION)
IMG            ?= $(REGISTRY)/$(REPO):$(IMAGE_TAG)

.PHONY: all build push build-all help

all: build

## build: 지정 버전 이미지 빌드
build:
	docker build \
	  --build-arg TT_KMD_VERSION=$(TT_KMD_VERSION) \
	  --build-arg TT_KMD_GIT_TAG=$(TT_KMD_GIT_TAG) \
	  -t $(IMG) .

## push: 레지스트리에 push
push:
	docker push $(IMG)

## build-all: 2.8.0(기준) + 2.9.0(대체) 두 버전 빌드
build-all:
	$(MAKE) build push TT_KMD_VERSION=2.8.0
	$(MAKE) build push TT_KMD_VERSION=2.9.0

## help: 타겟 목록
help:
	@grep -E '^## ' Makefile | sed 's/## //'
