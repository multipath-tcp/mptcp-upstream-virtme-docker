#! /bin/bash -x

docker exec -it \
	"$(docker ps --filter "label=name=mptcp-upstream-virtme-docker" -l --format "{{.ID}}")" \
	/entrypoint.sh connect "${@}"
