# MPTCP Upstream Virtme Docker

This repo contains files to build a vitual environment with virtme to validate
[mptcp_net-next](https://github.com/multipath-tcp/mptcp_net-next) repo.

The idea here is to have automatic builds to published a docker that can be used
by devs and CI.

## Published image

This docker image needs to be executed with `--privileged` option to be able to
execute QEmu with KVM acceleration.

## How to use

### User mode

Without cloning this repo, you can quickly get a ready to use environment:

```
$ cd <kernel source code>
$ docker pull mptcp/mptcp-upstream-virtme-docker:latest
$ docker run -v "${PWD}:${PWD}:rw" -w "${PWD}" --privileged --rm -it \
  mptcp/mptcp-upstream-virtme-docker:latest \
  <manual-normal | manual-debug | auto-normal | auto-debug | auto-all>
```

### Developer mode

Clone this repo, then:

```
$ cd <kernel source code>
$ /PATH/TO/THIS/REPO/run-tests-dev.sh <manual-normal | manual-debug | auto-normal | auto-debug | auto-all>
```

This will build the docker image and start the script.

## Extension

### Files

3 files can be created in the root dir of the kernel source code:

- `.virtme-exec-pre`
- `.virtme-exec-run`
- `.virtme-exec-post`

`pre` and `post` are ran before and after the tests suite.
`run` is ran instead of the tests suite.
These scripts are sourced and can used functions from the virtme script.

### Env vars

#### Not blocking with questions

You can set `INPUT_NO_BLOCK=1` env var not to block if these files are present.
This is useful if you need to do a `git bisect`.

#### Packetdrill

You can set `INPUT_PACKETDRILL_NO_SYNC=1` env var not to sync Packetdrill with
upstream. This is useful if you mount a local packetdrill repo in the image.

You can also set `INPUT_PACKETDRILL_NO_MORE_TOLERANCE=1` not to increase
Packetdrill's tolerances.

If you run the Docker commands directly, you can use:

```
$ docker run \
  -e INPUT_PACKETDRILL_NO_SYNC=1 \
  -e INPUT_PACKETDRILL_NO_MORE_TOLERANCE=1 \
  -v /PATH/TO/packetdrill:/opt/packetdrill:rw \
  -v "${PWD}:${PWD}:rw" -w "${PWD}" \
  --privileged --rm -it \
  mptcp/mptcp-upstream-virtme-docker:latest \
  <manual-normal | manual-debug | auto-normal | auto-debug | auto-all>
```

If you use the `run*.sh` scripts, you can set `VIRTME_PACKETDRILL_PATH` to do
this mount and set the proper env var.

```
VIRTME_PACKETDRILL_PATH=/PATH/TO/packetdrill \
  /PATH/TO/THIS/REPO/run-tests-dev.sh <manual-normal | manual-debug | auto-normal | auto-debug | auto-all>
```
