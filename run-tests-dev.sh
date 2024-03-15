#!/bin/bash -ex
# SPDX-License-Identifier: GPL-2.0
DIR="$(dirname "$(realpath -P "${0}")")"
docker -v >/dev/null

if [[ "${-}" =~ "x" ]]; then
	export INPUT_TRACE=1
fi
export INPUT_NO_BLOCK="${INPUT_NO_BLOCK:-1}"

bash "-${-}" "${DIR}/build.sh"
docker system prune --filter "label=name=mptcp-upstream-virtme-docker" -f

bash "-${-}" "${DIR}/run.sh" "${@}"
