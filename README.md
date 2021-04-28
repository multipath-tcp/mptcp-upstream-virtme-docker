# MPTCP Upstream Virtme Docker

This repo contains files to build a vitual environment with virtme to validate
[mptcp_net-next](https://github.com/multipath-tcp/mptcp_net-next) repo.

The idea here is to have automatic builds to published a docker that can be used
by devs and CI.

## Published image

This docker image needs to be executed with `--privileged` option to be able to
execute QEmu with KVM acceleration.

## Extension

### Files

3 files can be created:

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
upstream. This is useful if you mount a local packetdrill repo in the image
with:

  -v /PATH/TO/packetdrill:/opt/packetdrill:rw

You can also set `VIRTME_PACKETDRILL_PATH` with `run*.sh` scripts to do this
mount and set the proper env var.
