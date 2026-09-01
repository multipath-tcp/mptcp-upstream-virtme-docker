#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

VIRTME_INTERACTIVE=""
test -t 1 && VIRTME_INTERACTIVE="-t"
[ "${VIRTME_NO_INTERACTIVE}" != 1 ] && VIRTME_INTERACTIVE="-it"
[ -z "${VIRTME_SYZKALLER_PATH}" ] && [ -d ../syzkaller ] && VIRTME_SYZKALLER_PATH="$(realpath "../syzkaller")"
[ -z "${VIRTME_IPROUTE2_PATH}" ] && [ -d ../iproute2 ] && VIRTME_IPROUTE2_PATH="$(realpath "../iproute2")"

# host is different if worktree are used
VIRTME_GIT_DIR="$(realpath "$(git rev-parse --git-common-dir)")"
VIRTME_REAL_DIR="$(realpath .virtme)"

HOME_DIR="$(realpath "$(dirname "${0}")/.home")"
mkdir -p "${HOME_DIR}"

envs=()
for env in "${!INPUT_@}"; do
	envs+=(-e "${env}=${!env}")
done

ports=()
if [ -z "$(docker ps --filter "label=name=mptcp-upstream-virtme-docker" --format '{{.Ports}}')" ]; then
	ports+=(-p 127.0.0.1:1234-1238:1234-1238
		-p 127.0.0.1:3636-3640:3636-3640)
fi

docker run \
	-v "${PWD}:${PWD}:rw" \
	-v "${VIRTME_GIT_DIR}:${VIRTME_GIT_DIR}:ro" \
	-v "${VIRTME_REAL_DIR}:${VIRTME_REAL_DIR}:rw" \
	${VIRTME_PACKETDRILL_PATH:+-v "${VIRTME_PACKETDRILL_PATH}:/opt/packetdrill:rw"} \
	-v "${HOME_DIR}:/root" \
	-v "/etc/localtime:/etc/localtime:ro" \
	${VIRTME_SYZKALLER_PATH:+ -v "${VIRTME_SYZKALLER_PATH}:/opt/syzkaller:rw"} \
	${VIRTME_IPROUTE2_PATH:+ -v "${VIRTME_IPROUTE2_PATH}:${VIRTME_IPROUTE2_PATH}:rw"} \
	${VIRTME_NG_PATH:+ -v "${VIRTME_NG_PATH}:/opt/virtme-ng:ro"} \
	-w "${PWD}" \
	-e "INPUT_PACKETDRILL_NO_SYNC=${VIRTME_PACKETDRILL_PATH:+1}" \
	-e "INPUT_PACKETDRILL_NO_MORE_TOLERANCE=${VIRTME_PACKETDRILL_PATH:+1}" \
	-e "INPUT_PACKETDRILL_STABLE=${VIRTME_PACKETDRILL_STABLE:-0}" \
	"${envs[@]}" \
	-e "VIRTME_ARCH" \
	-e "COMPILER" \
	-e "CI" \
	"${ports[@]}" \
	--privileged \
	--rm \
	${VIRTME_INTERACTIVE} \
	"${DOCKER_VIRTME_NAME:-"mptcp/mptcp-upstream-virtme-docker:latest"}" \
	"${@}"
