#!/bin/bash -ex
# SPDX-License-Identifier: GPL-2.0

cd "$(dirname "$(realpath -P "${0}")")"

ARGS=(
	-t "${DOCKER_VIRTME_NAME:-mptcp/mptcp-upstream-virtme-docker:latest}"
	-f Dockerfile
)

if [[ "${-}" =~ "x" ]]; then
	ARGS+=(--progress plain)
else
	echo "Building Docker image" >&2
	ARGS+=(--quiet)
fi

docker buildx build "${ARGS[@]}" "${@}" .
