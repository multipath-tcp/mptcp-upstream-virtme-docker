#!/bin/bash -e
DIR="$(dirname "$(realpath -P "${0}")")"
docker -v >/dev/null

export DOCKER_VIRTME_NAME="virtme"

"${DIR}/build.sh"
"${DIR}/run.sh" "${@}"
