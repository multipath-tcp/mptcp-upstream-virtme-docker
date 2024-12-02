#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

VIRTME_INTERACTIVE=""
test -t 1 && VIRTME_INTERACTIVE="-t"
[ "${VIRTME_NO_INTERACTIVE}" != 1 ] && VIRTME_INTERACTIVE="-it"
[ -z "${VIRTME_SYZKALLER_PATH}" ] && [ -d ../syzkaller ] && VIRTME_SYZKALLER_PATH="$(realpath "../syzkaller")"

# host is different if worktree are used
VIRTME_GIT_DIR="$(realpath "$(git rev-parse --git-common-dir)")"

HOME_DIR="$(realpath "$(dirname "${0}")/.home")"

envs=()
for env in "${!INPUT_@}"; do
	envs+=(-e "${env}=${!env}")
done

docker run \
	-v "${PWD}:${PWD}:rw" \
	-v "${VIRTME_GIT_DIR}:${VIRTME_GIT_DIR}:ro" \
	${VIRTME_PACKETDRILL_PATH:+-v "${VIRTME_PACKETDRILL_PATH}:/opt/packetdrill:rw"} \
	-v "${HOME_DIR}:/root" \
	${VIRTME_SYZKALLER_PATH:+ -v "${VIRTME_SYZKALLER_PATH}:/opt/syzkaller:rw"} \
	${VIRTME_NG_PATH:+ -v "${VIRTME_NG_PATH}:/opt/virtme-ng:ro"} \
	-w "${PWD}" \
	-e "INPUT_PACKETDRILL_NO_SYNC=${VIRTME_PACKETDRILL_PATH:+1}" \
	-e "INPUT_PACKETDRILL_NO_MORE_TOLERANCE=${VIRTME_PACKETDRILL_PATH:+1}" \
	-e "INPUT_PACKETDRILL_STABLE=${VIRTME_PACKETDRILL_STABLE:-0}" \
	"${envs[@]}" \
	-e "VIRTME_ARCH" \
	-e "COMPILER" \
	--privileged \
	--rm \
	${VIRTME_INTERACTIVE} \
	"${DOCKER_VIRTME_NAME:-"mptcp/mptcp-upstream-virtme-docker:latest"}" \
	"${@}"
