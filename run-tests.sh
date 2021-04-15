#!/bin/bash -e
DIR="$(dirname "$(realpath -P "${0}")")"
docker -v >/dev/null

"${DIR}/pull.sh"
"${DIR}/run.sh" "${@}"
