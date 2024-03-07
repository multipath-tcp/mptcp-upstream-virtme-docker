FROM ubuntu:23.10

LABEL name=mptcp-upstream-virtme-docker

# dependencies for the script
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive \
	apt-get dist-upgrade -y && \
	DEBIAN_FRONTEND=noninteractive \
	apt-get install -y --no-install-recommends \
		build-essential libncurses5-dev gcc libssl-dev bc bison automake \
		libelf-dev flex git curl tar hashalot qemu-kvm sudo expect \
		python3 python3-pkg-resources busybox \
		iputils-ping ethtool klibc-utils kbd rsync ccache netcat-openbsd \
		ca-certificates gnupg2 net-tools kmod \
		libdbus-1-dev libnl-genl-3-dev libibverbs-dev \
		tcpdump \
		pkg-config libmnl-dev \
		clang lld llvm llvm-dev libcap-dev \
		gdb crash dwarves strace \
		iptables ebtables nftables vim psmisc bash-completion less jq \
		gettext-base libevent-dev libtraceevent-dev libnewt0.52 libslang2 libutempter0 python3-newt tmux \
		libdwarf-dev libbfd-dev libnuma-dev libzstd-dev libunwind-dev libdw-dev libslang2-dev python3-dev python3-setuptools binutils-dev libiberty-dev libbabeltrace-dev systemtap-sdt-dev libperl-dev python3-docutils \
		libtap-formatter-junit-perl \
		zstd \
		wget xz-utils lftp cpio u-boot-tools \
		cscope \
		bpftrace \
		&& \
	apt-get clean

# virtme
ARG VIRTME_GIT_URL="https://github.com/matttbe/virtme.git"
ARG VIRTME_GIT_SHA="57c440a1dce4476638d67a2d1aead5bdcced0de7" # include a fix for modules on linux >= 6.2 and QEmu > 6
RUN cd /opt && \
	git clone "${VIRTME_GIT_URL}" && \
	cd virtme && \
		git checkout "${VIRTME_GIT_SHA}"

# byobu (not to have a dep to iproute2)
ARG BYOBU_URL="https://github.com/dustinkirkland/byobu/archive/refs/tags/6.12.tar.gz"
ARG BYOBU_SUM="abb000331858609dfda9214115705506249f69237625633c80487abe2093dd45  byobu.tar.gz"
RUN cd /opt && \
	curl -L "${BYOBU_URL}" -o byobu.tar.gz && \
	echo "${BYOBU_SUM}" | sha256sum -c && \
	tar xzf byobu.tar.gz && \
	cd byobu-*/ && \
		./autogen.sh && \
		./configure --prefix=/usr && \
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
ARG SPARSE_GIT_URL="git://git.kernel.org/pub/scm/devel/sparse/sparse.git"
ARG SPARSE_GIT_SHA="09411a7a5127516a0741eb1bd8762642fa9197ce" # include a fix for 'unreplaced' issues and llvm 16
RUN cd /opt && \
	git clone "${SPARSE_GIT_URL}" sparse && \
	cd "sparse" && \
		git checkout "${SPARSE_GIT_SHA}" && \
		make -j"$(nproc)" -l"$(nproc)" && \
		make PREFIX=/usr install && \
		cd .. && \
	rm -rf "sparse"

# iproute
ARG IPROUTE2_GIT_URL="https://git.kernel.org/pub/scm/network/iproute2/iproute2.git"
ARG IPROUTE2_GIT_SHA="v6.8.0"
ENV IPROUTE2_GIT_SHA="${IPROUTE2_GIT_SHA}"
RUN cd /opt && \
	git clone "${IPROUTE2_GIT_URL}" iproute2 && \
	cd iproute2 && \
		git checkout "${IPROUTE2_GIT_SHA}" && \
		./configure && \
		make -j"$(nproc)" -l"$(nproc)" && \
		make install

# to quickly shutdown the VM and more
RUN for i in /usr/lib/klibc/bin/*; do \
	type "$(basename "${i}")" >/dev/null 2>&1 || ln -sv "${i}" /usr/sbin/; \
    done

# CCache for quicker builds with default colours
# Note: use 'ccache -M xG' to increase max size, default is 5GB
ENV PATH /usr/lib/ccache:${PATH}
ENV CCACHE_COMPRESS true
ENV KBUILD_BUILD_TIMESTAMP "0"
ENV GCC_COLORS error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01

COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]
