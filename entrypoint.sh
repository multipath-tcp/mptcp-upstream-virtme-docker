#! /bin/bash
#
# The goal is to launch MPTCP kernel selftests
#
# Arguments:
#   - "manual": to have a console in the VM. Additional args are for the kconfig
#   - args we pass to kernel's "scripts/config" script.

# We should manage all errors in this script
set -e
set -x

KERNEL_SRC="${PWD}"

VIRTME_WORKDIR="${KERNEL_SRC}/.virtme"

VIRTME_BUILD_DIR="${VIRTME_WORKDIR}/build"
VIRTME_KCONFIG="${VIRTME_BUILD_DIR}/.config"

VIRTME_SCRIPTS="${VIRTME_WORKDIR}/scripts"
VIRTME_SCRIPT="${VIRTME_SCRIPTS}/tests.sh"
VIRTME_SCRIPT_END="__VIRTME_END__"
VIRTME_EXPECT_TIMEOUT="1500"
VIRTME_RUN_SCRIPT="${VIRTME_SCRIPTS}/virtme.sh"
VIRTME_RUN_EXPECT="${VIRTME_SCRIPTS}/virtme.expect"

LINUX_USR_HEADERS_DIR="usr/include/linux"
MPTCP_SELFTESTS_DIR="tools/testing/selftests/net/mptcp"

export CCACHE_MAXSIZE="${INPUT_CCACHE_MAXSIZE:-5G}"
export CCACHE_DIR="${VIRTME_WORKDIR}/ccache"

export O="${VIRTME_BUILD_DIR}"
export KBUILD_OUTPUT="${VIRTME_BUILD_DIR}"
export KCONFIG_CONFIG="${VIRTME_KCONFIG}"

mkdir -p \
	"${VIRTME_BUILD_DIR}" \
	"${VIRTME_SCRIPTS}" \
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

EXIT_STATUS=0

_get_last_iproute_version() {
	curl https://git.kernel.org/pub/scm/network/iproute2/iproute2.git/refs/tags 2>/dev/null | \
		grep "/tag/?h=v[0-9]" | \
		cut -d\' -f2 | cut -d= -f2 | \
		sort -Vu | \
		tail -n1
}

check_last_iproute() { local last curr
	last="$(_get_last_iproute_version)"

	if [[ "${IPROUTE2_GIT_SHA}" == "v"* ]]; then
		curr="${IPROUTE2_GIT_SHA}"
		if [ "${curr}" = "${last}" ]; then
			echo "Using the last version of IPRoute2: ${last}"
		else
			echo "Not the last version of IPRoute2: ${curr} < ${last}"
			return 1
		fi
	else
		echo "TODO: check ip -V"
		exit 1
	fi

}

_make() {
	make -j"$(nproc)" -l"$(nproc)" "${@}"
}

_make_o() {
	_make O="${VIRTME_BUILD_DIR}" "${@}"
}

# $1: source ; [ $2: target ]
_add_symlink() {
	local src="${1}"
	local dst="${2:-${1}}"

	if [ -e "${dst}" ] && [ ! -L "${dst}" ]; then
		echo "${dst} already exists and is not a symlink, please remove it"
		return 1
	fi

	ln -sf "${VIRTME_BUILD_DIR}/${src}" "${dst}"
}

_add_workaround_selftests() {
	_add_symlink "${LINUX_USR_HEADERS_DIR}"
}

# $@: extra kconfig
gen_kconfig() { local kconfig=()
	# Extra options needed for MPTCP KUnit tests
	kconfig+=(-m KUNIT -e KUNIT_DEBUGFS -d KUNIT_ALL_TESTS -m MPTCP_KUNIT_TESTS)

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

build() {
	_make_o
	_make_o headers_install
	_make_o modules
	_make_o modules_install

	# it doesn't seem OK to use a different output dir with our selftests
	_make_o INSTALL_HDR_PATH="${VIRTME_BUILD_DIR}/kselftest/usr" headers_install
	_add_workaround_selftests
	_make_o -C "${MPTCP_SELFTESTS_DIR}"
}

prepare() { local old_pwd mode
	old_pwd="${PWD}"
	mode="${1:-}"

	RESULTS_DIR="${RESULTS_DIR_BASE}/${mode}"
	OUTPUT_VIRTME="${RESULTS_DIR}/output.log"
	TESTS_SUMMARY="${RESULTS_DIR}/summary.txt"

	local kunit_tap="${RESULTS_DIR}/kunit.tap"
	local mptcp_connect_mmap_tap="${RESULTS_DIR}/mptcp_connect_mmap.tap"
	local dummy_tap="${RESULTS_DIR}/dummy.tap"
	local pktd_base="${RESULTS_DIR}/packetdrill"

	# for the kmods: TODO: still needed?
	mkdir -p /lib/modules

	# make sure we have the last stable tests
	cd /opt/packetdrill/
	git fetch origin
	git checkout -f "origin/${PACKETDRILL_GIT_BRANCH}"
	cd gtests/net/packetdrill/
	./configure
	_make

	cd ../mptcp
	if [ "${mode}" = "debug" ]; then
		# Add higher tolerance in debug mode
		git grep -l "^--tolerance_usecs" | \
			xargs sudo sed -i "s/^--tolerance_usecs=.*/&0/g"
	else
		# double the time in normal mode, CI can be quite loaded...
		git grep -l "^--tolerance_usecs=1" | \
			xargs sudo sed -i "s/^--tolerance_usecs=1/--tolerance_usecs=2/g"
	fi
	cd "${old_pwd}"

	rm -rf "${RESULTS_DIR}"
	mkdir -p "${RESULTS_DIR}"
	cat <<EOF > "${VIRTME_SCRIPT}"
#! /bin/bash -x

TAP_PREFIX="${KERNEL_SRC}/tools/testing/selftests/kselftest/prefix.pl"

# \$1: file ; \$2+: commands
tap() { local out tmp fname rc
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
		echo "not ok 1 test: insmod \${1} # exit=\${?}"
		return 1
	fi
}

# kunit name
_kunit_result() {
	if ! cat "/sys/kernel/debug/kunit/\${1}/results"; then
		echo "not ok 1 test: kunit result \${1} # exit=\${?}"
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
run_one_selftest_tap() {
	cd "${KERNEL_SRC}/${MPTCP_SELFTESTS_DIR}"
	tap "\${@}"
}

run_selftests() { local sf
	# The following command re-do a slow headers install + compilation in a different dir
	#make O="${VIRTME_BUILD_DIR}" --silent -C tools/testing/selftests TARGETS=net/mptcp run_tests

	for sf in "${KERNEL_SRC}/${MPTCP_SELFTESTS_DIR}/"*.sh; do
		sf=\$(basename \${sf})
		run_one_selftest_tap "${RESULTS_DIR}/selftest_\${sf:0:-3}.tap" "./\${sf}"
	done
}

# \$@: cmd to run
run_one_selftest() {
	run_one_selftest_tap "${dummy_tap}" "\${@}"
}

run_mptcp_connect_mmap() {
	run_one_selftest_tap "${mptcp_connect_mmap_tap}" ./mptcp_connect.sh -m mmap
}

# \$1: pktd_dir (e.g. mptcp/dss)
run_packetdrill_one() { local pktd_dir="\${1}" pktd
	pktd="\${pktd_dir:6}"

	if [ "\${pktd}" = "common" ]; then
		return 0
	fi

	cd /opt/packetdrill/gtests/net/
	PYTHONUNBUFFERED=1 tap "${pktd_base}_\${pktd}.tap" \
		./packetdrill/run_all.py -l -v \${pktd_dir}
}

run_packetdrill_all() { local pktd_dir
	cd /opt/packetdrill/gtests/net/

	for pktd_dir in mptcp/*; do
		run_packetdrill_one "\${pktd_dir}"
	done
}

# echo "file net/mptcp/* +fmp" > /sys/kernel/debug/dynamic_debug/control

run_kunit
run_selftests
run_mptcp_connect_mmap
run_packetdrill_all

# For "manual" tests only
#run_one_selftest ./mptcp_join.sh

# end
echo "${VIRTME_SCRIPT_END}"
EOF
	chmod +x "${VIRTME_SCRIPT}"
}

run() {
	sudo "${VIRTME_RUN}" "${VIRTME_RUN_OPTS[@]}"
}

run_expect() {
	cat <<EOF > "${VIRTME_RUN_SCRIPT}"
#! /bin/bash -x
sudo "${VIRTME_RUN}" ${VIRTME_RUN_OPTS[@]} 2>&1 | tr -d '\r'
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

is_ci() {
	[ "${CI}" = "true" ]
}

ccache_stat() {
	if is_ci; then
		ccache -s
	fi
}

# $@: args for kconfig
analyse() {
	# reduce log that could be wrongly interpreted
	set +x

	if is_ci; then
		LANG=C tap2junit "${RESULTS_DIR}"/*.tap
	fi

	# look for crashes/warnings
	if grep -q "Call Trace:" "${OUTPUT_VIRTME}"; then
		grep --text -C 80 "Call Trace:" "${OUTPUT_VIRTME}" | \
			./scripts/decode_stacktrace.sh "${VIRTME_BUILD_DIR}/vmlinux" "${KERNEL_SRC}" "${KERNEL_SRC}"
		echo "Call Trace found (additional kconfig: '${*}')"
		# exit directly, that's bad
		exit 1
	fi

	if ! grep -q "${VIRTME_SCRIPT_END}" "${OUTPUT_VIRTME}"; then
		echo "Timeout (additional kconfig: '${*}')"
		# exit directly, that's bad
		exit 1
	fi

	echo "== Tests Summary ==" | tee "${TESTS_SUMMARY}"
	grep -e "^ok " -e "^not ok " "${RESULTS_DIR}"/*.tap | tee -a "${TESTS_SUMMARY}"

	if grep -q "^not ok " "${TESTS_SUMMARY}"; then
		EXIT_STATUS=42
	fi
}

# $@: args for kconfig
go_manual() { local mode
	mode="${1}"
	shift

	gen_kconfig "${@}"
	build
	prepare "${mode}"
	run
}

# $1: mode ; $2+: args for kconfig
go_expect() { local mode
	mode="${1}"
	shift

	ccache_stat
	check_last_iproute
	gen_kconfig "${@}"
	build
	prepare "${mode}"
	run_expect
	ccache_stat
	analyse "${@}"
}

clean() { local path
	# remove symlinks we added as a workaround for the selftests
	rm -fv "${LINUX_USR_HEADERS_DIR}"
	for path in $(_get_selftests_gen_files); do
		rm -fv "${MPTCP_SELFTESTS_DIR}/${path}"
	done
}

exit_trap() {
	set +x
	clean
}


trap 'exit_trap' EXIT


if is_ci; then
	VIRTME_RUN_OPTS+=(--cpus "$(nproc)")
else
	VIRTME_RUN_OPTS+=(--cpus 2) # limit to 2 cores for now
	# avoid override
	RESULTS_DIR_BASE="${RESULTS_DIR_BASE}/$(git rev-parse --short HEAD)"
fi

# allow to launch anything else
if [ "${1}" = "manual" ]; then
	go_manual "${@}"
elif [ "${1}" = "debug" ]; then
	# note: we need to use "2" to skip the first arg with "$@" but we would
	# use 1 with any other arrays!
	# a=("${@}") ; ${a[@]:1} == ${@:2}
	go_manual "${1}" "${KCONFIG_EXTRA_CHECKS[@]}" "${@:2}"
elif [ "${1}" = "expect-normal" ]; then
	go_expect "normal" "${@:2}"
elif [ "${1}" = "expect-debug" ]; then
	go_expect "debug" "${KCONFIG_EXTRA_CHECKS[@]}" "${@:2}"
else
	# first with the minimum because configs like KASAN slow down the
	# tests execution, it might hide bugs
	go_expect "normal" "${@}"
	make clean
	go_expect "debug" "${KCONFIG_EXTRA_CHECKS[@]}" "${@}"
fi

exit "${EXIT_STATUS}"
