# SPDX-License-Identifier: GPL-2.0
FROM ubuntu:26.04

LABEL name=mptcp-upstream-virtme-docker

# dependencies for the script
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive \
	apt-get dist-upgrade -y && \
	DEBIAN_FRONTEND=noninteractive \
	apt-get install -y --no-install-recommends \
		build-essential libncurses5-dev gcc libssl-dev bc bison byacc automake cmake \
		libelf-dev flex git curl tar hashalot qemu-system-x86 sudo expect \
		python3 python3-pip python3-pkg-resources python3-scipy file virtiofsd \
		busybox-static coreutils python3-requests libvirt-clients udev \
		iputils-ping ethtool klibc-utils kbd rsync ccache netcat-openbsd \
		ca-certificates gnupg2 net-tools kmod \
		libdbus-1-dev libnl-genl-3-dev libibverbs-dev \
		tcpdump \
		pkgconf libmnl-dev libxtables-dev libatm1-dev libbsd-dev libbpf-dev gcc-multilib libcap-dev libdb-dev libnsl-dev libselinux1-dev zlib1g-dev \
		clang clangd clang-tidy lld llvm llvm-dev libcap-dev \
		gdb gdb-multiarch crash dwarves strace trace-cmd linux-perf \
		iptables ebtables nftables bridge-utils socat \
		vim psmisc bash-completion less jq xxd moreutils time bsdextrautils htop \
		gettext-base libevent-dev libtraceevent-dev libnewt0.52 libslang2 libutempter0 python3-newt tmux gawk \
		libdwarf-dev libbfd-dev libnuma-dev libzstd-dev libunwind-dev libdw-dev libslang2-dev python3-dev python3-setuptools binutils-dev libiberty-dev libbabeltrace-dev systemtap-sdt-dev libperl-dev python3-docutils \
		libtap-formatter-junit-perl lcov libjson-xs-perl \
		zstd \
		wget xz-utils lftp cpio u-boot-tools \
		cscope \
		bpftrace \
		golang \
		mptcpize iperf3 netperf \
		bmon ifstat dstat \
		stress-ng \
		python3-pexpect \
		nvme-cli fio keyutils ktls-utils libnss-myhostname \
		&& \
	apt-get clean

# byobu (not to have a dep to iproute2)
ARG BYOBU_URL="https://github.com/dustinkirkland/byobu/archive/refs/tags/6.16.tar.gz"
ARG BYOBU_SUM="ce294bbc2c04c2b2dd79e2d0ec336812d8e9bd4d9a7f696e2ba335ecbc17fe68  byobu.tar.gz"
RUN cd /opt && \
	curl -L "${BYOBU_URL}" -o byobu.tar.gz && \
	echo "${BYOBU_SUM}" | sha256sum -c && \
	tar xzf byobu.tar.gz && \
	cd byobu-*/ && \
		./autogen.sh && \
		./configure --prefix=/usr --sysconfdir=/etc && \
		make -j"$(nproc)" -l"$(nproc)" && \
		make install

# packetdrill
ARG PACKETDRILL_GIT_URL="https://github.com/multipath-tcp/packetdrill.git"
ARG PACKETDRILL_GIT_BRANCH="mptcp-net-next"
ENV PACKETDRILL_GIT_BRANCH="${PACKETDRILL_GIT_BRANCH}"
RUN cd /opt && \
	git clone "${PACKETDRILL_GIT_URL}" && \
	cd packetdrill && \
		git checkout "${PACKETDRILL_GIT_BRANCH}" && \
		cd gtests/net/packetdrill/ && \
			./configure && \
			make -j"$(nproc)" -l"$(nproc)" && \
			ln -s /opt/packetdrill/gtests/net/packetdrill/packetdrill \
			      /opt/packetdrill/gtests/net/packetdrill/run_all.py \
				/usr/sbin/

# Sparse
ARG SPARSE_GIT_URL="https://kernel.googlesource.com/pub/scm/devel/sparse/sparse.git"
ARG SPARSE_GIT_SHA="37156835e3d725b6d750f000be33ba3814bb2310" # include a fix for __builtin_strlen
RUN cd /opt && \
	git clone "${SPARSE_GIT_URL}" sparse && \
	cd "sparse" && \
		git checkout "${SPARSE_GIT_SHA}" && \
		make -j"$(nproc)" -l"$(nproc)" && \
		make PREFIX=/usr install && \
		cd .. && \
	rm -rf "sparse"

# Pahole
ARG PAHOLE_GIT_URL="https://kernel.googlesource.com/pub/scm/devel/pahole/pahole.git"
ARG PAHOLE_GIT_SHA="6fd0dacc9418b103af4245ab300b9c135bcdb383" # fix discarded-qualifiers
RUN cd /opt && \
	git clone "${PAHOLE_GIT_URL}" pahole && \
	cd "pahole" && \
		git checkout "${PAHOLE_GIT_SHA}" && \
		git submodule update --init --recursive && \
		mkdir build && \
		cd build && \
		cmake .. && \
		make -j"$(nproc)" -l"$(nproc)" && \
		make install && \
		ldconfig && \
		cd .. && \
	rm -rf "pahole"

# iproute
ARG IPROUTE2_GIT_URL="https://kernel.googlesource.com/pub/scm/network/iproute2/iproute2.git"
ARG IPROUTE2_GIT_SHA="v7.1.0"
RUN cd /opt && \
	git clone "${IPROUTE2_GIT_URL}" iproute2 && \
	cd iproute2 && \
		git checkout "${IPROUTE2_GIT_SHA}" && \
		./configure --color=auto && \
		make -j"$(nproc)" -l"$(nproc)" && \
		make install && \
		cd .. && \
	rm -rf iproute2

# Virtme NG
ARG VIRTME_NG_VERSION="1.41"
RUN pip3 install --no-cache-dir --break-system-packages \
	virtme-ng=="${VIRTME_NG_VERSION}"

# to quickly shutdown the VM and more
RUN for i in /usr/lib/klibc/bin/*; do \
	type "$(basename "${i}")" >/dev/null 2>&1 || ln -sv "${i}" /usr/sbin/; \
    done

# CCache for quicker builds with default colours
# Note: use 'ccache -M xG' to increase max size, default is 5GB
ENV PATH=/usr/lib/ccache:/opt/virtme-ng:${PATH}
ENV CCACHE_COMPRESS=true
ENV KBUILD_BUILD_TIMESTAMP="0"
ENV GCC_COLORS=error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01

COPY entrypoint.sh *.py *.yml /

ENTRYPOINT ["/entrypoint.sh"]
