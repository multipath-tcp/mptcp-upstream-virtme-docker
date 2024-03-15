#!/bin/bash -e
# SPDX-License-Identifier: GPL-2.0
DIR="$(dirname "$(realpath -P "${0}")")"
docker -v >/dev/null

bash "-${-}" "${DIR}/pull.sh"
bash "-${-}" "${DIR}/run.sh" "${@}"
