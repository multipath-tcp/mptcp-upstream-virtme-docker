#! /bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# The goal is to launch (MPTCP) kernel selftests and more.
# But also to provide a dev env for kernel developers or testers.

# We should manage all errors in this script
set -e

is_ci() {
	[ "${CI}" = "true" ]
}

is_github_action() {
	[ "${GITHUB_ACTIONS}" = "true" ]
}

trace_needed() {
	[ "${INPUT_TRACE}" = "1" ]
}

set_trace_on() {
	if trace_needed; then
		set -x
	fi
}

set_trace_off() {
	if trace_needed; then
		set +x
	fi
}

with_clang() {
	[ "${INPUT_CLANG}" = "1" ]
}

set_trace_on

DEFAULT_VSOCK_CID="3"
DEFAULT_HOSTNAME="mptcpdev"

# The behaviour can be changed with 'input' env var
: "${INPUT_CCACHE_MAXSIZE:=5G}"
: "${INPUT_CCACHE_DIR:=""}"
: "${INPUT_CCACHE_DISABLE:=""}"
: "${INPUT_NO_BLOCK:=0}"
: "${INPUT_PACKETDRILL_NO_SYNC:=0}"
: "${INPUT_PACKETDRILL_NO_MORE_TOLERANCE:=0}"
: "${INPUT_PACKETDRILL_STABLE:=0}"
: "${INPUT_RUN_LOOP_CONTINUE:=0}"
: "${INPUT_RUN_TESTS_ONLY:=""}"
: "${INPUT_RUN_TESTS_EXCEPT:=""}"
: "${INPUT_SELFTESTS_DIR:=""}"
: "${INPUT_SELFTESTS_MPTCP_LIB_EXPECT_ALL_FEATURES:=1}"
: "${INPUT_SELFTESTS_MPTCP_LIB_OVERRIDE_FLAKY:=0}"
: "${INPUT_SELFTESTS_MPTCP_LIB_COLOR_FORCE:=1}"
: "${INPUT_HOSTNAME:="${DEFAULT_HOSTNAME}"}"
: "${INPUT_CPUS:=""}"
: "${INPUT_RAM:=""}"
: "${INPUT_GCOV:=""}"
: "${INPUT_NET_BRIDGES:=""}"
: "${INPUT_MAC_ADDRESS_PREFIX:=""}"
: "${INPUT_VSOCK_CID:="${DEFAULT_VSOCK_CID}"}"
: "${INPUT_CI_RESULTS_DIR:=""}"
: "${INPUT_CI_PRINT_EXIT_CODE:=1}"
: "${INPUT_CI_TIMEOUT_SEC:=7200}"
: "${INPUT_EXPECT_TIMEOUT:="-1"}"
: "${INPUT_BUILD_SKIP_PERF:=1}"
: "${INPUT_FULL_DUMP:=0}"

if [ -z "${INPUT_MODE}" ]; then
	INPUT_MODE="${1}"
	shift || true # none set
fi

# to be able to set an extra env var
if [[ ${INPUT_EXTRA_ENV} =~ ^"INPUT_"[A-Z0-9_]+"="[a-zA-Z0-9_]+$ ]]; then
	eval "${INPUT_EXTRA_ENV}"
fi

: "${PACKETDRILL_GIT_BRANCH:=mptcp-net-next}"
: "${VIRTME_ARCH:="$(uname -m)"}"

TIMESTAMPS_SEC_START=$(date +%s)
# CI only: estimated time before (clone + boot) and after (artifacts + debug
# output in case of timeout) running this script.
VIRTME_CI_ESTIMATED_EXTRA_TIME="540"

# max time to boot: it should take less than one minute with a debug kernel, *5 to be safe
VIRTME_EXPECT_BOOT_TIMEOUT="300"

# max time to shutdown: it should take one second
VIRTME_EXPECT_SHUTDOWN_TIMEOUT="60"

KERNEL_SRC="${PWD}"

# used to pass environment variables to the VM
BASH_PROFILE="/root/.bash_profile"

VIRTME_WORKDIR="${KERNEL_SRC}/.virtme"
VIRTME_SCRIPTS_DIR="${VIRTME_WORKDIR}/scripts"
VIRTME_CURRENT_BUILD_DIR="${INPUT_CURRENT_BUILD:-"${VIRTME_WORKDIR}/current_build"}"

VIRTME_SCRIPT="${VIRTME_SCRIPTS_DIR}/tests.sh"
VIRTME_SCRIPT_END="__VIRTME_END__"
VIRTME_SCRIPT_UNEXPECTED_STOP="Unexpected stop of the VM"
VIRTME_SCRIPT_TIMEOUT="${VIRTME_SCRIPTS_DIR}/tests.timeout"
VIRTME_SCRIPT_TIMEOUT_END="__VIRTME_TIMEOUT_END__"
VIRTME_SCRIPT_TIMEOUT_GDB="${VIRTME_SCRIPTS_DIR}/gdb.timeout"
VIRTME_SCRIPT_TIMEOUT_GDB_END="__VIRTME_TIMEOUT_GDB_END__"
VIRTME_RUN_SCRIPT="${VIRTME_SCRIPTS_DIR}/virtme.sh"
VIRTME_RUN_EXPECT="${VIRTME_SCRIPTS_DIR}/virtme.expect"

SELFTESTS_DIR="${INPUT_SELFTESTS_DIR:-tools/testing/selftests/net/mptcp}"
SELFTESTS_CONFIG="${SELFTESTS_DIR}/config"
BPFTESTS_DIR="${INPUT_BPFTESTS_DIR:-tools/testing/selftests/bpf}"
BPFTESTS_CONFIG="${BPFTESTS_DIR}/config"

export CCACHE_MAXSIZE="${INPUT_CCACHE_MAXSIZE}"
if [ -n "${INPUT_CCACHE_DISABLE}" ]; then
	export CCACHE_DISABLE="${INPUT_CCACHE_DISABLE}"
fi

VIRTME_CONFIGKERNEL="virtme-configkernel"
VIRTME_RUN="virtme-run"
VIRTME_RUN_OPTS=(
	--arch "${VIRTME_ARCH}"
	--name "${INPUT_HOSTNAME}"
	--mods=auto
	--rw                 # "rwdir" will use 9p ; in a container, use "rw"
	--overlay-rwdir /tmp # to support O_TMPFILE feature
	--pwd
	--server --port "${INPUT_VSOCK_CID}" # To connect to the VM using VSock
	--show-command
	--verbose --show-boot-console
	--kopt nokaslr # needed for gdb
	--kopt mitigations=off
)
VIRTME_RUN_QEMU_OPTS=(
	-gdb tcp::$((1234 + INPUT_VSOCK_CID - DEFAULT_VSOCK_CID))
	-qmp "tcp::$((3636 + INPUT_VSOCK_CID - DEFAULT_VSOCK_CID)),server,nowait"
)

# results dir
RESULTS_DIR_BASE="${VIRTME_WORKDIR}/results"
RESULTS_DIR=

# log files
OUTPUT_VIRTME=
TESTS_SUMMARY=
CONCLUSION=
KMEMLEAK=
LCOV_FILE=
LCOV_TXT=
LCOV_HTML=

EXIT_STATUS=0
EXIT_REASONS=()
CRITICAL_ERRORS=()
OTHER_ERRORS=()
EXIT_TITLE="KVM Validation"
EXPECT=0
VIRTME_EXEC_RUN="${INPUT_VIRTME_EXEC_RUN:-"${KERNEL_SRC}/.virtme-exec-run"}"
VIRTME_EXEC_PRE="${KERNEL_SRC}/.virtme-exec-pre"
VIRTME_EXEC_POST="${KERNEL_SRC}/.virtme-exec-post"
VIRTME_PREPARE_POST="${KERNEL_SRC}/.virtme-prepare-post"

COLOR_RED="\E[1;31m"
COLOR_GREEN="\E[1;32m"
COLOR_YELLOW="\E[1;33m"
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

if is_github_action; then
	# $1: description
	log_section_start() {
		echo -e "\n::group::${COLOR_YELLOW}${*}${COLOR_RESET}"
	}

	# $1: description
	log_section_start_no_color() {
		echo -e "\n::group::${*}"
	}

	log_section_end() {
		echo -e "::endgroup::\n"
	}
else
	# $1: description
	log_section_start() {
		printinfo "${@}"
	}

	# $1: description
	log_section_start_no_color() {
		echo "${START_PRINT:-}${*}"
	}

	log_section_end() {
		true
	}
fi

# $1: mode
is_mode_normal() {
	[[ ${1} == *"normal" ]]
}

# $1: mode
is_mode_debug() {
	[[ ${1} == *"debug" ]]
}

# $1: mode
is_mode_btf() {
	[[ ${1} == "btf-"* ]]
}

_get_results_dir_suffix() {
	if [ "${INPUT_HOSTNAME}" != "${DEFAULT_HOSTNAME}" ] ||
		[ "${INPUT_VSOCK_CID}" != "${DEFAULT_VSOCK_CID}" ]; then
		echo "/${INPUT_HOSTNAME}_${INPUT_VSOCK_CID}"
	fi
}

# $1: mode
_get_results_dir() {
	local sha host
	sha="$(git rev-parse --short HEAD || echo "UNKNOWN")"
	host="$(_get_results_dir_suffix)"

	echo "${RESULTS_DIR_BASE}/${sha}/${1}${host}"
}

# $1: iterations (.1 sec)
wait_prev_vm() {
	for _ in $(seq "${1}"); do
		[ -f "/tmp/virtme-console/${INPUT_VSOCK_CID}.sh" ] || return 0
		sleep .1
	done
	return 1
}

# $1: pid
kill_wait() {
	local pid="${1}"
	if [ -z "${pid}" ]; then
		return
	fi

	kill "${pid}"
	while [ -d "/proc/${pid}" ]; do
		sleep 0.1
	done
}

# $1: bridge name
_add_bridge() {
	local router static
	local br="${1}"

	local i="${br//[^0-9]/}" # only the numbers
	local prefix="10.0.${i}"
	local conf="/tmp/udhcpd-${br}.conf"
	local pidfile="/var/run/udhcpd-${br}.pid"
	local leases="/var/lib/misc/udhcpd-${br}.leases"

	VIRTME_RUN_OPTS+=("--net=bridge=${br}")

	if [ -n "${INPUT_MAC_ADDRESS_PREFIX}" ]; then
		static="static_lease	${INPUT_MAC_ADDRESS_PREFIX%=*}:0${i}	${prefix}.${INPUT_MAC_ADDRESS_PREFIX#*=}"
	fi

	# already setup from another VM?
	if grep -wq "${br}" /etc/qemu/bridge.conf; then
		if [ -n "${static}" ]; then
			echo "${static}" >>"${conf}"
			kill_wait "$(<"${pidfile}")"
			busybox udhcpd "${conf}"
		fi

		return 0
	fi

	echo "allow ${br}" >>/etc/qemu/bridge.conf
	brctl addbr "${br}"
	ip addr add "${prefix}.1/24" dev "${br}"
	ip link set dev "${br}" mtu 12000 up

	# one default address
	if [ "${i}" = "0" ]; then
		router="opt	router	${prefix}.1"
	fi

	cat <<-EOF >"${conf}"
		start      ${prefix}.2
		end        ${prefix}.254
		interface  ${br}
		pidfile    ${pidfile}
		lease_file ${leases}
		opt        subnet 255.255.255.0
		${router}
		${static}
	EOF

	touch "${leases}" # to avoid a warning
	busybox udhcpd "${conf}"
}

_setup_bridges() {
	chmod u+s /usr/lib/qemu/qemu-bridge-helper
	mkdir -p /etc/qemu
	touch /etc/qemu/bridge.conf
	chmod 755 /etc/qemu/bridge.conf
	{
		sysctl -w net.bridge.bridge-nf-call-ip6tables=0
		sysctl -w net.bridge.bridge-nf-call-iptables=0
		sysctl -w net.bridge.bridge-nf-call-arptables=0
	} 2>/dev/null || true
	# only v4 for the moment
	if ! iptables -t nat -C POSTROUTING -s 10.0.0.0/16 -o eth0 -j MASQUERADE 2>/dev/null; then
		iptables -t nat -A POSTROUTING -s 10.0.0.0/16 -o eth0 -j MASQUERADE
	fi

	if [ -n "${INPUT_MAC_ADDRESS_PREFIX}" ]; then
		VIRTME_RUN_OPTS+=("--net-mac-address" "${INPUT_MAC_ADDRESS_PREFIX%=*}:00")
	fi

	local br
	for br in "${@}"; do
		_add_bridge "${br}"
	done
}

setup_env() {
	local mode
	mode="${1}"

	log_section_start "Setup environment"

	EXIT_TITLE="${EXIT_TITLE}: ${mode}" # only one mode

	if [ -n "${INPUT_RUN_TESTS_ONLY}" ]; then
		EXIT_TITLE="${EXIT_TITLE} (only ${INPUT_RUN_TESTS_ONLY})"
	fi

	if [ -n "${INPUT_RUN_TESTS_EXCEPT}" ]; then
		EXIT_TITLE="${EXIT_TITLE} (except ${INPUT_RUN_TESTS_EXCEPT})"
	fi

	# Avoid 'unsafe repository' error: we need to get the rev/tag later from
	# this docker image
	git config --global --replace-all safe.directory "${KERNEL_SRC}" || true

	# Set a name, just in case for automations
	git config --global user.name "MPTCP Virtme Docker"
	git config --global user.email "DO-NOT@SEND.THIS"

	# Avoid a long advice
	git config --global advice.detachedHead false

	mkdir -p "/root/.config/gdb"
	echo "add-auto-load-safe-path ${KERNEL_SRC}/scripts/gdb/vmlinux-gdb.py" \
		>"/root/.config/gdb/gdbinit"

	VIRTME_BUILD_DIR="${VIRTME_WORKDIR}/build"
	with_clang && VIRTME_BUILD_DIR+="-clang"
	is_mode_debug "${mode}" && VIRTME_BUILD_DIR+="-debug"
	is_mode_btf "${mode}" && VIRTME_BUILD_DIR+="-btf"
	[ -n "${INPUT_BUILD_SUFFIX}" ] && VIRTME_BUILD_DIR+="-${INPUT_BUILD_SUFFIX}"

	VIRTME_HEADERS_DIR="${VIRTME_BUILD_DIR}/usr/include"
	VIRTME_PERF_DIR="${VIRTME_BUILD_DIR}/tools/perf"
	VIRTME_TOOLS_SBIN_DIR="${VIRTME_BUILD_DIR}/tools/sbin"
	VIRTME_CACHE_DIR="${VIRTME_BUILD_DIR}/.cache"
	VIRTME_KCONFIG="${VIRTME_BUILD_DIR}/.config"
	if [ -n "${INPUT_CCACHE_DIR}" ]; then
		export CCACHE_DIR="${VIRTME_WORKDIR}/${INPUT_CCACHE_DIR}"
	else
		export CCACHE_DIR="${VIRTME_WORKDIR}/ccache"
		with_clang && CCACHE_DIR+="-clang"
		is_mode_debug "${mode}" && CCACHE_DIR+="-debug"
		is_mode_btf "${mode}" && CCACHE_DIR+="-btf"
		[ -n "${INPUT_BUILD_SUFFIX}" ] && CCACHE_DIR+="-${INPUT_BUILD_SUFFIX}"
	fi

	read -ra MAKE_ARGS <<<"${INPUT_MAKE_ARGS}"
	with_clang && MAKE_ARGS+=(LLVM=1 LLVM_IAS=1 CC=clang ARCH="${VIRTME_ARCH}")
	MAKE_ARGS_O=("${MAKE_ARGS[@]}" O="${VIRTME_BUILD_DIR}")

	export KBUILD_OUTPUT="${VIRTME_BUILD_DIR}"
	export KCONFIG_CONFIG="${VIRTME_KCONFIG}"

	if [ "${INPUT_CLEAN}" = 1 ]; then
		printinfo "Cleaning build dir: ${VIRTME_BUILD_DIR}"
		rm -rf "${VIRTME_BUILD_DIR}" "${VIRTME_PERF_DIR}"
	fi

	mkdir -p \
		"${VIRTME_BUILD_DIR}" \
		"${VIRTME_SCRIPTS_DIR}" \
		"${VIRTME_PERF_DIR}" \
		"${VIRTME_CACHE_DIR}" \
		"${CCACHE_DIR}"
	chmod 777 "${VIRTME_CACHE_DIR}" # to let users writting files there, e.g. clangd

	rm -rf "${VIRTME_CURRENT_BUILD_DIR}"
	ln -s "${VIRTME_BUILD_DIR}" "${VIRTME_CURRENT_BUILD_DIR}"

	local ram_mul=1
	if is_ci; then
		# Root dir: not to have to go down dirs to get artifacts
		RESULTS_DIR="${KERNEL_SRC}${INPUT_CI_RESULTS_DIR:+/${INPUT_CI_RESULTS_DIR}}$(_get_results_dir_suffix)"

		: "${INPUT_CPUS:=$(nproc)}" # use all available resources
		: "${INPUT_GCOV:=1}"
		ram_mul=2 # because it is available and dedicated to this task

		# The CI doesn't need to access to the outside world, so no '--net'
	else
		# avoid override
		RESULTS_DIR="$(_get_results_dir "${mode}")"
		if [ "${EXPECT}" != 0 ]; then
			rm -rf "${RESULTS_DIR}"
		fi

		: "${INPUT_CPUS:=4}" # limit to 4 cores for now
		: "${INPUT_GCOV:=0}"

		# add net support, can be useful, but delay the start of the tests (~1 sec?)
		if [ -z "${INPUT_NET_BRIDGES}" ]; then
			VIRTME_RUN_OPTS+=("--net")
		fi
	fi

	if [ -n "${INPUT_NET_BRIDGES}" ]; then
		local bridges
		IFS=',' read -ra bridges <<<"${INPUT_NET_BRIDGES}"
		_setup_bridges "${bridges[@]}"
	fi

	# More needed for GCOV, not to swap
	: "${INPUT_RAM:="$((512 * INPUT_CPUS * ram_mul + 1024 * INPUT_GCOV))M"}"

	VIRTME_RUN_OPTS+=(
		--kdir "${VIRTME_BUILD_DIR}"
		--cpus "${INPUT_CPUS}"
		--memory "${INPUT_RAM}"
	)

	# instead of blocking
	VIRTME_RUN_OPTS+=(
		--kopt softlockup_panic=1
		--kopt nmi_watchdog=1
		--kopt hung_task_panic=1
		--kopt workqueue.panic_on_stall=1
		--kopt ftrace_dump_on_oops
	)

	if [ "${INPUT_FULL_DUMP}" = 1 ]; then
		VIRTME_RUN_OPTS+=(--disable-microvm)
		VIRTME_RUN_QEMU_OPTS+=(-device vmcoreinfo)
	fi

	if [ -n "${INPUT_KOPTS}" ]; then
		local array=() kopt
		read -r -a array <<<"${INPUT_KOPTS}"
		for kopt in "${array[@]}"; do
			VIRTME_RUN_OPTS+=(--kopt "${kopt}")
		done
	fi

	if [ -n "${INPUT_VIRTME_RUN_OPTS}" ]; then
		local array=()
		read -r -a array <<<"${INPUT_VIRTME_RUN_OPTS}"
		VIRTME_RUN_OPTS+=("${array[@]}")
	fi

	if [ -n "${INPUT_VIRTME_RUN_QEMU_OPTS}" ]; then
		local array=()
		read -r -a array <<<"${INPUT_VIRTME_RUN_QEMU_OPTS}"
		VIRTME_RUN_QEMU_OPTS+=("${array[@]}")
	fi

	mkdir -p "${RESULTS_DIR}"
	OUTPUT_VIRTME="${RESULTS_DIR}/output.log"
	TESTS_SUMMARY="${RESULTS_DIR}/summary.txt"
	CONCLUSION="${RESULTS_DIR}/conclusion.txt"
	KMEMLEAK="${RESULTS_DIR}/kmemleak.txt"
	LCOV_FILE="${RESULTS_DIR}/kernel.lcov"
	LCOV_TXT="${RESULTS_DIR}/coverage.txt"
	LCOV_HTML="${RESULTS_DIR}/lcov"

	KVERSION=$(make -C "${KERNEL_SRC}" -s kernelversion) ## 5.17.0 or 5.17.0-rc8
	KVER_MAJ=${KVERSION%%.*}                             ## 5
	KVER_MIN=${KVERSION#*.}                              ## 17.0*
	KVER_MIC=${KVER_MIN#*.}                              ## 0
	KVER_MIN=${KVER_MIN%%.*}                             ## 17

	# without rc, it means we probably already merged with net-next
	if [[ ! ${KVERSION} =~ rc ]] && [ "${KVER_MIC}" = 0 ]; then
		KVER_MIN=$((KVER_MIN + 1))

		# max .19 because Linus has 20 fingers
		if [ ${KVER_MIN} -gt 19 ]; then
			KVER_MAJ=$((KVER_MAJ + 1))
			KVER_MIN=0
		fi
	fi

	if [ "${KVER_MAJ}" -lt 5 ] ||
		{ [ "${KVER_MAJ}" -eq 5 ] && [ "${KVER_MIN}" -le 10 ]; }; then
		# virtiofs doesn't seem to be supported on old kernels
		VIRTME_RUN_OPTS+=(--force-9p)
	fi

	if [ "${KVER_MAJ}" -gt 6 ] ||
		{ [ "${KVER_MAJ}" -eq 6 ] && [ "${KVER_MIN}" -gt 6 ]; }; then
		# vsock console seems working fine from >6.6
		VSOCK_OK=1
	else
		VSOCK_OK=0
	fi

	log_section_end
}

_check_source_exec_one() {
	local src="${1}"
	local reason="${2}"

	if [ -f "${src}" ]; then
		printinfo "This script file exists and will be used ${reason}: $(basename "${src}")"
		cat -n "${src}"

		if is_ci || [ "${INPUT_NO_BLOCK}" = "1" ]; then
			printinfo "Check source exec: not blocking"
		else
			print "Press Enter to continue (use 'INPUT_NO_BLOCK=1' to avoid this)"
			read -r
		fi
	fi
}

check_source_exec_all() {
	log_section_start "Check extented exec files"

	_check_source_exec_one "${VIRTME_EXEC_PRE}" "before the tests suite"
	_check_source_exec_one "${VIRTME_EXEC_RUN}" "to replace the execution of the whole tests suite"
	_check_source_exec_one "${VIRTME_EXEC_POST}" "after the tests suite"

	log_section_end
}

_make_j() {
	make -j"$(nproc)" -l"$(nproc)" "${@}"
}

_make() {
	_make_j "${MAKE_ARGS[@]}" "${@}"
}

_make_o() {
	_make_j "${MAKE_ARGS_O[@]}" "${@}"
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

# $1: mode ; [rest: extra kconfig]
gen_kconfig() {
	local mode kconfig=() vck rc=0
	mode="${1}"
	shift

	log_section_start "Generate kernel config"

	vck=(--arch "${VIRTME_ARCH}" --defconfig --custom "${SELFTESTS_CONFIG}")

	if is_mode_debug "${mode}"; then
		kconfig+=(
			-e NET_NS_REFCNT_TRACKER    # now in debug.config, for < 6.9 kernels
			-d SLUB_DEBUG_ON            # perf impact is too important
			-d DEBUG_KMEMLEAK_AUTO_SCAN # we will scan at the end
		)

		local debug_config="kernel/configs/debug.config"

		# Introduced in v5.17
		if [ ! -s "${debug_config}" ]; then
			debug_config="${VIRTME_CACHE_DIR}/debug.config"
			curl "https://raw.githubusercontent.com/torvalds/linux/refs/tags/v5.17/${debug_config}" >"${debug_config}"
		fi

		vck+=(--custom "${debug_config}")
	else
		# low-overhead sampling-based memory safety error detector.
		# Only in non-debug: KASAN is more precise
		kconfig+=(-e KFENCE)
	fi

	# stop at the first oops or lockup, no need to continue in a bad state
	kconfig+=(
		-e PANIC_ON_OOPS
		-e SOFTLOCKUP_DETECTOR
		-e HARDLOCKUP_DETECTOR
		-e DETECT_HUNG_TASK
		-e WQ_WATCHDOG
	)

	# Debug info for developers
	kconfig+=(-e DEBUG_INFO -e DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT -e GDB_SCRIPTS)

	# Compressed (old/new option)
	kconfig+=(-e DEBUG_INFO_COMPRESSED -e DEBUG_INFO_COMPRESSED_ZSTD)

	# We need more debug info but it is slow to generate
	if is_mode_btf "${mode}"; then
		vck+=(--custom "${BPFTESTS_CONFIG}")
		kconfig+=(-e DEBUG_INFO_BTF_MODULES -e MODULE_ALLOW_BTF_MISMATCH)
		# Fix ./include/linux/if.h:28:10: fatal error:
		#		sys/socket.h: no such file or directory
		kconfig+=(-d IA32_EMULATION)
	elif is_ci; then
		kconfig+=(-e DEBUG_INFO_REDUCED -e DEBUG_INFO_SPLIT)

		if ! with_clang; then
			# decode_stacktrace.sh script reports '??:?' with DWARF5
			kconfig+=(-e DEBUG_INFO_DWARF4)
		fi
	fi

	# GCov for the CI
	if [ "${INPUT_GCOV}" = 1 ]; then
		kconfig+=(-e GCOV_KERNEL -e GCOV_PROFILE_MPTCP)
	fi

	# Debug tools for developers
	kconfig+=(
		-e DYNAMIC_DEBUG --set-val CONSOLE_LOGLEVEL_DEFAULT 8
		-e FTRACE -e FUNCTION_TRACER -e DYNAMIC_FTRACE
		-e FTRACE_SYSCALLS -e HIST_TRIGGERS
	)

	# Extra sanity checks in networking: for the moment, small checks
	kconfig+=(-e DEBUG_NET)

	# Extra detailed debug info on WARN
	kconfig+=(-e DEBUG_BUGVERBOSE_DETAILED)

	# Extra options needed for MPTCP KUnit tests (+S on <v5.13)
	kconfig+=(
		-m KUNIT -e KUNIT_DEBUGFS -d KUNIT_ALL_TESTS
		-m MPTCP_KUNIT_TEST -m MPTCP_KUNIT_TESTS
	)

	# Options for BPF
	kconfig+=(-e BPF_JIT -e BPF_SYSCALL)

	# For TCP sockmap
	kconfig+=(-e BPF_STREAM_PARSER)

	# There are some MEMCG specific code in MPTCP
	kconfig+=(-e MEMCG)

	# Extra options needed for packetdrill
	# note: we still need SHA1 for fallback tests with v0
	kconfig+=(-e TUN -e CRYPTO_USER_API_HASH -e CRYPTO_SHA1)

	# Useful to reproduce issue
	kconfig+=(-e NET_SCH_TBF -e BRIDGE)

	# Disable retpoline to accelerate tests
	kconfig+=(-d RETPOLINE)

	# Disable components we don't need
	kconfig+=(
		-d PCCARD -d MACINTOSH_DRIVERS -d SOUND -d USB_SUPPORT
		-d NEW_LEDS -d SURFACE_PLATFORMS -d DRM -d FB -d ATA
		-d MISC_FILESYSTEMS -d SCSI -d AGP
	)

	# initramfs is not needed, and there are issues with CoreUtils' 'date'
	kconfig+=(-d BLK_DEV_INITRD)

	# extra config
	if [ -s "${1:-}" ]; then
		local i
		for i in "${@}"; do
			# These options are already set by virtme, to avoid
			# duplicated output in the terminal, e.g. syzbot options
			sed -i 's/console=\S\+ //g;s/earlyprintk=\S\+ //g' "${i}"
			vck+=(--custom "${i}")
		done

		# Disable components present in syzbot and not needed here
		kconfig+=(
			-d WLAN -d WIRELESS -d HAMRADIO -d CAN -d BT -d CAIF -d NFC
			-d MEDIA_SUPPORT -d INFINIBAND -d STAGING -d HID
			-d X86_PLATFORM_DEVICES -d BATMAN_ADV -d OPENVSWITCH -d MPLS
			-d QRTR -d IP_DCCP -d RDS -d DLM -d IP_SCTP
			-d BCACHEFS_FS -d F2FS_FS -d BTRFS_FS -d OCFS2_FS -d XFS_FS
			-d JFS_FS -d ISO9660_FS -d NFS_FS -d NFSD
			-d CEPH_FS -d CIFS -d SMB_SERVER -d AFS_FS -d TTY_PRINTK
		)

		# Disable all net vendors, except Intel, for their e1000 driver
		# shellcheck disable=SC2207 # we do want to split
		kconfig+=($(grep "^config NET_VENDOR_" drivers/net/ethernet/*/Kconfig |
			awk '{ print "-d " $2 }'))
		kconfig+=(-e NET_VENDOR_INTEL)
	else
		kconfig+=("${@}")
	fi

	# KBUILD_OUTPUT is used by virtme
	"${VIRTME_CONFIGKERNEL}" "${vck[@]}" "${MAKE_ARGS_O[@]}" 2>/dev/null || rc=${?}

	./scripts/config --file "${VIRTME_KCONFIG}" "${kconfig[@]}" || rc=${?}

	_make_o olddefconfig || rc=${?}

	if is_ci; then
		# Useful to help reproducing issues later
		zstd -19 -T0 "${VIRTME_KCONFIG}" -o "${RESULTS_DIR}/config.zstd" || rc=${?}
	fi

	log_section_end

	return ${rc}
}

build_kernel() {
	local rc=0
	log_section_start "Build kernel"

	if [ "${INPUT_GCOV}" = 1 ]; then
		KCFLAGS="-fprofile-update=atomic" _make_o || rc=${?}
	else
		_make_o || rc=${?}
	fi

	# virtme will mount a tmpfs there + symlink to .virtme_mods
	mkdir -p /lib/modules

	log_section_end

	return ${rc}
}

build_compile_commands() {
	local rc=0
	log_section_start "Build compile_commands.json"

	_make_o compile_commands.json || rc=${?}

	log_section_end

	return ${rc}
}

install_kernel_headers() {
	local rc=0
	log_section_start "Install kernel headers"

	# for BPFTrace and cie
	cp -r include/ "${VIRTME_BUILD_DIR}"

	_make_o headers_install || rc=${?}

	log_section_end

	return ${rc}

}

build_perf() {
	local rc=0
	if [ "${INPUT_BUILD_SKIP_PERF}" = 1 ]; then
		printinfo "Skip Perf build"
		return 0
	fi

	log_section_start "Build Perf"

	cd tools/perf

	_make O="${VIRTME_PERF_DIR}" DESTDIR=/usr install || rc=${?}

	cd "${KERNEL_SRC}"

	log_section_end

	return ${rc}
}

build_gdb_index() {
	local rc=0
	if readelf -S vmlinux 2>/dev/null | grep -q ".gdb_index"; then
		printinfo "Skip GDB Index build: already there"
		return 0
	fi

	log_section_start "Build GDB Index"

	ln -sf "${VIRTME_CURRENT_BUILD_DIR}/vmlinux" .
	ln -sf "${VIRTME_CURRENT_BUILD_DIR}/scripts/gdb/linux/constants.py" scripts/gdb/linux/

	GDB=gdb-multiarch gdb-add-index vmlinux || rc=${?}

	log_section_end

	return ${rc}
}

build() {
	if [ "${INPUT_BUILD_SKIP}" = 1 ]; then
		printinfo "Skip kernel build"
		return 0
	fi

	ccache_stat
	build_kernel
	if with_clang; then
		build_compile_commands || true # nice to have
	fi
	build_gdb_index
	install_kernel_headers
	build_perf
	ccache_stat
}

build_selftests() {
	local rc=0
	if [ "${INPUT_BUILD_SKIP_SELFTESTS}" = 1 ]; then
		printinfo "Skip selftests build"
		return 0
	fi

	log_section_start "Build the selftests $(basename "${SELFTESTS_DIR}")"

	_make_o KHDR_INCLUDES="-I${VIRTME_HEADERS_DIR}" -C "${SELFTESTS_DIR}" || rc=${?}

	log_section_end

	return ${rc}
}

build_bpftests() {
	local rc=0
	if [ "${INPUT_BUILD_SKIP_BPFTESTS}" = 1 ]; then
		printinfo "Skip bpftests build"
		return 0
	fi

	log_section_start "Build BPFTests"

	_make_o KHDR_INCLUDES="-I${VIRTME_HEADERS_DIR}" -C "${BPFTESTS_DIR}" || rc=${?}

	log_section_end

	return ${rc}
}

build_packetdrill() {
	local old_pwd kversion rc=0
	if [ "${INPUT_BUILD_SKIP_PACKETDRILL}" = 1 ]; then
		printinfo "Skip Packetdrill build"
		return 0
	fi

	log_section_start "Build Packetdrill"

	old_pwd="${PWD}"

	# make sure we have the last stable tests
	cd /opt/packetdrill/
	if [ "${INPUT_PACKETDRILL_NO_SYNC}" = "1" ]; then
		printinfo "Packetdrill: no sync"
	else
		git checkout -f "${PACKETDRILL_GIT_BRANCH}"
		if [ "${INPUT_PACKETDRILL_STABLE}" = "1" ]; then
			git fetch origin
			kversion="mptcp-${KVER_MAJ}.${KVER_MIN}"
			# set the new branch only if it exists. If not, take the dev one
			if git show-ref --quiet "refs/remotes/origin/${kversion}"; then
				git branch -f "${kversion}" "origin/${kversion}"
				git checkout -f "${kversion}"
			elif git show-ref --quiet "refs/remotes/origin/archived/${kversion}"; then
				git branch -f "${kversion}" "origin/archived/${kversion}"
				git checkout -f "${kversion}"
			else
				git reset --hard "origin/${PACKETDRILL_GIT_BRANCH}"
			fi
		else
			git fetch origin "${PACKETDRILL_GIT_BRANCH}"
			git reset --hard FETCH_HEAD
		fi
	fi
	cd gtests/net/packetdrill/
	./configure
	_make || rc=${?}

	if [ "${INPUT_PACKETDRILL_NO_MORE_TOLERANCE}" = "1" ]; then
		printinfo "Packetdrill: not modifying the tolerance"
	else
		cd ../mptcp
		# reduce debug logs: too much
		set_trace_off

		local pf val new_val
		for pf in $(git grep -l "^--tolerance_usecs="); do
			# shellcheck disable=SC2013 # to filter duplicated ones
			for val in $(grep "^--tolerance_usecs=" "${pf}" | cut -d= -f2 | sort -u); do
				if is_mode_debug "${mode}"; then
					# the environment can be very slow
					new_val=$((val * 3))
				else
					# public CI can be quite loaded...
					new_val=$((val * 2))
				fi

				sed -i "s/^--tolerance_usecs=${val}$/--tolerance_usecs=${new_val}/g" "${pf}"
			done
		done

		set_trace_on
	fi
	cd "${old_pwd}"

	log_section_end

	return ${rc}
}

build_packetdrill_if_needed() {
	# Try to build it only if it is really needed
	if [ "${INPUT_PACKETDRILL_STABLE}" = "1" ] ||
		[ "${INPUT_PACKETDRILL_NO_SYNC}" = 1 ] ||
		! [ -f "${VIRTME_EXEC_RUN}" ] ||
		sed "s/#.*//g;/^\s*$/d" "${VIRTME_EXEC_RUN}" 2>/dev/null |
		grep -q -e "packetdrill" -e "run_all"; then
		build_packetdrill
	fi
}

build_tests() {
	local mode
	mode="${1}"

	build_selftests
	if is_mode_btf "${mode}"; then
		build_bpftests
	fi
	build_packetdrill
}

prepare() {
	printinfo "Prepare the environment"

	cat <<EOF >"${BASH_PROFILE}"
export KERNEL_BUILD_DIR="${VIRTME_BUILD_DIR}"
export KERNEL_SRC_DIR="${KERNEL_SRC}"
export PATH="\${PATH}:${VIRTME_TOOLS_SBIN_DIR}"
EOF

	# add colours to the prompt if OK
	if [ "${INPUT_SELFTESTS_MPTCP_LIB_COLOR_FORCE}" = 1 ]; then
		# shellcheck disable=SC2016 # escaped on purpose
		local ps1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
		echo "PS1='${ps1}'" >>"${BASH_PROFILE}"
	fi

	if [ -f "${VIRTME_PREPARE_POST}" ]; then
		# shellcheck source=/dev/null
		source "${VIRTME_PREPARE_POST}"
	fi
}

run() {
	printinfo "Run the virtme script: manual"

	"${VIRTME_RUN}" "${VIRTME_RUN_OPTS[@]}" ${VIRTME_RUN_QEMU_OPTS:+--qemu-opts "${VIRTME_RUN_QEMU_OPTS[@]}"}
}

run_expect() {
	local mode timestamps_sec_stop no_tap=1
	mode="${1}"

	if is_ci; then
		no_tap=0 # we want subtests
		timestamps_sec_stop=$(date +%s)

		# max - compilation time - before/after script
		VIRTME_EXPECT_TEST_TIMEOUT=$((INPUT_CI_TIMEOUT_SEC - (timestamps_sec_stop - TIMESTAMPS_SEC_START) - VIRTME_CI_ESTIMATED_EXTRA_TIME))
	else
		# disable timeout
		VIRTME_EXPECT_TEST_TIMEOUT="${INPUT_EXPECT_TIMEOUT}"
	fi

	# force a stop in case of panic, but avoid a reboot in "expect" mode
	VIRTME_RUN_OPTS+=(--kopt panic=-1 --kopt oops=panic)
	VIRTME_RUN_QEMU_OPTS+=(-no-reboot)

	printinfo "Run the virtme script: expect (timeout: ${VIRTME_EXPECT_TEST_TIMEOUT})"

	cat <<EOF >"${VIRTME_SCRIPT}"
#! /bin/bash

if [ "${INPUT_TRACE}" = "1" ]; then
	set -x
fi

# useful for virtme-exec-run
TAP_PREFIX="${KERNEL_SRC}/tools/testing/selftests/kselftest/prefix.pl"
RESULTS_DIR="${RESULTS_DIR}"
OUTPUT_VIRTME="${OUTPUT_VIRTME}"
KUNIT_CORE_LOADED=0
MAX_THREADS=${INPUT_MAX_THREADS:-$((INPUT_CPUS * 2))}
export SELFTESTS_MPTCP_LIB_EXPECT_ALL_FEATURES="${INPUT_SELFTESTS_MPTCP_LIB_EXPECT_ALL_FEATURES}"
export SELFTESTS_MPTCP_LIB_OVERRIDE_FLAKY="${INPUT_SELFTESTS_MPTCP_LIB_OVERRIDE_FLAKY}"
export SELFTESTS_MPTCP_LIB_COLOR_FORCE="${INPUT_SELFTESTS_MPTCP_LIB_COLOR_FORCE}"
export SELFTESTS_MPTCP_LIB_NO_TAP="${no_tap}"

set_max_threads() {
	# if QEmu without KVM support or debug mode
	if [[ "${mode}" == *"debug" ]] ||
	   { [ "\$(cat /sys/devices/virtual/dmi/id/sys_vendor)" = "QEMU" ] &&
	     [ "\$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)" != "kvm-clock" ]; }; then
		MAX_THREADS=$((MAX_THREADS / 2)) # avoid too many concurrent work
	fi
}

if [ "${GITHUB_ACTIONS}" = "true" ]; then
	# \$1: description
	log_section_start() {
		echo -e "\n::group::${COLOR_YELLOW}\${*}${COLOR_RESET}"
	}

	log_section_end() {
		echo -e "::endgroup::\n"
	}
else
	# \$1: description
	log_section_start() {
		echo -e "${COLOR_BLUE}\${*}${COLOR_RESET}"
	}

	log_section_end() {
		true
	}
fi

# \$1: name of the test
_can_run() { local tname
	tname="\${1}"

	# only some tests?
	if [ -n "${INPUT_RUN_TESTS_ONLY}" ]; then
		if ! echo "${INPUT_RUN_TESTS_ONLY}" | grep -wq "\${tname}"; then
			return 1
		fi
	fi

	# not some tests?
	if [ -n "${INPUT_RUN_TESTS_EXCEPT}" ]; then
		if echo "${INPUT_RUN_TESTS_EXCEPT}" | grep -wq "\${tname}"; then
			return 1
		fi
	fi

	return 0
}

can_run() {
	# Use the function name of the caller without the prefix
	_can_run "\${FUNCNAME[1]#*_}"
}

# \$1: file ; \$2+: commands
_tap() { local out out_subtests tmp fname rc ok nok msg cmt ts_s_start ts_s_stop
	out="\${1}.tap"
	out_subtests="\${1}_subtests.tap"
	fname="\$(basename \${1})"
	shift

	rm -f "\${out}" "\${out_subtests}"
	# With TAP, we have first the summary, then the diagnostic
	tmp="\${out}.tmp"
	ok="ok 1 test: \${fname}"
	nok="not \${ok}"
	ts_s_start=\$(date +%s)

	# init
	{
		echo "TAP version 13"
		echo "1..1"
	} | tee "\${out}"

	# Exec the command and pipe in tap prefix + store for later
	"\${@}" 2>&1 | "\${TAP_PREFIX}" | tee "\${tmp}"
	# output to stdout now to see the progression
	rc=\${PIPESTATUS[0]}
	ts_s_stop=\$(date +%s)

	# summary
	case \${rc} in
		0)
			msg="\${ok}"
			;;
		1)
			msg="\${nok}"
			cmt=FAIL
			;;
		2)
			msg="\${nok}"
			cmt=XFAIL
			;;
		3)
			msg="\${nok}"
			cmt=XPASS
			;;
		4)
			cmt=SKIP
			if [ "\${SELFTESTS_MPTCP_LIB_EXPECT_ALL_FEATURES}" = "1" ]; then
				msg="\${nok}"
			else
				msg="\${ok}"
			fi
			;;
		*)
			msg="\${nok}"
			cmt="FAIL # exit=\${rc}"
			;;
	esac
	# note: '#' is a directive, not a comment: we imitate kselftest/runner.sh
	echo "\${msg}\${cmt+ # }\${cmt}" | tee -a "\${out}"

	# diagnostic at the end with TAP
	# Strip colours: https://stackoverflow.com/a/18000433
	# Also extract subtests displayed at the end, if any, in a different file without "#"
	sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,2};?)?)?[mGK]//g" "\${tmp}" | \
		awk "BEGIN { subtests=0 } {
			if (subtests == 0 && \\\$0 ~ /^# TAP version /) { subtests=1 };
			if (subtests == 0) { print >> \"\${out}\" }
			else { for (i=2; i <= NF; i++) printf(\"%s\", ((i>2) ? OFS : \"\") \\\$i) >> \"\${out_subtests}\" ; printf(\"\n\") >> \"\${out_subtests}\" }
		}"
	rm -f "\${tmp}"

	echo "# time=\$((ts_s_stop - ts_s_start))" | tee -a "\${out}"

	return \${rc}
}

# \$1: kunit path ; \$2: kunit test
_kunit_result() {
	if ! grep -q "^KTAP" "\${1}" 2>/dev/null; then
		echo "TAP version 14"
		echo "1..1"
	fi

	if ! cat "\${1}"; then
		echo "not ok 1 test: \${2/*//} # no kunit result"
		return 1
	fi
}

run_kunit_core() {
	[ "\${KUNIT_CORE_LOADED}" = 1 ] && return 0
	KUNIT_CORE_LOADED=1

	_tap "${RESULTS_DIR}/kunit" insmod ${VIRTME_BUILD_DIR}/lib/kunit/kunit.ko
}

# \$1: .ko path
run_kunit_one() { local ko kunit kunit_path rc=0
	ko="\${1}"

	kunit="\${ko#${VIRTME_BUILD_DIR}/}" # remove abs dir
	kunit="\${kunit:10:-8}" # remove net/mptcp (10) + _test.ko (8)
	kunit="\${kunit//_/-}" # dash
	kunit_path="/sys/kernel/debug/kunit/\${kunit}/results"

	log_section_start "KUnit Test: \${kunit}"

	run_kunit_core || return \${?}

	insmod "\${ko}" || true # errors will also be visible below: no results
	_kunit_result "\${kunit_path}" "\${kunit}" | tee "${RESULTS_DIR}/kunit_\${kunit}.tap" || rc=\${?}

	log_section_end

	return \${rc}
}

run_kunit_all() { local ko rc=0
	can_run || return 0

	cd "${KERNEL_SRC}"

	for ko in ${VIRTME_BUILD_DIR}/net/mptcp/*_test.ko; do
		run_kunit_one "\${ko}" || rc=\${?}
	done

	return \${rc}
}

# \$1: output tap file; rest: command to launch
_run_selftest_one_tap() {
	cd "${KERNEL_SRC}/${SELFTESTS_DIR}"
	_tap "\${@}"
}

# \$1: script file; rest: command to launch
run_selftest_one() { local sf tap rc=0
	sf=\$(basename \${1})
	tap=selftest_\${sf:0:-3}
	shift

	_can_run "\${tap}" || return 0

	log_section_start "Selftest Test: ./\${sf}\${1:+ \${*}}"
	_run_selftest_one_tap "${RESULTS_DIR}/\${tap}" "./\${sf}" "\${@}" || rc=\${?}
	log_section_end

	return \${rc}
}

run_selftest_all() { local sf rc=0
	# The following command re-do a slow headers install + compilation in a different dir
	#make O="${VIRTME_BUILD_DIR}" --silent -C tools/testing/selftests TARGETS=net/mptcp run_tests

	for sf in "${KERNEL_SRC}/${SELFTESTS_DIR}/"*.sh; do
		if [ -x "\${sf}" ]; then
			run_selftest_one "\${sf}" || rc=\${?}
		elif [[ "\${sf}" == "${KERNEL_SRC}/${SELFTESTS_DIR}/mptcp_connect_"*".sh" ]]; then
			# workaround for stable kernels
			chmod +x "\${sf}"
			run_selftest_one "\${sf}" || rc=\${?}
			chmod -x "\${sf}"
		fi
	done

	return \${rc}
}

# \$1: packetdrill TAP file, \$2: TAP prefix
_packetdrill_result() {
	if grep -q "^TAP version 13" "\${1}" 2>/dev/null; then
		sed -i "s#\${PWD}/#packetdrill: #g" "\${1}" # remove long path + prefix
		return 0
	fi

	{
		echo "TAP version 13"
		echo "1..1"
		echo "not ok 1 test: \${2} # no result"
	} > "\${1}"

	return 1
}

# \$1: pktd_dir (e.g. mptcp/dss)
run_packetdrill_one() { local pktd_dir pktd tap rc=0
	pktd_dir="\${1}"
	pktd="\$(basename "\${pktd_dir}" ".pkt")" # remove ext just in case
	tap="packetdrill_\${pktd}"

	if [ "\${pktd}" = "common" ]; then
		return 0
	fi

	_can_run "\${tap}" || return 0

	log_section_start "Packetdrill Test: \${pktd}"
	cd /opt/packetdrill/gtests/net/
	PYTHONUNBUFFERED=1 ./packetdrill/run_all.py -t "${RESULTS_DIR}" \
		-l -v -P \${MAX_THREADS} \${pktd_dir} || rc=\${?}
	_packetdrill_result "${RESULTS_DIR}/\${tap}.tap" "\${tap}" || rc=\${?}
	log_section_end

	return \${rc}
}

run_packetdrill_all() { local pktd_dir rc=0
	cd /opt/packetdrill/gtests/net/

	# dry run just to "heat" up the environment: the first tests are always
	# slower, especially with a debug kernel
	./packetdrill/run_all.py mptcp/add_addr/add_addr4_server.pkt &>/dev/null || true

	for pktd_dir in mptcp/*; do
		run_packetdrill_one "\${pktd_dir}" || rc=\${?}
	done

	return \${rc}
}

# \$1: output tap file; rest: command to launch
_run_bpftest_one_tap() {
	cd "${VIRTME_BUILD_DIR}"
	_tap "\${@}"
}

# \$1: script file; rest: command to launch
run_bpftest_one() { local bf bt tap rc=0
	bf=\$(basename \${1})
	bt=\${2}
	tap=bpftest_\${bf}_\${bt}

	log_section_start "BPF Test: \${bf} -t \${bt}"
	_run_bpftest_one_tap "${RESULTS_DIR}/\${tap}" "./\${bf}" -t "\${bt}" || rc=\${?}
	log_section_end

	return \${rc}
}

run_bpftest_all() {
	can_run || return 0

	if [[ "${mode}" == "btf-"* ]]; then
		local sf rc=0

		for sf in "${VIRTME_BUILD_DIR}/"test_progs*; do
			if [ -x "\${sf}" ]; then
				run_bpftest_one "\${sf}" "\${1:-mptcp}" || rc=\${?}
			fi
		done

		return \${rc}
	else
		echo "Skip BPF tests: only supported in the 'btf' mode"
	fi
}

run_all() {
	run_kunit_all
	run_selftest_all
	run_packetdrill_all
	run_bpftest_all
}

has_call_trace() {
	grep -q "[C]all Trace:" "${OUTPUT_VIRTME}"
}

kmemleak_scan() { local p="/sys/kernel/debug/kmemleak"
	if [ -e "\${p}" ]; then
		echo scan > "\${p}"
		sleep 5 # grace period of 5 sec
		# second scan often surfaces issues the first scan missed
		echo scan > "\${p}"
		cat "\${p}" >> "${KMEMLEAK}"
	fi
}

gcov_extract() {
	if [ -d /sys/kernel/debug/gcov ]; then
		log_section_start "GCOV capture"
		timeout 2m lcov --capture --keep-going -j "${INPUT_CPUS}" \
				--rc geninfo_unexecuted_blocks=1 \
				--include '/net/mptcp/' \
				--function-coverage --branch-coverage \
				-b "${VIRTME_BUILD_DIR}" -o "${LCOV_FILE}"
		log_section_end
	fi
}

# \$1: max iterations (<1 means no limit) ; args: what needs to be executed
run_loop_n() { local i tdir rc=0
	n=\${1}
	shift

	tdir="${KERNEL_SRC}/${SELFTESTS_DIR}"
	if ls "\${tdir}/"*.pcap &>/dev/null; then
		mkdir -p "\${tdir}/pcaps"
		mv "\${tdir}/"*.pcap "\${tdir}/pcaps"
	fi

	i=1
	while true; do
		echo -e "\n\n\t=== ${COLOR_BLUE}Attempt: \${i} (\$(date -R))${COLOR_RESET} ===\n\n"

		if ! "\${@}" || has_call_trace; then
			rc=1

			echo -e "\n\n\t=== ${COLOR_RED}ERROR after \${i} attempts (\$(date -R))${COLOR_RESET} ===\n\n"

			if [ "${INPUT_RUN_LOOP_CONTINUE}" = "1" ]; then
				echo "Attempt: \${i}" >> "${CONCLUSION}.failed"
			else
				break
			fi
		fi

		rm -f "\${tdir}/"*.pcap 2>/dev/null

		if [ "\${i}" = "\${n}" ]; then
			break
		fi

		i=\$((i+1))
	done

	echo -e "\n\n\t${COLOR_BLUE}Stopped after \${i} attempts${COLOR_RESET}\n\n"

	return "\${rc}"
}

# args: what needs to be executed
run_loop() {
	run_loop_n 0 "\${@}"
}

# args: what needs to be executed
run_cmd() {
	_tap "${RESULTS_DIR}/cmd_\$(basename "\${1}")_\$(mktemp -u XXXXXX)" "\${@}"
}

set_max_threads

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
	echo -e "\n\n\t${COLOR_YELLOW}Not running all tests but:${COLOR_RESET}\n\n-------- 8< --------\n\$(sed "s/#.*//g;/^\s*$/d" "${VIRTME_EXEC_RUN}")\n-------- 8< --------\n\n"
	source "${VIRTME_EXEC_RUN}"
	# e.g.:
	# run_selftest_one ./mptcp_join.sh -f
	# run_loop run_selftest_one ./simult_flows.sh
	# run_packetdrill_one mptcp/dss
else
	run_all
fi

cd "${KERNEL_SRC}"

rm -f "${KMEMLEAK}"
kmemleak_scan
gcov_extract

# To run commands after having executed the tests
if [ -f "${VIRTME_EXEC_POST}" ]; then
	source "${VIRTME_EXEC_POST}"
	# e.g.: cat /sys/kernel/tracing/trace
fi

# end
echo "${VIRTME_SCRIPT_END}"
/usr/lib/klibc/bin/poweroff
EOF
	chmod +x "${VIRTME_SCRIPT}"

	cat <<EOF >"${VIRTME_SCRIPT_TIMEOUT}"
#! /bin/bash
sysrq() {
	echo -e "\nsysrq: \${1}\n"
	echo "\${1}" > /proc/sysrq-trigger
	sleep 1
}
sysrq 'w'
sysrq 'd'
sysrq 'l'
sysrq 't'
echo "${VIRTME_SCRIPT_TIMEOUT_END}"
EOF
	chmod +x "${VIRTME_SCRIPT_TIMEOUT}"

	cat <<EOF >"${VIRTME_SCRIPT_TIMEOUT_GDB}"
set output-radix 16
target remote localhost:1234
l
bt full
info frame
info registers
thread apply all bt full
detach
exit
EOF

	cat <<EOF >"${VIRTME_RUN_SCRIPT}"
#! /bin/bash
echo -e "$(log_section_start "Boot VM (\$1)")"
set -x
"${VIRTME_RUN}" ${VIRTME_RUN_OPTS[@]} ${VIRTME_RUN_QEMU_OPTS:+--qemu-opts ${VIRTME_RUN_QEMU_OPTS[@]}} 2>&1 | tr -d '\r'
EOF
	chmod +x "${VIRTME_RUN_SCRIPT}"

	cat <<EOF >"${VIRTME_RUN_EXPECT}"
#!/usr/bin/expect -f

set unexp_stop 0
set serial_id 0

set max_boot 5
for {set boot 0} {\$boot < \$max_boot} {incr boot 1} {
	if {\$boot > 0} {
		send_user "\n$(log_section_end)"
		if {\$unexp_stop == 0} {
			set timeout "60"
			send_user "$(log_section_start_no_color "Timeout: Getting more info via GDB")\n"
			spawn gdb-multiarch --batch -x "${VIRTME_SCRIPT_TIMEOUT_GDB}" vmlinux
			expect {
				"detached" {
					send_user "Timeout: Getting more info via GDB: end\n"
				} timeout {
					send_user "Timeout: Getting more info via GDB: timeout\n"
					send "\x03\r"
				} eof {
					send_user "Timeout: Getting more info via GDB: unexpected end\n"
				}
			}
			send_user "\n$(log_section_end)"
			close
			wait

			set spawn_id \$serial_id
			close
			wait
		}

		# not to prevent restart after a kill
		exec rm -f "/tmp/virtme-console/${INPUT_VSOCK_CID}.sh"
	}

	set timeout "${VIRTME_EXPECT_BOOT_TIMEOUT}"
	spawn "${VIRTME_RUN_SCRIPT}" \$boot
	set serial_id \$spawn_id
	set unexp_stop 0

	expect {
		"virtme-ng-init: " {
			send_user "Waiting for the virtme-ng-init to finish\n"
		} timeout {
			send_user "Timeout boot: stopping\n"
			continue
		} eof {
			send_user "Unexpected stop ttyS0\n"
			set unexp_stop 1
			continue
		}
	}

	set timeout "60"
	expect {
		"virtme-ng-init: initialization done\r" {
			send_user "Waiting for the console to be ready\n"
			send "\r"
		} timeout {
			send_user "Timeout virtme-ng-init: stopping\n"
			continue
		} eof {
			send_user "Unexpected stop init\n"
			set unexp_stop 1
			continue
		}
	}

	set timeout "1"

	set max_csl 60
	for {set csl 0} {\$csl < \$max_csl} {incr csl 1} {
		expect {
			"root@${INPUT_HOSTNAME}" {
				break
			} timeout {
				sleep 1
				send "\r"
			} eof {
				send_user "Unexpected stop console\n"
				set unexp_stop 1
				continue
			}
		}
	}

	if {\$csl >= \$max_csl} {
		send_user "Timeout console: stopping (\$csl)\n"
		continue
	}

	break
}

if {\$boot >= \$max_boot} {
	send_user "\n$(log_section_end)"
	if {\$unexp_stop == 1} {
		send_user "${VIRTME_SCRIPT_UNEXPECTED_STOP} (\$boot)\n"
	} else {
		send_user "Timeout boot (\$boot)\n"
	}
	exit 1
}

# on "recent" kernels, we can use VSOCK instead of the serial
# on older ones, it works, but we get "cat: write error: Broken pipe" errors
if {${VSOCK_OK} == 1} {
	# workaround to continue to get "live" serial output
	expect_background eof

	set timeout "5"
	spawn "${VIRTME_RUN}" --mods none --client --port "${INPUT_VSOCK_CID}"
	set console_id \$spawn_id
	send_user "\n$(log_section_end)"

	expect {
		"root@${INPUT_HOSTNAME}" {
			send_user "VSOCK console is ready\n"
		} timeout {
			send_user "Timeout VSOCK console: stopping\n"
			send -i \$serial_id -- "/usr/lib/klibc/bin/poweroff\r"
			exit 1
		} eof {
			send_user "${VIRTME_SCRIPT_UNEXPECTED_STOP} (VSOCK console)\n"
			send -i \$serial_id -- "/usr/lib/klibc/bin/poweroff\r"
			exit 1
		}
	}
} else {
	send_user "\n$(log_section_end)"
	send_user "VSOCK console is not usable in this kernel version\n"
	# echo the script name, used in the analysis: commands are not echoed here
	send_user "Going to start ${VIRTME_SCRIPT}\n"
	# workaround to avoid more 'if' statements below
	set console_id \$spawn_id
}

send_user "Starting the validation script (after \$csl sec, attempt: \$boot)\n"
set timeout "${VIRTME_EXPECT_TEST_TIMEOUT}"
send -- "stdbuf -oL ${VIRTME_SCRIPT}\r"

expect {
	"${VIRTME_SCRIPT_END}\r" {
		send_user "validation script ended with success\n"
	} timeout {
		send_user "\n$(log_section_end)"
		send_user "$(log_section_start_no_color "Timeout: Getting more info via SysRq")\n"
		# stop consuming serial's stdout
		expect_background -i \$serial_id
		send -i \$serial_id -- "${VIRTME_SCRIPT_TIMEOUT}\r"
		set timeout "60"
		expect {
			-i \$serial_id "${VIRTME_SCRIPT_TIMEOUT_END}" {
				send_user "Timeout: Getting more info: end\n"
			} timeout {
				send_user "Timeout: Getting more info: timeout\n"
				send -i \$serial_id "\x03\r"
			} eof {
				send_user "Timeout: Getting more info: unexpected end\n"
			}
		}
		send_user "\n$(log_section_end)"

		send_user "$(log_section_start_no_color "Timeout: Getting more info via GDB")\n"
		spawn gdb-multiarch --batch -x "${VIRTME_SCRIPT_TIMEOUT_GDB}" vmlinux
		expect {
			"detached" {
				send_user "Timeout: Getting more info via GDB: end\n"
			} timeout {
				send_user "Timeout: Getting more info via GDB: timeout\n"
				send "\x03\r"
			} eof {
				send_user "Timeout: Getting more info via GDB: unexpected end\n"
			}
		}
		send_user "\n$(log_section_end)"
		close
		wait
		send_user "${VIRTME_SCRIPT_TIMEOUT_GDB_END}"

		set spawn_id \$console_id
		send_user "Timeout: sending Ctrl+C\n"
		send "\x03\r"
		sleep 2
		send "\x03\r"
	} eof {
		send_user "${VIRTME_SCRIPT_UNEXPECTED_STOP}\n"
		exit 1
	}
}

if {${VSOCK_OK} == 1} {
	# get end messages
	expect_background eof
	# stop vsock
	close

	# back to the serial, stop consuming stdout
	set spawn_id \$serial_id
	expect_background
}

set timeout "${VIRTME_EXPECT_SHUTDOWN_TIMEOUT}"

expect {
	"KVM: entry failed, hardware error" {
		exit 1
	} timeout {
		exit 1
	} eof {
		exit 0
	}
}
EOF
	chmod +x "${VIRTME_RUN_EXPECT}"

	# We could use "--script-sh", but we use expect to catch timeout, etc.
	"${VIRTME_RUN_EXPECT}" | tee "${OUTPUT_VIRTME}"
}

ccache_stat() {
	if is_ci; then
		log_section_start "CCache Stats"
		ccache -s
		log_section_end
	fi
}

_had_issues() {
	[ ${#EXIT_REASONS[@]} -gt 0 ]
}

_had_critical_issues() {
	[ ${#CRITICAL_ERRORS[@]} -gt 0 ]
}

_had_other_issues() {
	[ ${#OTHER_ERRORS[@]} -gt 0 ]
}

# $1: category ; $2: reason
_register_issue() {
	local msg
	msg="${1}: ${2}"

	if [ "${1}" = "Critical" ]; then
		if _had_critical_issues; then
			CRITICAL_ERRORS+=("-" "${2}")
		else
			CRITICAL_ERRORS=("${2}")
		fi
	elif [ "${1}" != "Unstable" ]; then
		if _had_other_issues; then
			OTHER_ERRORS+=("-" "${2}")
		else
			OTHER_ERRORS=("${2}")
		fi
	fi

	if _had_issues; then
		EXIT_REASONS+=("-" "${msg}")
	else
		EXIT_REASONS=("${msg}")
	fi
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

# $1: A: after, B: before
_get_output_around_start() {
	grep -a"${1}" 9999999 "${VIRTME_SCRIPT}" "${OUTPUT_VIRTME}"
}

_get_output_after_start() {
	_get_output_around_start A
}

_get_output_before_start() {
	if grep -q "${VIRTME_SCRIPT}" "${OUTPUT_VIRTME}"; then
		_get_output_around_start B
	else
		cat "${OUTPUT_VIRTME}"
	fi
}

_get_output_around_stop() {
	local arg="${1}"
	shift

	# either the script was able to finish, or the timeout/stop message
	grep -a"${arg}" 9999999 -e "${VIRTME_SCRIPT_END}" \
		-e "${VIRTME_SCRIPT_TIMEOUT_GDB_END}" \
		-e "${VIRTME_SCRIPT_UNEXPECTED_STOP}" "${@}"
}

_get_output_after_stop() {
	_get_output_around_stop A "${OUTPUT_VIRTME}"
}

_get_output_before_stop() {
	_get_output_around_stop B
}

_call_trace() {
	grep -q "Call Trace:"
}

_has_call_trace() {
	_get_output_after_start | _get_output_before_stop | _call_trace
}

_has_call_trace_at_boot() {
	_get_output_before_start | _call_trace
}

_has_call_trace_at_shutdown() {
	_get_output_after_stop | _call_trace
}

_print_line() {
	echo "=========================================="
}

_get_ref() {
	echo "${GITHUB_REF_NAME:-$(git describe --tags 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "Unknown")}"
}

decode_stacktrace() {
	./scripts/decode_stacktrace.sh "${VIRTME_BUILD_DIR}/vmlinux" "${KERNEL_SRC}" "${VIRTME_BUILD_DIR}/.virtme_mods"
}

_print_call_trace_info() {
	echo
	_print_line
	echo "Call Trace:"
	_print_line
	grep --text -C 80 "Call Trace:" "${OUTPUT_VIRTME}" | decode_stacktrace
	_print_line
	echo "Call Trace found"
}

_get_call_trace_status() {
	echo "$(grep -c "Call Trace:" "${OUTPUT_VIRTME}") Call Trace(s)"
}

_has_unexpected_stop() {
	grep -q "${VIRTME_SCRIPT_UNEXPECTED_STOP}" "${OUTPUT_VIRTME}"
}

_print_unexpected_stop() {
	echo
	_print_line
	echo "${VIRTME_SCRIPT_UNEXPECTED_STOP}: see above"
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

_has_kmemleak() {
	[ -s "${KMEMLEAK}" ]
}

_print_kmemleak() {
	echo
	_print_line
	echo "KMemLeak:"
	_print_line
	decode_stacktrace <"${KMEMLEAK}"
	_print_line
	echo "KMemLeak detected"
}

_has_boot_failure() {
	grep -q "Boot VM (1)" "${OUTPUT_VIRTME}"
}

_print_boot_failure() {
	echo "Had $(grep -c "Boot VM " "${OUTPUT_VIRTME}") boot attempts"
}

# $1: mode, rest: args for kconfig
_print_summary_header() {
	local mode="${1}"
	shift

	echo "== Summary =="
	echo
	echo "Ref: $(_get_ref)${GITHUB_SHA:+ (${GITHUB_SHA})}"
	echo "Mode: ${mode}"
	echo "Extra kconfig: ${*:-/}"
	echo
}

# [ $1: .tap file, summary file by default]
_has_failed_tests() {
	grep -q "^not ok " "${1:-${TESTS_SUMMARY}}"
}

# $1: prefix
_print_tests_results_subtests() {
	local tap ok
	for tap in "${RESULTS_DIR}/${1}"*.tap; do
		[[ ${tap} == *"_*.tap" ]] && continue
		grep -q "^not ok " "${tap}" && ok="not ok" || ok="ok"
		echo "${ok} 1 test: $(basename "${tap}" ".tap")"
	done
}

_print_tests_result() {
	local flaky
	echo "All tests:"
	# only from the main tests
	grep --text --no-filename -E "^(not )?ok 1 test: " "${RESULTS_DIR}"/*.tap || true
	_print_tests_results_subtests "kunit_"
	_print_tests_results_subtests "packetdrill_"

	if is_ci; then
		flaky="$(grep --text --no-filename -F " # IGNORE Flaky" "${RESULTS_DIR}"/*_subtests.tap || true)"
	else
		flaky="$(grep --text --no-filename -F "[IGNO] (flaky)" "${RESULTS_DIR}"/*.tap || true)"
	fi
	if [ -n "${flaky}" ]; then
		echo
		echo "Flaky tests:"
		echo "${flaky}"
	fi
}

_print_failed_tests() {
	local t
	echo
	_print_line
	echo "Failed tests:"
	for t in "${RESULTS_DIR}"/*.tap; do
		if _has_failed_tests "${t}"; then
			_print_line
			echo "- $(basename "${t}"):"
			echo
			grep -av "^ok [0-9]\+ " "${t}"
		fi
	done
	_print_line
}

_get_failed_tests() {
	# not ok 1 test: selftest_mptcp_join.tap # exit=1
	# we just want the main results, not the detailed ones for the moment
	grep --text "^not ok 1 test: " "${TESTS_SUMMARY}" |
		awk '{ print $5 }' |
		sort -u |
		sed "s/\.tap$//g"
}

_get_failed_tests_status() {
	local t fails=()
	for t in $(_get_failed_tests); do
		fails+=("${t}")
	done

	echo "${#fails[@]} failed test(s): ${fails[*]}"
}

_gen_results_files() {
	LANG=C tap2junit "${RESULTS_DIR}"/*.tap

	# remove prefix id (unique test) and comments (status, time)
	sed -i 's/\(<testcase name="\)[0-9]\+[ -]*/\1/g;/<testcase name=/s/\s\+#.*">/">/g' "${RESULTS_DIR}"/*.tap.xml

	LANG=C /tap2json.py \
		--output "${RESULTS_DIR}/results.json" \
		--info "run_id:${GITHUB_RUN_ID:-"none"}" \
		--error "${CRITICAL_ERRORS[*]}" \
		--warn "${OTHER_ERRORS[*]}" \
		--only-fails \
		"${RESULTS_DIR}"/*.tap
}

# $1: mode, rest: args for kconfig
analyze() {
	# reduce log that could be wrongly interpreted
	set_trace_off

	local mode="${1}"
	shift

	local has_call_trace=0

	printinfo "Analyze results"

	echo -ne "\n${COLOR_GREEN}"
	_print_summary_header "${mode}" "${@}" | tee "${TESTS_SUMMARY}"
	_print_tests_result | tee -a "${TESTS_SUMMARY}"

	echo -ne "${COLOR_RESET}\n${COLOR_RED}"

	if _has_failed_tests; then
		# no tee, it can be long and less important than critical err
		_print_failed_tests >>"${TESTS_SUMMARY}"
		_register_issue "Unstable" "$(_get_failed_tests_status)"
		EXIT_STATUS=42
	fi

	# look for crashes/warnings
	if _has_call_trace; then
		has_call_trace=1
		_print_call_trace_info | tee -a "${TESTS_SUMMARY}"
		_register_issue "Critical" "$(_get_call_trace_status)"
		EXIT_STATUS=1

		if is_ci; then
			zstd -19 -T0 "${VIRTME_BUILD_DIR}/vmlinux" \
				-o "${RESULTS_DIR}/vmlinux.zstd"
		fi
	fi

	if _has_unexpected_stop; then
		_print_unexpected_stop | tee -a "${TESTS_SUMMARY}"
		_register_issue "Critical" "${VIRTME_SCRIPT_UNEXPECTED_STOP}"
		EXIT_STATUS=1
	elif _has_timed_out; then
		_print_timed_out | tee -a "${TESTS_SUMMARY}"
		_register_issue "Critical" "Global Timeout"
		EXIT_STATUS=1
	fi

	if _has_kmemleak; then
		_print_kmemleak | tee -a "${TESTS_SUMMARY}"
		_register_issue "Critical" "KMemLeak"
		EXIT_STATUS=1
	fi

	if _has_call_trace_at_boot; then
		# not to print errors twice
		if [ "${has_call_trace}" = 0 ]; then
			_print_call_trace_info | tee -a "${TESTS_SUMMARY}"
			has_call_trace=1
		fi
		_register_issue "Notice" "Call Traces at boot time, rebooted and continued"
		EXIT_STATUS=2
	elif _has_boot_failure; then
		_print_boot_failure | tee -a "${TESTS_SUMMARY}"
		_register_issue "Notice" "Boot failures, rebooted and continued"
		EXIT_STATUS=2
	fi

	if _has_call_trace_at_shutdown; then
		# not to print errors twice
		if [ "${has_call_trace}" = 0 ]; then
			_print_call_trace_info | tee -a "${TESTS_SUMMARY}"
			has_call_trace=1
		fi
		_register_issue "Notice" "Call Traces at shutdown time, ignored and continued"
		EXIT_STATUS=2
	fi

	if [ -s "${LCOV_FILE}" ]; then
		lcov --branch-coverage --function-coverage --keep-going \
			--summary "${LCOV_FILE}" | tee "${LCOV_TXT}" || true
	fi

	echo -ne "${COLOR_RESET}"

	if is_ci; then
		_gen_results_files || true
	fi

	if [ "${EXIT_STATUS}" = "1" ]; then
		echo
		printerr "Critical issue(s) detected, exiting"
		exit 1
	fi

	set_trace_on
}

# $1: type ; $2: mode ; [ $@:3: args for kconfig ]
prepare_all() {
	local t mode
	t=${1}
	shift
	mode="${1}"

	printinfo "Start: ${t} (${mode})"

	if [ "${t}" = "auto" ]; then
		EXPECT=1
	fi

	setup_env "${mode}"
	gen_kconfig "${@}"
	build
	build_tests "${mode}"
	prepare
}

# $1: mode ; [ $2+: kconfig ]
go_manual() {
	prepare_all manual "${@}"
	run
}

# $1: mode ; [ $2+: kconfig ]
go_expect() {
	check_source_exec_all

	prepare_all auto "${@}"
	run_expect "${@}"
	analyze "${@}"
}

go_vm_manual() {
	setup_env "${@:-normal}"
	build_packetdrill_if_needed
	prepare
	run
}

go_vm_expect() {
	check_source_exec_all
	EXPECT=1
	setup_env "${@:-normal}"
	build_packetdrill_if_needed
	prepare
	run_expect "${@:-normal}"
	analyze "${@:-normal}"
}

go_vm_auto() {
	go_vm_expect "${@}"
}

go_perf() {
	local mode="${1}"
	shift

	EXPECT=1
	setup_env "${mode}"
	# unset TERM to avoid this in pexpect buffers: "\x1b[?2004l\r"
	# python env var to avoid creating __pycache__ in kernel src dir
	TERM="" PYTHONDONTWRITEBYTECODE=1 \
		/perf.py -m "${mode}" --log-dir "${RESULTS_DIR}" \
		"${INPUT_TRACE:+-v}" "${@}" || EXIT_STATUS=$?
}

static_analysis() {
	local src obj ftmp
	ftmp=$(mktemp)

	set_trace_off
	for src in net/mptcp/*.c; do
		obj="${src/%.c/.o}"
		if [[ ${src} == *"_test.mod.c" ]]; then
			continue
		fi

		printinfo "Checking: ${src}"

		touch "${src}"
		if ! KCFLAGS="-Werror" _make_o W=1 "${obj}"; then
			printerr "Found make W=1 issues for ${src}"
		fi

		touch "${src}"
		_make_o C=1 "${obj}" >/dev/null 2>"${ftmp}" || true

		if test -s "${ftmp}"; then
			cat "${ftmp}"
			printerr "Found make C=1 issues for ${src}"
		fi
	done
	set_trace_on

	rm -f "${ftmp}"
}

_lcov2html() {
	local rc=0
	if [ -z "${1}" ] && [ ! -s "${LCOV_FILE}" ]; then
		echo "No LCOV data generated in ${LCOV_FILE}"
		exit 1
	fi

	rm -rf "${LCOV_HTML}"
	mkdir -p "${LCOV_HTML}"
	genhtml -j "$(nproc)" -t "$(_get_ref)" --dark-mode \
		--include '/net/mptcp/' --flat --legend \
		--function-coverage --branch-coverage --keep-going \
		-o "${LCOV_HTML}" "${@:-${LCOV_FILE}}" || rc=${?}

	set +x
	printinfo "Code coverage: ${LCOV_HTML}/index.html"

	return ${rc}
}

print_conclusion() {
	local rc=${1}
	echo -n "${EXIT_TITLE}: "

	if _had_issues; then
		_print_issues "❌" "🔴"
	elif [ "${rc}" != "0" ]; then
		echo "Script error! ❓"
	else
		echo "Success! ✅"
	fi
}

# $@: result paths
print_summaries() {
	local result
	set +x

	_print_line
	echo

	for result in "${@}"; do
		case "$(cat "${result}/conclusion.txt")" in
		*": Success"*)
			echo -ne "\n${COLOR_GREEN}"
			;;
		*": Unstable: "*)
			echo -ne "\n${COLOR_YELLOW}"
			;;
		*)
			echo -ne "\n${COLOR_RED}"
			;;
		esac
		cat "${result}/summary.txt" || echo "Error: no summary"

		echo -ne "${COLOR_RESET}\n"
		_print_line
		echo
	done

	echo -ne "\n${COLOR_BLUE}"
	for result in "${@}"; do
		cat "${result}/conclusion.txt" || echo "Error: No conclusion"
	done
	echo -ne "${COLOR_RESET}"
}

exit_trap() {
	local rc=${?}
	set +x

	echo -ne "\n${COLOR_BLUE}"
	if [ "${EXPECT}" = 1 ]; then
		print_conclusion ${rc} | tee "${CONCLUSION:-"conclusion.txt"}"
	fi
	echo -e "${COLOR_RESET}"

	return ${rc}
}

usage() {
	echo "Usage: ${0} <manual-normal | manual-debug | manual-btf-normal | manual-btf-debug | auto-normal | auto-debug | auto-btf-normal | auto-btf-debug | auto-all | auto-btf-all | perf-normal | perf-debug> [KConfig]"
	echo
	echo " - manual: access to an interactive shell"
	echo " - auto: the tests suite is ran automatically"
	echo " - perf: the perf regression tests suite"
	echo
	echo " - normal: without the debug kconfig"
	echo " - debug: with debug kconfig"
	echo " - all: both 'normal' and 'debug' modes, without BTF support"
	echo " - btf-normal: without the debug kconfig, but with BTF support"
	echo " - btf-debug: with the debug kconfig, and with BTF support"
	echo " - btf-all: both 'normal' and 'debug' modes, with BTF support"
	echo
	echo " - KConfig: optional kernel config: arguments for './scripts/config' or config file"
	echo
	echo "Usage: ${0} <make [params] | make.cross [params] | build <mode> | clean <mode> | defconfig <mode> | selftests | bpftests | cmd <command> | src <source file> | static | vm-manual | vm-auto | connect | lcov2html>"
	echo
	echo " - make: run the make command with optional parameters"
	echo " - make.cross: run Intel's make.cross command with optional parameters"
	echo " - build: build everything, but don't start the VM ('normal' mode by default)"
	echo " - clean: clean the build directory"
	echo " - defconfig: only generate the .config file ('normal' mode by default)"
	echo " - selftests: only build the KSelftests"
	echo " - bpftests: only build the BPF tests"
	echo " - cmd: run the given command"
	echo " - src: source a given script file"
	echo " - static: run static analysis, with make W=1 C=1"
	echo " - vm-manual: start the VM with what has already been built ('normal' mode by default, dash is optional)"
	echo " - vm-auto: same, then run the tests as well ('normal' mode by default, dash is optional)"
	echo " - connect: connect to a VM's remote shell via a VSOCK (set INPUT_VSOCK_CID for multiple VMs)."
	echo " - gdb: connect to the GDB daemon"
	echo " - lcov2html: generate html from lcov file (required INPUT_GCOV=1)"
	echo
	echo "This script needs to be ran from the root of kernel source code."
	echo
	echo "Some files can be added in the kernel sources to modify the tests suite."
	echo "See the README file for more details."
}

if [ -z "${INPUT_MODE}" ]; then
	set +x
	usage
	exit 0
fi

if [ ! -s "${SELFTESTS_CONFIG}" ]; then
	printerr "Please be at the root of kernel source code with MPTCP (Upstream) support"
	exit 1
fi

trap 'exit_trap' EXIT

case "${INPUT_MODE}" in
"manual")
	if [ "${1}" = "normal" ] || [ "${1}" = "debug" ]; then
		go_manual "${1}" "${@:2}"
	else
		go_manual "normal" "${@}"
	fi
	;;
"normal" | "manual-normal")
	go_manual "normal" "${@}"
	;;
"debug" | "manual-debug")
	go_manual "debug" "${@}"
	;;
"btf")
	if [ "${1}" = "normal" ] || [ "${1}" = "debug" ]; then
		go_manual "btf-${1}" "${@:2}"
	else
		go_manual "btf-normal" "${@}"
	fi
	;;
"btf-normal" | "manual-btf" | "manual-btf-normal")
	go_manual "btf-normal" "${@}"
	;;
"btf-debug" | "manual-btf-debug")
	go_manual "btf-debug" "${@}"
	;;
"auto")
	if [ "${1}" = "btf" ]; then
		go_expect "btf-${2?}" "${@:3}"
	else
		go_expect "${1?}" "${@:2}"
	fi
	;;
"expect-normal" | "auto-normal")
	go_expect "normal" "${@}"
	;;
"expect-debug" | "auto-debug")
	go_expect "debug" "${@}"
	;;
"expect-btf" | "expect-btf-normal" | "auto-btf" | "auto-btf-normal")
	go_expect "btf-normal" "${@}"
	;;
"expect-btf-debug" | "auto-btf-debug")
	go_expect "btf-debug" "${@}"
	;;
"expect" | "all" | "expect-all" | "auto-all")
	rc=0
	results=("$(_get_results_dir "normal")")
	INPUT_MODE="auto-normal" "${0}" "${@}" || rc=${?}
	results+=("$(_get_results_dir "debug")")
	wait_prev_vm 100 || true
	INPUT_MODE="auto-debug" "${0}" "${@}" || rc=${?}
	print_summaries "${results[@]}"
	exit ${rc}
	;;
"expect-btf-all" | "auto-btf-all")
	rc=0
	results=("$(_get_results_dir "btf-normal")")
	INPUT_MODE="auto-btf-normal" "${0}" "${@}" || rc=${?}
	results+=("$(_get_results_dir "btf-debug")")
	wait_prev_vm 100 || true
	INPUT_MODE="auto-btf-debug" "${0}" "${@}" || rc=${?}
	print_summaries "${results[@]}"
	exit ${rc}
	;;
"make")
	setup_env "${INPUT_ENV:-normal}"
	_make_o "${@}"
	;;
"make.cross")
	setup_env "${INPUT_ENV:-normal}"
	MAKE_CROSS="/usr/sbin/make.cross"
	wget https://raw.githubusercontent.com/intel/lkp-tests/master/sbin/make.cross -O "${MAKE_CROSS}"
	chmod +x "${MAKE_CROSS}"
	COMPILER_INSTALL_PATH="${VIRTME_WORKDIR}/0day" \
		COMPILER="${COMPILER}" \
		"${MAKE_CROSS}" "${@}"
	;;
"build")
	prepare_all manual "${@:-normal}"
	;;
"clean")
	setup_env "${@:-normal}"
	rm -r "${VIRTME_BUILD_DIR}"
	;;
"defconfig")
	setup_env "${@:-normal}"
	gen_kconfig "${@:-normal}"
	;;
"selftests")
	setup_env "${@:-normal}"
	build_selftests
	;;
"bpftests")
	setup_env "${@:-btf-normal}"
	build_bpftests
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
	setup_env "${@:-normal}"
	static_analysis
	;;
"vm")
	if [ "${1}" = "manual" ] || [ "${1}" = "auto" ]; then
		if [ "${2}" = "btf" ]; then
			"go_vm_${1}" "${2}-${3}" "${@:4}"
		else
			"go_vm_${1}" "${@:2}"
		fi
	else
		go_vm_manual "${@}"
	fi
	;;
"vm-manual")
	go_vm_manual "${@}"
	;;
"vm-expect" | "vm-auto")
	go_vm_expect "${@}"
	;;
"connect")
	exec "${VIRTME_RUN}" --mods none --client --port "${INPUT_VSOCK_CID}" ${1:+--remote-cmd "${*}"}
	;;
"gdb")
	exec gdb-multiarch -q -ex "target remote localhost:$((1234 + INPUT_VSOCK_CID - DEFAULT_VSOCK_CID))${1:+ ${*}}" vmlinux
	;;
"dump")
	exec vng --dump "${1?}"
	;;
"lcov2html")
	setup_env "${@:-normal}"
	while [ -n "${1}" ] && [ ! -s "${1}" ]; do
		shift
	done
	_lcov2html "${@}"
	;;
"perf")
	go_perf "${1?}" "${@:2}"
	;;
"perf-normal" | "perf-debug")
	go_perf "${INPUT_MODE:5}" "${@}"
	;;
*)
	set +x
	printerr "Unknown mode: ${INPUT_MODE}"
	echo -e "${COLOR_RED}"
	usage
	echo -e "${COLOR_RESET}"
	exit 1
	;;
esac

set_trace_off
printinfo "Results dir: ${RESULTS_DIR}"
printinfo "Exit status: ${EXIT_STATUS}"

if is_ci && [ "${INPUT_CI_PRINT_EXIT_CODE}" = 1 ]; then
	echo "==EXIT_STATUS=${EXIT_STATUS}=="
else
	exit "${EXIT_STATUS}"
fi
