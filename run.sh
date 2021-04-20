#!/bin/bash
docker run \
	-v "${PWD}:${PWD}:rw" \
	-w "${PWD}" \
	-e "VIRTME_NO_BLOCK" \
	--privileged \
	--rm \
	-it \
	virtme "${@}"
