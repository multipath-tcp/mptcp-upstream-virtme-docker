#!/bin/bash
DIR="$(dirname "$(realpath -P "${0}")")"
"${DIR}/build.sh"
"${DIR}/run.sh"
