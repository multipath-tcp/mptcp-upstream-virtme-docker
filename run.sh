#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

VIRTME_INTERACTIVE=""
test -t 1 && VIRTME_INTERACTIVE="-t"
[ "${VIRTME_NO_INTERACTIVE}" != 1 ] && VIRTME_INTERACTIVE="-it"
[ -z "${VIRTME_SYZKALLER_PATH}" ] && [ -d ../syzkaller ] && VIRTME_SYZKALLER_PATH="$(realpath "../syzkaller")"

# host is different if worktree are used
VIRTME_GIT_DIR="$(realpath "$(git rev-parse --git-common-dir)")"

HOME_DIR="$(realpath "$(dirname "${0}")/.home")"

docker run \
	-v "${PWD}:${PWD}:rw" \
	-v "${VIRTME_GIT_DIR}:${VIRTME_GIT_DIR}:ro" \
	${VIRTME_PACKETDRILL_PATH:+-v "${VIRTME_PACKETDRILL_PATH}:/opt/packetdrill:rw"} \
	-v "${HOME_DIR}:/root" \
	${VIRTME_SYZKALLER_PATH:+ -v "${VIRTME_SYZKALLER_PATH}:/opt/syzkaller:rw"} \
	-w "${PWD}" \
	-e "INPUT_CLANG" \
	-e "INPUT_TRACE" \
	-e "INPUT_NO_BLOCK" \
	-e "INPUT_RUN_LOOP_CONTINUE" \
	-e "INPUT_BUILD_SKIP" \
	-e "INPUT_BUILD_SKIP_PERF" \
	-e "INPUT_BUILD_SKIP_SELFTESTS" \
	-e "INPUT_BUILD_SKIP_PACKETDRILL" \
	-e "INPUT_MAKE_ARGS" \
	-e "INPUT_RUN_TESTS_ONLY" \
	-e "INPUT_RUN_TESTS_EXCEPT" \
	-e "INPUT_SELFTESTS_DIR" \
	-e "INPUT_SELFTESTS_MPTCP_LIB_EXPECT_ALL_FEATURES" \
	-e "INPUT_SELFTESTS_MPTCP_LIB_OVERRIDE_FLAKY" \
	-e "INPUT_PACKETDRILL_NO_SYNC=${VIRTME_PACKETDRILL_PATH:+1}" \
	-e "INPUT_PACKETDRILL_NO_MORE_TOLERANCE=${INPUT_PACKETDRILL_NO_MORE_TOLERANCE:-${VIRTME_PACKETDRILL_PATH:+1}}" \
	-e "INPUT_PACKETDRILL_STABLE=${VIRTME_PACKETDRILL_STABLE:-0}" \
	-e "INPUT_EXPECT_TIMEOUT" \
	-e "INPUT_EXTRA_ENV" \
	-e "VIRTME_ARCH" \
	-e "COMPILER" \
	--privileged \
	--rm \
	${VIRTME_INTERACTIVE} \
	"${DOCKER_VIRTME_NAME:-"mptcp/mptcp-upstream-virtme-docker:latest"}" \
	"${@}"
