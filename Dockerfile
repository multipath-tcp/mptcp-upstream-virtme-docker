FROM ubuntu:20.04

LABEL name=mptcp-upstream-virtme-docker

ARG VIRTME_GIT_URL="git://git.kernel.org/pub/scm/utils/kernel/virtme/virtme.git"
ARG VIRTME_GIT_SHA="1ab5dea159016cd7a079811091d12d2d57a2c023"

ARG PACKETDRILL_GIT_URL="https://github.com/multipath-tcp/packetdrill.git"
ARG PACKETDRILL_GIT_BRANCH="mptcp-net-next"
ENV PACKETDRILL_GIT_BRANCH="${PACKETDRILL_GIT_BRANCH}"

ARG LIBPCAP_GIT_URL="https://github.com/the-tcpdump-group/libpcap.git"
ARG LIBPCAP_GIT_SHA="libpcap-1.10.0"
ARG TCPDUMP_GIT_URL="https://github.com/the-tcpdump-group/tcpdump.git"
ARG TCPDUMP_GIT_SHA="tcpdump-4.99.0"

ARG IPROUTE2_GIT_URL="git://git.kernel.org/pub/scm/network/iproute2/iproute2.git"
#IPROUTE2_GIT_URL="git://git.kernel.org/pub/scm/network/iproute2/iproute2-next.git"
ARG IPROUTE2_GIT_SHA="v5.12.0"
ENV IPROUTE2_GIT_SHA="${IPROUTE2_GIT_SHA}"

ARG BYOBU_URL="https://launchpad.net/byobu/trunk/5.133/+download/byobu_5.133.orig.tar.gz"
ARG BYOBU_MD5="0ff03f3795cc08aae50c1ab117c03261 byobu.tar.gz"

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
		libsmi2-dev libcap-ng-dev \
		pkg-config libmnl-dev \
		clang lld llvm libcap-dev \
		gdb crash dwarves \
		iptables ebtables nftables vim psmisc bash-completion less \
		gettext-base libevent-dev libnewt0.52 libslang2 libutempter0 python3-newt tmux \
		libtap-formatter-junit-perl \
		zstd \
		wget xz-utils lftp cpio u-boot-tools \
		&& \
	apt-get clean

# virtme
RUN cd /opt && \
	git clone "${VIRTME_GIT_URL}" && \
	cd virtme && \
		git checkout "${VIRTME_GIT_SHA}"

# byobu (not to have a dep to iproute2)
RUN cd /opt && \
	curl -L "${BYOBU_URL}" -o byobu.tar.gz && \
	echo "${BYOBU_MD5}" | md5sum -c && \
	tar xzf byobu.tar.gz && \
	cd byobu-*/ && \
		./configure --prefix=/usr && \
		make && \
		sudo make install

# libpcap & tcpdump
RUN cd /opt && \
	git clone "${LIBPCAP_GIT_URL}" libpcap && \
	git clone "${TCPDUMP_GIT_URL}" tcpdump && \
	cd libpcap && \
		git checkout "${LIBPCAP_GIT_SHA}" && \
		./configure --prefix=/usr && \
		make -j"$(nproc)" -l"$(nproc)" && \
		make install && \
	cd ../tcpdump && \
		git checkout "${TCPDUMP_GIT_SHA}" && \
		./configure --prefix=/usr && \
		make -j"$(nproc)" -l"$(nproc)" && \
		make install

# iproute
RUN cd /opt && \
	git clone "${IPROUTE2_GIT_URL}" iproute2 && \
	cd iproute2 && \
		git checkout "${IPROUTE2_GIT_SHA}" && \
		./configure && \
		make -j"$(nproc)" -l"$(nproc)" && \
		make install

# packetdrill
ENV PACKETDRILL_GIT_BRANCH "${PACKETDRILL_GIT_BRANCH}"
RUN cd /opt && \
	git clone "${PACKETDRILL_GIT_URL}" && \
	cd packetdrill && \
		git checkout "${PACKETDRILL_GIT_BRANCH}" && \
		cd gtests/net/packetdrill/ && \
			./configure && \
			make -j"$(nproc)" -l"$(nproc)" && \
			ln -s /opt/packetdrill/gtests/net/packetdrill/packetdrill /usr/sbin/

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
