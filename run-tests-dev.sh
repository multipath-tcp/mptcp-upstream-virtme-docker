#!/bin/bash -ex
# SPDX-License-Identifier: GPL-2.0
if [[ ${-} =~ "x" ]]; then
	if [ "${INPUT_TRACE}" = 0 ]; then
		set +x
	else
		export INPUT_TRACE=1
	fi
fi
export INPUT_NO_BLOCK="${INPUT_NO_BLOCK:-1}"

DIR="$(dirname "$(realpath -P "${0}")")"
docker -v >/dev/null

bash "-${-}" "${DIR}/build.sh"
docker system prune --filter "label=name=mptcp-upstream-virtme-docker" -f >&2

bash "-${-}" "${DIR}/run.sh" "${@}"
