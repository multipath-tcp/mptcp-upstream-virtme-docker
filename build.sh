#!/bin/bash -ex
cd "$(dirname "$(realpath -P "${0}")")"
docker build -t "${DOCKER_VIRTME_NAME:-mptcp/mptcp-upstream-virtme-docker:latest}" -f Dockerfile .
