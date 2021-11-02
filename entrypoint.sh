#! /bin/bash
#
# The goal is to launch MPTCP kernel selftests
#
# Arguments:
#   - "manual": to have a console in the VM. Additional args are for the kconfig
#   - args we pass to kernel's "scripts/config" script.

# We should manage all errors in this script
set -e

is_ci() {
	[ "${CI}" = "true" ]
}

if is_ci || [ "${INPUT_TRACE}" = "1" ]; then
	set -x
fi

# The behaviour can be changed with 'input' env var
: "${INPUT_CCACHE_MAXSIZE:=5G}"
: "${INPUT_NO_BLOCK:=0}"
: "${INPUT_PACKETDRILL_NO_SYNC:=0}"
: "${INPUT_PACKETDRILL_NO_MORE_TOLERANCE:=0}"

KERNEL_SRC="${PWD}"

VIRTME_WORKDIR="${KERNEL_SRC}/.virtme"
VIRTME_BUILD_DIR="${VIRTME_WORKDIR}/build"
VIRTME_SCRIPTS_DIR="${VIRTME_WORKDIR}/scripts"
VIRTME_PERF_DIR="${VIRTME_BUILD_DIR}/perf"

VIRTME_KCONFIG="${VIRTME_BUILD_DIR}/.config"

VIRTME_SCRIPT="${VIRTME_SCRIPTS_DIR}/tests.sh"
VIRTME_SCRIPT_END="__VIRTME_END__"
VIRTME_EXPECT_TIMEOUT="3300" # 55 minutes: auto mode on CI only
VIRTME_RUN_SCRIPT="${VIRTME_SCRIPTS_DIR}/virtme.sh"
VIRTME_RUN_EXPECT="${VIRTME_SCRIPTS_DIR}/virtme.expect"

USR_INCLUDE_DIR="usr/include"
MPTCP_SELFTESTS_DIR="tools/testing/selftests/net/mptcp"

export CCACHE_MAXSIZE="${INPUT_CCACHE_MAXSIZE}"
export CCACHE_DIR="${VIRTME_WORKDIR}/ccache"

export KBUILD_OUTPUT="${VIRTME_BUILD_DIR}"
export KCONFIG_CONFIG="${VIRTME_KCONFIG}"

mkdir -p \
	"${VIRTME_BUILD_DIR}" \
	"${VIRTME_SCRIPTS_DIR}" \
	"${VIRTME_PERF_DIR}" \
	"${CCACHE_DIR}"

VIRTME_PROG_PATH="/opt/virtme"
VIRTME_CONFIGKERNEL="${VIRTME_PROG_PATH}/virtme-configkernel"
VIRTME_RUN="${VIRTME_PROG_PATH}/virtme-run"
VIRTME_RUN_OPTS=(--net --memory 2048M --kdir "${VIRTME_BUILD_DIR}" --mods=auto --rwdir "${KERNEL_SRC}" --pwd)
VIRTME_RUN_OPTS+=(--kopt mitigations=off)

# TODO: kmemleak (or all the time?)
# TODO: kfence (or all the time?)
KCONFIG_EXTRA_CHECKS=(
	-e KASAN -e KASAN_OUTLINE -d TEST_KASAN
	-e PROVE_LOCKING -e DEBUG_LOCKDEP
	-e PREEMPT -e DEBUG_PREEMPT
	-e DEBUG_SLAVE -e DEBUG_PAGEALLOC -e DEBUG_MUTEXES -e DEBUG_SPINLOCK -e DEBUG_ATOMIC_SLEEP
	-e PROVE_RCU -e DEBUG_OBJECTS_RCU_HEAD
)

# results dir
RESULTS_DIR_BASE="${VIRTME_WORKDIR}/results"
RESULTS_DIR=

# log files
OUTPUT_VIRTME=
TESTS_SUMMARY=
CONCLUSION="conclusion.txt"

EXIT_STATUS=0
EXIT_REASONS=()
EXIT_TITLE="KVM Validation"
EXPECT=0
VIRTME_EXEC_RUN="${KERNEL_SRC}/.virtme-exec-run"
VIRTME_EXEC_PRE="${KERNEL_SRC}/.virtme-exec-pre"
VIRTME_EXEC_POST="${KERNEL_SRC}/.virtme-exec-post"

COLOR_RED="\E[1;31m"
COLOR_GREEN="\E[1;32m"
COLOR_BLUE="\E[1;34m"
COLOR_RESET="\E[0m"

# $1: color, $2: text
print_color() {
	echo -e "${START_PRINT:-}${*}${COLOR_RESET}"
}

print() {
	print_color "${COLOR_GREEN}${*}"
}

printinfo() {
	print_color "${COLOR_BLUE}${*}"
}

printerr() {
	print_color "${COLOR_RED}${*}" >&2
}

_get_last_iproute_version() {
	curl https://git.kernel.org/pub/scm/network/iproute2/iproute2.git/refs/tags 2>/dev/null | \
		grep "/tag/?h=v[0-9]" | \
		cut -d\' -f2 | cut -d= -f2 | \
		sort -Vu | \
		tail -n1
}

check_last_iproute() { local last curr
	# only check on CI
	if ! is_ci; then
		return 0
	fi

	printinfo "Check IPRoute2 version"

	last="$(_get_last_iproute_version)"

	if [[ "${IPROUTE2_GIT_SHA}" == "v"* ]]; then
		curr="${IPROUTE2_GIT_SHA}"
		if [ "${curr}" = "${last}" ]; then
			printinfo "Using the last version of IPRoute2: ${last}"
		else
			printerr "Not the last version of IPRoute2: ${curr} < ${last}"
			return 1
		fi
	else
		printerr "TODO: check ip -V"
		exit 1
	fi

}

_check_source_exec_one() {
	local src="${1}"
	local reason="${2}"

	if [ -f "${src}" ]; then
		printinfo "This script file exists and will be used ${reason}: $(basename "${src}")"
		cat -n "${src}"

		if [ "${INPUT_NO_BLOCK}" = "1" ]; then
			printinfo "Check source exec: not blocking"
		else
			print "Press Enter to continue (use 'INPUT_NO_BLOCK=1' to avoid this)"
			read -r
		fi
	fi
}

check_source_exec_all() {
	printinfo "Check extented exec files"

	_check_source_exec_one "${VIRTME_EXEC_PRE}" "before the tests suite"
	_check_source_exec_one "${VIRTME_EXEC_RUN}" "to replace the execution of the whole tests suite"
	_check_source_exec_one "${VIRTME_EXEC_POST}" "after the tests suite"
}

_make() {
	make -j"$(nproc)" -l"$(nproc)" "${@}"
}

_make_o() {
	_make O="${VIRTME_BUILD_DIR}" "${@}"
}

# $1: source ; $2: target
_add_symlink() {
	local src="${1}"
	local dst="${2}"

	if [ -e "${dst}" ] && [ ! -L "${dst}" ]; then
		printerr "${dst} already exists and is not a symlink, please remove it"
		return 1
	fi

	ln -sf "${src}" "${dst}"
}

_add_workaround_selftests() { local f
	for f in "${VIRTME_BUILD_DIR}/${USR_INCLUDE_DIR}/"*; do
		_add_symlink "${f}" "${USR_INCLUDE_DIR}/$(basename "${f}")"
	done
}

# $@: extra kconfig
gen_kconfig() { local kconfig=()
	printinfo "Generate kernel config"

	# Extra options needed for MPTCP KUnit tests
	kconfig+=(-m KUNIT -e KUNIT_DEBUGFS -d KUNIT_ALL_TESTS -m MPTCP_KUNIT_TEST)

	# Extra options needed for packetdrill
	# note: we still need SHA1 for fallback tests with v0
	kconfig+=(-e TUN -e CRYPTO_USER_API_HASH -e CRYPTO_SHA1)

	# Debug info
	kconfig+=(
		-e DEBUG_INFO -e DEBUG_INFO_COMPRESSED -e DEBUG_INFO_DWARF4
		-e DEBUG_INFO_REDUCED -e DEBUG_INFO_SPLIT -e GDB_SCRIPTS
		-e DYNAMIC_DEBUG --set-val CONSOLE_LOGLEVEL_DEFAULT 8
		-e FTRACE -e FUNCTION_TRACER -e DYNAMIC_FTRACE
		-e FTRACE_SYSCALLS -e HIST_TRIGGERS
	)

	# Useful to reproduce issue
	kconfig+=(-e NET_SCH_TBF)

	# Disable retpoline to accelerate tests
	kconfig+=(-d RETPOLINE)

	# extra config
	if [ -n "${1}" ]; then
		kconfig+=("${@}")
	fi

	_make_o defconfig

	# KBUILD_OUTPUT is used by virtme
	"${VIRTME_CONFIGKERNEL}" --arch=x86_64 --update

	# Extra options are needed for MPTCP kselftests
	./scripts/kconfig/merge_config.sh -m "${VIRTME_KCONFIG}" "${MPTCP_SELFTESTS_DIR}/config"

	./scripts/config --file "${VIRTME_KCONFIG}" "${kconfig[@]}"

	_make_o olddefconfig
}

build_kernel() {
	_make_o
	_make_o headers_install
}

build_modules() {
	_make_o modules
	_make_o modules_install
}

build_headers() {
	_make_o INSTALL_HDR_PATH="${VIRTME_BUILD_DIR}/kselftest/usr" headers_install
}

build_perf() {
	cd tools/perf

	_make O="${VIRTME_PERF_DIR}" DESTDIR=/usr install

	cd "${KERNEL_SRC}"
}

build() {
	printinfo "Build the kernel"

	build_kernel
	build_modules
	build_perf
	build_headers
}

build_selftests() {
	# it doesn't seem OK to use a different output dir with our selftests
	_add_workaround_selftests
	_make_o -C "${MPTCP_SELFTESTS_DIR}"
}

build_packetdrill() { local old_pwd
	old_pwd="${PWD}"

	# make sure we have the last stable tests
	cd /opt/packetdrill/
	if [ "${INPUT_PACKETDRILL_NO_SYNC}" = "1" ]; then
		printinfo "Packetdrill: no sync"
	else
		git fetch origin
		git checkout -f "origin/${PACKETDRILL_GIT_BRANCH}"
	fi
	cd gtests/net/packetdrill/
	./configure
	_make

	cd ../mptcp
	if [ "${INPUT_PACKETDRILL_NO_MORE_TOLERANCE}" = "1" ]; then
		printinfo "Packetdrill: not modifying the tolerance"
	else
		local pf val new_val
		for pf in $(git grep -l "^--tolerance_usecs="); do
			# shellcheck disable=SC2013 # to filter duplicated ones
			for val in $(grep "^--tolerance_usecs=" "${pf}" | cut -d= -f2 | sort -u); do
				if [ "${mode}" = "debug" ]; then
					# Add higher tolerance in debug mode:
					# the environment can be very slow
					new_val=$((val * 10))
				else
					# double the time in normal mode:
					# public CI can be quite loaded...
					new_val=$((val * 2))
				fi

				sed -i "s/^--tolerance_usecs=${val}$/--tolerance_usecs=${new_val}/g" "${pf}"
			done
		done
	fi
	cd "${old_pwd}"
}

prepare() { local mode
	mode="${1:-}"

	printinfo "Prepare the environment"

	if is_ci; then
		# Root dir: not to have to go down dirs to get artifacts
		RESULTS_DIR="${KERNEL_SRC}"

		VIRTME_RUN_OPTS+=(--cpus "$(nproc)")

		EXIT_TITLE="${EXIT_TITLE}: ${mode}" # only one mode
	else
		# avoid override
		RESULTS_DIR="${RESULTS_DIR_BASE}/$(git rev-parse --short HEAD)/${mode}"
		rm -rf "${RESULTS_DIR}"
		mkdir -p "${RESULTS_DIR}"

		VIRTME_RUN_OPTS+=(--cpus 2) # limit to 2 cores for now

		# disable timeout
		VIRTME_EXPECT_TIMEOUT="-1"
	fi

	OUTPUT_VIRTME="${RESULTS_DIR}/output.log"
	TESTS_SUMMARY="${RESULTS_DIR}/summary.txt"
	CONCLUSION="${RESULTS_DIR}/${CONCLUSION}"

	local kunit_tap="${RESULTS_DIR}/kunit.tap"
	local mptcp_connect_mmap_tap="${RESULTS_DIR}/mptcp_connect_mmap.tap"
	local pktd_base="${RESULTS_DIR}/packetdrill"

	# for the kmods: TODO: still needed?
	mkdir -p /lib/modules

	build_selftests
	build_packetdrill

	cat <<EOF > "${VIRTME_SCRIPT}"
#! /bin/bash -x

# useful for virtme-exec-run
TAP_PREFIX="${KERNEL_SRC}/tools/testing/selftests/kselftest/prefix.pl"
RESULTS_DIR="${RESULTS_DIR}"
OUTPUT_VIRTME="${OUTPUT_VIRTME}"

# \$1: file ; \$2+: commands
_tap() { local out tmp fname rc
	out="\${1}"
	shift

	# With TAP, we have first the summary, then the diagnostic
	tmp="\${out}.tmp"
	fname="\$(basename \${out})"

	# init
	{
		echo "TAP version 13"
		echo "1..1"
	} | tee "\${out}"

	# Exec the command and pipe in tap prefix + store for later
	"\${@}" 2>&1 | "\${TAP_PREFIX}" | tee "\${tmp}"
	# output to stdout now to see the progression
	rc=\${PIPESTATUS[0]}

	# summary
	{
		if [ \${rc} -eq 0 ]; then
			echo "ok 1 test: \${fname}"
		else
			echo "not ok 1 test: \${fname} # exit=\${rc}"
		fi
	} | tee -a "\${out}"

	# diagnostic at the end with TAP
	cat "\${tmp}" >> "\${out}"
	rm -f "\${tmp}"

	return \${rc}
}

# $1: path to .ko file
_insmod() {
	if ! insmod "\${1}"; then
		echo "not ok 1 test: insmod \${1} # exit=1"
		return 1
	fi
}

# kunit name
_kunit_result() {
	if ! cat "/sys/kernel/debug/kunit/\${1}/results"; then
		echo "not ok 1 test: kunit result \${1} # exit=1"
		return 1
	fi

}

_run_kunit() { local ko kunit
	_insmod ${VIRTME_BUILD_DIR}/lib/kunit/kunit.ko || return \${?}

	echo "TAP version 14"
	echo "1..$(echo "${VIRTME_BUILD_DIR}/net/mptcp/"*_test.ko | wc -w)"

	for ko in ${VIRTME_BUILD_DIR}/net/mptcp/*_test.ko; do
		_insmod "\${ko}" || return \${?}

		kunit="\${ko#${VIRTME_BUILD_DIR}/}" # remove abs dir
		kunit="\${kunit:10:-8}" # remove net/mptcp (10) + _test.ko (8)
		kunit="\${kunit//_/-}" # dash
		_kunit_result "\${kunit}" || return \${?}
	done
}

run_kunit() {
	cd ${KERNEL_SRC}
	_run_kunit | tee "${kunit_tap}"
}

# \$1: output tap file; rest: command to launch
_run_selftest_one_tap() {
	cd "${KERNEL_SRC}/${MPTCP_SELFTESTS_DIR}"
	_tap "\${@}"
}

# \$1: script file; rest: command to launch
run_selftest_one() { local sf
	sf=\$(basename \${1})
	shift
	_run_selftest_one_tap "${RESULTS_DIR}/selftest_\${sf:0:-3}.tap" "./\${sf}" "\${@}"
}

run_selftest_all() { local sf
	# The following command re-do a slow headers install + compilation in a different dir
	#make O="${VIRTME_BUILD_DIR}" --silent -C tools/testing/selftests TARGETS=net/mptcp run_tests

	for sf in "${KERNEL_SRC}/${MPTCP_SELFTESTS_DIR}/"*.sh; do
		run_selftest_one "\${sf}"
	done
}

run_mptcp_connect_mmap() {
	_run_selftest_one_tap "${mptcp_connect_mmap_tap}" ./mptcp_connect.sh -m mmap
}

# \$1: pktd_dir (e.g. mptcp/dss)
run_packetdrill_one() { local pktd_dir="\${1}" pktd
	pktd="\${pktd_dir:6}"

	if [ "\${pktd}" = "common" ]; then
		return 0
	fi

	cd /opt/packetdrill/gtests/net/
	PYTHONUNBUFFERED=1 _tap "${pktd_base}_\${pktd}.tap" \
		./packetdrill/run_all.py -l -v \${pktd_dir}
}

run_packetdrill_all() { local pktd_dir
	cd /opt/packetdrill/gtests/net/

	for pktd_dir in mptcp/*; do
		run_packetdrill_one "\${pktd_dir}"
	done
}

has_call_trace() {
	grep -q "[C]all Trace:" "${OUTPUT_VIRTME}"
}

# args: what needs to be executed
run_loop() { local i
	i=1
	while true; do
		echo -e "\n\n\t=== Attempt: \${i} (\$(date -R)) ===\n\n"
		"\${@}" || break
		has_call_trace && break
		i=\$((i+1))
	done
	echo -e "\n\n\tStopped after \${i} attempts\n\n"
}

# To run commands before executing the tests
if [ -f "${VIRTME_EXEC_PRE}" ]; then
	source "${VIRTME_EXEC_PRE}"
	# e.g.:
	# echo "file net/mptcp/* +fmp" > /sys/kernel/debug/dynamic_debug/control
	# echo __mptcp_subflow_connect > /sys/kernel/tracing/set_graph_function
	# echo printk > /sys/kernel/tracing/set_graph_notrace
	# echo function_graph > /sys/kernel/tracing/current_tracer
fi

# To exec different tests than the full suite
if [ -f "${VIRTME_EXEC_RUN}" ]; then
	source "${VIRTME_EXEC_RUN}"
	# e.g.:
	# run_selftest_one ./mptcp_join.sh -f
	# run_loop run_selftest_one ./simult_flows.sh
	# run_packetdrill_one mptcp/dss
else
	run_kunit
	run_selftest_all
	run_mptcp_connect_mmap
	run_packetdrill_all
fi

# To run commands before executing the tests
if [ -f "${VIRTME_EXEC_POST}" ]; then
	source "${VIRTME_EXEC_POST}"
	# e.g.: cat /sys/kernel/tracing/trace
fi

# end
echo "${VIRTME_SCRIPT_END}"
EOF
	chmod +x "${VIRTME_SCRIPT}"
}

run() {
	printinfo "Run the virtme script: manual"

	"${VIRTME_RUN}" "${VIRTME_RUN_OPTS[@]}"
}

run_expect() {
	printinfo "Run the virtme script: expect"

	cat <<EOF > "${VIRTME_RUN_SCRIPT}"
#! /bin/bash -x
"${VIRTME_RUN}" ${VIRTME_RUN_OPTS[@]} 2>&1 | tr -d '\r'
EOF
	chmod +x "${VIRTME_RUN_SCRIPT}"

	cat <<EOF > "${VIRTME_RUN_EXPECT}"
#!/usr/bin/expect -f

set timeout "${VIRTME_EXPECT_TIMEOUT}"

spawn "${VIRTME_RUN_SCRIPT}"

expect "virtme-init: console is ttyS0\r"
send -- "stdbuf -oL ${VIRTME_SCRIPT}\r"

expect {
	"${VIRTME_SCRIPT_END}\r" {
		send_user "validation script ended with success\n"
	} timeout {
		send_user "Timeout: sending Ctrl+C\n"
		send "\x03"
	} eof {
		send_user "Unexpected stop of the VM\n"
		exit 1
	}
}
send -- "/usr/lib/klibc/bin/poweroff\r"

expect eof
EOF
	chmod +x "${VIRTME_RUN_EXPECT}"

	# for an unknown reason, we cannot use "--script-sh", qemu is not
	# started, no debug. As a workaround, we use expect.
	"${VIRTME_RUN_EXPECT}" | tee "${OUTPUT_VIRTME}"
}

_get_selftests_gen_files() {
	grep TEST_GEN_FILES "${MPTCP_SELFTESTS_DIR}/Makefile" | cut -d= -f2
}

ccache_stat() {
	if is_ci; then
		ccache -s
	fi
}

# $1: category ; $2: mode ; $3: reason
_register_issue() { local msg
	# only one mode in CI mode
	if is_ci; then
		msg="${1}: ${3}"
	else
		msg="${1} ('${2}' mode): ${3}"
	fi

	if [ "${#EXIT_REASONS[@]}" -eq 0 ]; then
		EXIT_REASONS=("${msg}")
	else
		EXIT_REASONS+=("-" "${msg}")
	fi
}

_had_issues() {
	[ ${#EXIT_REASONS[@]} -gt 0 ]
}

_had_critical_issues() {
	echo "${EXIT_REASONS[*]}" | grep -q "Critical"
}

# $1: end critical ; $2: end unstable
_print_issues() {
	echo -n "${EXIT_REASONS[*]} "
	if _had_critical_issues; then
		echo "${1}"
	else
		echo "${2}"
	fi
}

_has_call_trace() {
	grep -q "Call Trace:" "${OUTPUT_VIRTME}"
}

_print_line() {
	echo "=========================================="
}

_print_call_trace_info() {
	echo
	_print_line
	echo "Call Trace:"
	_print_line
	grep --text -C 80 "Call Trace:" "${OUTPUT_VIRTME}" | \
		./scripts/decode_stacktrace.sh "${VIRTME_BUILD_DIR}/vmlinux" "${KERNEL_SRC}" "${KERNEL_SRC}"
	_print_line
	echo "Call Trace found"
}

_get_call_trace_status() {
	echo "$(grep -c "Call Trace:" "${OUTPUT_VIRTME}") Call Trace(s)"
}

_has_timed_out() {
	! grep -q "${VIRTME_SCRIPT_END}" "${OUTPUT_VIRTME}"
}

_print_timed_out() {
	echo
	_print_line
	echo "Timeout:"
	_print_line
	tail -n 20 "${OUTPUT_VIRTME}"
	_print_line
	echo "Global Timeout"
}

# $1: mode, rest: args for kconfig
_print_summary_header() {
	local mode="${1}"
	shift

	echo "== Summary =="
	echo
	echo "Mode: ${mode}"
	echo "Extra kconfig: ${*:-/}"
	echo
}

# [ $1: .tap file, summary file by default]
_has_failed_tests() {
	grep -q "^not ok " "${1:-${TESTS_SUMMARY}}"
}

_print_tests_result() {
	echo "All tests:"
	grep --no-filename -e "^ok " -e "^not ok " "${RESULTS_DIR}"/*.tap
}

_print_failed_tests() { local t
	echo
	_print_line
	echo "Failed tests:"
	for t in "${RESULTS_DIR}"/*.tap; do
		if _has_failed_tests "${t}"; then
			_print_line
			echo "- $(basename "${t}"):"
			echo
			cat "${t}"
		fi
	done
	_print_line
}

_get_failed_tests() {
	# not ok 1 test: selftest_mptcp_join.tap # exit=1
	grep "^not ok " "${TESTS_SUMMARY}" | \
		awk '{ print $5 }' | \
		sort -u | \
		sed "s/\.tap$//g"
}

_get_failed_tests_status() { local t fails=()
	for t in $(_get_failed_tests); do
		fails+=("${t}")
	done

	echo "${#fails[@]} failed test(s): ${fails[*]}"
}

# $1: mode, rest: args for kconfig
analyze() {
	# reduce log that could be wrongly interpreted
	set +x

	local mode="${1}"
	shift

	printinfo "Analyze results"

	if is_ci; then
		LANG=C tap2junit "${RESULTS_DIR}"/*.tap
	fi

	echo -ne "\n${COLOR_GREEN}"
	_print_summary_header "${mode}" "${@}" | tee "${TESTS_SUMMARY}"
	_print_tests_result | tee -a "${TESTS_SUMMARY}"

	echo -ne "${COLOR_RESET}\n${COLOR_RED}"

	if _has_failed_tests; then
		# no tee, it can be long and less important than critical err
		_print_failed_tests >> "${TESTS_SUMMARY}"
		_register_issue "Unstable" "${mode}" "$(_get_failed_tests_status)"
		EXIT_STATUS=42
	fi

	# look for crashes/warnings
	if _has_call_trace; then
		_print_call_trace_info | tee -a "${TESTS_SUMMARY}"
		_register_issue "Critical" "${mode}" "$(_get_call_trace_status)"
		EXIT_STATUS=1

		if is_ci; then
			zstd -19 -T0 "${VIRTME_BUILD_DIR}/vmlinux" \
			     -o "${RESULTS_DIR}/vmlinux.zstd"
		fi
	fi

	if _has_timed_out; then
		_print_timed_out | tee -a "${TESTS_SUMMARY}"
		_register_issue "Critical" "${mode}" "Global Timeout"
		EXIT_STATUS=1
	fi

	echo -ne "${COLOR_RESET}"

	if [ "${EXIT_STATUS}" = "1" ]; then
		echo
		printerr "Critical issue(s) detected, exiting"
		exit 1
	fi
}

# $@: args for kconfig
go_manual() { local mode
	mode="${1}"
	shift

	printinfo "Start: manual (${mode})"

	gen_kconfig "${@}"
	build
	prepare "${mode}"
	run
}

# $1: mode ; $2+: args for kconfig
go_expect() { local mode
	mode="${1}"
	shift

	printinfo "Start: auto (${mode})"

	EXPECT=1

	ccache_stat
	check_last_iproute
	check_source_exec_all
	gen_kconfig "${@}"
	build
	prepare "${mode}"
	run_expect
	ccache_stat
	analyze "${mode}" "${@}"
}

static_analysis() { local src obj ftmp
	ftmp=$(mktemp)

	for src in net/mptcp/*.c; do
		obj="${src/%.c/.o}"
		if [[ "${src}" = *"_test.mod.c" ]]; then
			continue
		fi

		printinfo "Checking: ${src}"

		touch "${src}"
		if ! KCFLAGS="-Werror" make W=1 "${obj}"; then
			printerr "Found make W=1 issues for ${src}"
		fi

		touch "${src}"
		make C=1 "${obj}" >/dev/null 2>"${ftmp}" || true

		if test -s "${ftmp}"; then
			cat "${ftmp}"
			printerr "Found make C=1 issues for ${src}"
		fi
	done

	rm -f "${ftmp}"
}

clean() { local path
	# remove symlinks we added as a workaround for the selftests
	git clean -f -- "${USR_INCLUDE_DIR}"
	for path in $(_get_selftests_gen_files); do
		rm -fv "${MPTCP_SELFTESTS_DIR}/${path}"
	done
}

print_conclusion() { local rc=${1}
	echo -n "${EXIT_TITLE}: "

	if _had_issues; then
		_print_issues "❌" "🔴"
	elif [ "${rc}" != "0" ]; then
		echo "Script error! ❓"
	else
		echo "Success! ✅"
	fi
}

exit_trap() { local rc=${?}
	set +x

	# not needed on CI, remove some lines in the logs
	if ! is_ci; then
		clean
	fi

	echo -ne "\n${COLOR_BLUE}"
	if [ "${EXPECT}" = 1 ]; then
		print_conclusion ${rc} | tee "${CONCLUSION}"
	fi
	echo -e "${COLOR_RESET}"

	return ${rc}
}

usage() {
	echo "Usage: ${0} <manual-normal | manual-debug | auto-normal | auto-debug | auto-all> [KConfig]"
	echo
	echo " - manual: access to an interactive shell"
	echo " - auto: the tests suite is ran automatically"
	echo
	echo " - normal: without the debug kconfig"
	echo " - debug: with debug kconfig"
	echo " - all: both 'normal' and 'debug'"
	echo
	echo " - KConfig: optional kernel config: arguments for './scripts/config'"
	echo
	echo "Usage: ${0} <make [params] | make.cross [params] | cmd <command> | src <source file>>"
	echo
	echo " - make: run the make command with optional parameters"
	echo " - make.cross: run Intel's make.cross command with optional parameters"
	echo " - cmd: run the given command"
	echo " - src: source a given script file"
	echo
	echo "This script needs to be ran from the root of kernel source code."
	echo
	echo "Some files can be added in the kernel sources to modify the tests suite."
	echo "See the README file for more details."
}


MODE="${1}"
if [ -z "${MODE}" ]; then
	usage
	exit 0
fi
shift

if [ ! -s "net/mptcp/protocol.c" ]; then
	printerr "Please be at the root of kernel source code with MPTCP (Upstream) support"
	exit 1
fi


trap 'exit_trap' EXIT

case "${MODE}" in
	"manual" | "normal" | "manual-normal")
		go_manual "normal" "${@}"
		;;
	"debug" | "manual-debug")
		go_manual "debug" "${KCONFIG_EXTRA_CHECKS[@]}" "${@}"
		;;
	"expect-normal" | "auto-normal")
		go_expect "normal" "${@}"
		;;
	"expect-debug" | "auto-debug")
		go_expect "debug" "${KCONFIG_EXTRA_CHECKS[@]}" "${@}"
		;;
	"expect" | "all" | "expect-all" | "auto-all")
		# first with the minimum because configs like KASAN slow down the
		# tests execution, it might hide bugs
		go_expect "normal" "${@}"
		make clean
		go_expect "debug" "${KCONFIG_EXTRA_CHECKS[@]}" "${@}"
		;;
	"make")
		_make_o "${@}"
		;;
	"make.cross")
		MAKE_CROSS="/usr/sbin/make.cross"
		wget https://raw.githubusercontent.com/intel/lkp-tests/master/sbin/make.cross -O "${MAKE_CROSS}"
		chmod +x "${MAKE_CROSS}"
		COMPILER_INSTALL_PATH="${VIRTME_WORKDIR}/0day" \
			COMPILER="${COMPILER}" \
				"${MAKE_CROSS}" "${@}"
		;;
	"cmd" | "command")
		"${@}"
		;;
	"src" | "source" | "script")
		if [ ! -f "${1}" ]; then
			printerr "No such file: ${1}"
			exit 1
		fi

		# shellcheck disable=SC1090
		source "${1}"
		;;
	"static" | "static-analysis")
		static_analysis
		;;
	*)
		printerr "Unknown mode: ${MODE}"
		echo -e "${COLOR_RED}"
		usage
		echo -e "${COLOR_RESET}"
		exit 1
esac

if is_ci; then
	echo "==EXIT_STATUS=${EXIT_STATUS}=="
else
	exit "${EXIT_STATUS}"
fi
