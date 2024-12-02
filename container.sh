#! /bin/bash
# SPDX-License-Identifier: GPL-2.0

docker exec -it \
	-e "INPUT_TRACE=${INPUT_TRACE:-0}" \
	"$(docker ps --filter "label=name=mptcp-upstream-virtme-docker" -l --format "{{.ID}}")" \
	"${@:-bash}"
