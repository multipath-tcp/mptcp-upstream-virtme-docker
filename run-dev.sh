#!/bin/bash
DIR="$(dirname "$(realpath -P "${0}")")"
docker run \
	-v "${PWD}:${PWD}:rw" \
	-v "${DIR}/entrypoint.sh:/entrypoint.sh:ro" \
	-w "${PWD}" \
	-e "VIRTME_NO_BLOCK" \
	--privileged \
	--rm \
	-it \
	virtme "${@}"
