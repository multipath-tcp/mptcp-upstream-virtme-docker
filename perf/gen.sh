#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Generate the YAML perf tests from the Jsonnet files.
# Usage: gen.sh [--check]
#  --check: only check the generated files are up to date.
#
# The Go version of Jsonnet is recommended: the C++ one is very slow to generate
# the YAML output.

set -e

cd "$(dirname "${0}")"

JSONNET="${JSONNET:-jsonnet}"

check=0
if [ "${1}" = "--check" ]; then
	check=1
	tmp=$(mktemp)
	trap 'rm -f "${tmp}"' EXIT
fi

# $1: jsonnet file, $2: output file
gen() {
	local src="${1}" out="${2}"

	{
		echo "# Generated from ${src} by gen.sh: do not edit"
		echo "# yaml-language-server: \$schema=./perf.schema"
		echo "# yamllint disable rule:line-length"
		echo "---"
		echo
		"${JSONNET}" -S -e "std.manifestYamlDoc(import '${src}', indent_array_in_object=true, quote_keys=false)"
	} >"${out}"
}

rc=0
for src in *.jsonnet; do
	out="${src%.jsonnet}.yml"

	if [ "${check}" = 1 ]; then
		gen "${src}" "${tmp}"
		if ! diff -u "${out}" "${tmp}"; then
			echo "${out} is not up to date, please run ${0}" >&2
			rc=1
		fi
	else
		gen "${src}" "${out}"
	fi
done

exit "${rc}"
