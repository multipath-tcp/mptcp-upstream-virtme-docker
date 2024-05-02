#! /bin/bash
# SPDX-License-Identifier: GPL-2.0

# Some functions will be called indirectly, see the 'custom' commands below.
# shellcheck disable=SC2317

export VIRTME_NO_INTERACTIVE=1
export INPUT_CLANG="1"
export SILENT_BUILD_FLAG=" "
export SPINNER=0
export MAKE

cd "${SCRIPT_DIR}/.." || exit 1

if [ -f ".virtme-clang.sh" ]; then
	VIRTME_CMD=(bash -e ./.virtme-clang.sh)
else
	VIRTME_CMD=(docker run --rm -t
			-e INPUT_CLANG=1
			-v "${PWD}:${PWD}:rw" -w "${PWD}"
			mptcp/mptcp-upstream-virtme-docker:latest)
fi
MAKE="${VIRTME_CMD[*]} make"

defconfig() {
	if [ ! -f .virtme/build-clang/.config ]; then
		"${VIRTME_CMD[@]}" defconfig
	fi
}

case "${COMMAND}" in
	"build" | "clean" | "menuconfig" | "update" | "systemtap-build")
		echo "local: allow: ${COMMAND}"
		;;
	"gdb-index")
		echo "local: skip: ${COMMAND}"
		exit 0
		;;
	"defconfig")
		echo "local: custom: ${COMMAND}"
		${COMMAND}
		exit
		;;
	*)
		echo "local: block: ${COMMAND}"
		exit 1
		;;
esac
