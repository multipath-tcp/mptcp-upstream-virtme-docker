#!/bin/bash -e
# SPDX-License-Identifier: GPL-2.0
DIR="$(dirname "$(realpath -P "${0}")")"
CMD="$(basename "${0}")"

if [ "${CMD}" = "run-tests-dev-cmd.sh" ]; then
	if [ -n "${1}" ]; then
		CMD="${1}"
		shift
	else
		CMD="bash"
	fi
elif [[ "${CMD}" = ".virtme-run-"* ]]; then
	export VIRTME_NO_INTERACTIVE=1
	CMD="${CMD:12}"
elif [[ "${CMD}" = "mptcp-virtme-"* ]]; then
	export VIRTME_NO_INTERACTIVE=1
	CMD="${CMD:13}"
fi

bash "-${-}" "${DIR}/run-tests-dev.sh" cmd "${CMD}" "${@}"
