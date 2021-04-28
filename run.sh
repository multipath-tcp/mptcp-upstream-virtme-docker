#!/bin/bash
docker run \
	-v "${PWD}:${PWD}:rw" \
	${VIRTME_PACKETDRILL_PATH:+-v "${VIRTME_PACKETDRILL_PATH}:/opt/packetdrill:rw"} \
	-w "${PWD}" \
	-e "INPUT_NO_BLOCK" \
	-e "INPUT_PACKETDRILL_NO_SYNC=${VIRTME_PACKETDRILL_PATH:+1}" \
	--privileged \
	--rm \
	-it \
	"${DOCKER_VIRTME_NAME:-"mptcp/mptcp-upstream-virtme-docker:latest"}" \
	"${@}"
