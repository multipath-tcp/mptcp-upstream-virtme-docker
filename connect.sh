#! /bin/bash
# SPDX-License-Identifier: GPL-2.0
DIR="$(dirname "$(realpath -P "${0}")")"

export INPUT_TRACE=0
if [[ "${-}" =~ "x" ]]; then
	INPUT_TRACE=1
fi
bash "-${-}" "${DIR}/container.sh" /entrypoint.sh connect "${@}"
