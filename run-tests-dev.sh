#!/bin/bash -ex
DIR="$(dirname "$(realpath -P "${0}")")"
docker -v >/dev/null

export DOCKER_VIRTME_NAME="virtme"

if [[ "${-}" =~ "x" ]]; then
	export INPUT_TRACE=1
fi
export INPUT_NO_BLOCK="${INPUT_NO_BLOCK:-1}"

bash "-${-}" "${DIR}/build.sh"
docker system prune --filter "label=mptcp-upstream-virtme-docker" -f

bash "-${-}" "${DIR}/run.sh" "${@}"
