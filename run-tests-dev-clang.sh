#!/bin/bash -ex
# SPDX-License-Identifier: GPL-2.0
DIR="$(dirname "$(realpath -P "${0}")")"
export INPUT_CLANG=1

bash "-${-}" "${DIR}/run-tests-dev.sh" "${@}"
