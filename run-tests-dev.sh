#!/bin/bash -ex
DIR="$(dirname "$(realpath -P "${0}")")"
docker -v >/dev/null

export DOCKER_VIRTME_NAME="virtme"

if [[ "${-}" =~ "x" ]]; then
	export INPUT_TRACE=1
fi

bash "-${-}" "${DIR}/build.sh"
bash "-${-}" "${DIR}/run.sh" "${@}"
