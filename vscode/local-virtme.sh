#! /bin/bash
# SPDX-License-Identifier: GPL-2.0

# Some functions will be called indirectly, see the 'custom' commands below.
# shellcheck disable=SC2317

export VIRTME_NO_INTERACTIVE=1
export INPUT_CLANG="1"
export MAKE="./.virtme.sh make"
export SILENT_BUILD_FLAG=" "
export SPINNER=0

cd "${SCRIPT_DIR}/.." || exit 1

defconfig() {
	if [ ! -f .virtme/build-clang/.config ]; then
		./.virtme.sh defconfig
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
