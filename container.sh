#! /bin/bash
# SPDX-License-Identifier: GPL-2.0

envs=()
for env in "${!INPUT_@}"; do
	envs+=(-e "${env}=${!env}")
done

docker exec -it \
	"${envs[@]}" \
	"$(docker ps --filter "label=name=mptcp-upstream-virtme-docker" -l --format "{{.ID}}")" \
	"${@:-bash}"
