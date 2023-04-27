FROM ubuntu:22.04

LABEL name=mptcp-upstream-virtme-docker

# dependencies for the script
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive \
	apt-get install -y --no-install-recommends \
		build-essential libncurses5-dev gcc libssl-dev bc bison \
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
		libdwarf-dev libbfd-dev libnuma-dev libzstd-dev libunwind-dev libdw-dev libslang2-dev python3-dev python3-setuptools binutils-dev libiberty-dev libbabeltrace-dev systemtap-sdt-dev libperl-dev \
		libtap-formatter-junit-perl \
		zstd \
		wget xz-utils lftp cpio u-boot-tools \
		cscope \
		bpftrace \
		&& \
	apt-get clean

# virtme
ARG VIRTME_GIT_URL="https://github.com/matttbe/virtme.git"
ARG VIRTME_GIT_SHA="a680c0861cf6f9dc6a8a821e9e58ae43c5e68435"
RUN cd /opt && \
	git clone "${VIRTME_GIT_URL}" && \
	cd virtme && \
		git checkout "${VIRTME_GIT_SHA}"

# byobu (not to have a dep to iproute2)
ARG BYOBU_URL="https://launchpad.net/byobu/trunk/5.133/+download/byobu_5.133.orig.tar.gz"
ARG BYOBU_MD5="0ff03f3795cc08aae50c1ab117c03261 byobu.tar.gz"
RUN cd /opt && \
	curl -L "${BYOBU_URL}" -o byobu.tar.gz && \
	echo "${BYOBU_MD5}" | md5sum -c && \
	tar xzf byobu.tar.gz && \
	cd byobu-*/ && \
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
ARG SPARSE_GIT_SHA="ce1a6720f69e6233ec9abd4e9aae5945e05fda41" # include a fix for 'unreplaced' issues
RUN cd /opt && \
	git clone "${SPARSE_GIT_URL}" sparse && \
	cd "sparse" && \
		make -j"$(nproc)" -l"$(nproc)" && \
		make PREFIX=/usr install && \
		cd .. && \
	rm -rf "sparse"

# iproute
ARG IPROUTE2_GIT_URL="https://git.kernel.org/pub/scm/network/iproute2/iproute2.git"
ARG IPROUTE2_GIT_SHA="v6.3.0"
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
