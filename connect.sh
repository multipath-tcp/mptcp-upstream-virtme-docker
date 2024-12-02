#! /bin/bash

if [[ "${-}" =~ "x" ]]; then
	export INPUT_TRACE=1
fi
docker exec -it \
	-e "INPUT_TRACE=${INPUT_TRACE:-0}" \
	"$(docker ps --filter "label=name=mptcp-upstream-virtme-docker" -l --format "{{.ID}}")" \
	/entrypoint.sh connect "${@}"
