#!/usr/bin/env bash
set -euo pipefail
REPO=rv-noble-main
REL=noble

SN_UNSTABLE=rv-main-unstable-$(date +%Y%m%d)
aptly snapshot create ${SN_UNSTABLE} from repo ${REPO}
aptly publish snapshot -distribution=${REL} -component=main ${SN_UNSTABLE} || true

# (선택) 자동/수동 테스트 통과 후 testing/stable로 승격
SN_TESTING=rv-main-testing-$(date +%Y%m%d)
aptly snapshot create ${SN_TESTING} from snapshot ${SN_UNSTABLE}
aptly publish switch ${REL} ${SN_TESTING} || aptly publish snapshot -distribution=${REL} ${SN_TESTING}
