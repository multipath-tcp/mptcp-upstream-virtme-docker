#!/bin/bash -ex
# SPDX-License-Identifier: GPL-2.0

cd "$(dirname "$(realpath -P "${0}")")"

IMAGE=$(awk '/^FROM / {print $2; exit}' Dockerfile)
if [ -z "$(docker images -q --filter reference="${IMAGE}")" ]; then
	# Not to have to re-check if there is a new image
	docker pull "${IMAGE}"
fi

ARGS=(
	-t "${DOCKER_VIRTME_NAME:-mptcp/mptcp-upstream-virtme-docker:latest}"
	-f Dockerfile
)

if [[ ${-} =~ "x" ]]; then
	ARGS+=(--progress plain)
else
	echo "Building Docker image" >&2
	ARGS+=(--quiet)
fi

docker buildx build "${ARGS[@]}" "${@}" .
