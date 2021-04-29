#!/bin/bash -e
DIR="$(dirname "$(realpath -P "${0}")")"
docker -v >/dev/null

bash "-${-}" "${DIR}/pull.sh"
bash "-${-}" "${DIR}/run.sh" "${@}"
