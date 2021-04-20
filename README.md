# MPTCP Upstream Virtme Docker

This repo contains files to build a vitual environment with virtme to validate
[mptcp_net-next](https://github.com/multipath-tcp/mptcp_net-next) repo.

The idea here is to have automatic builds to published a docker that can be used
by devs and CI.

## Published image

This docker image needs to be executed with `--privileged` option to be able to
execute QEmu with KVM acceleration.

## Extension

3 files can be created:

- `.virtme-exec-pre`
- `.virtme-exec-run`
- `.virtme-exec-post`

`pre` and `post` are ran before and after the tests suite.
`run` is ran instead of the tests suite.
These scripts are sourced and can used functions from the virtme script.

You can set `VIRTME_NO_BLOCK=1` env var not to block if these files are present.
This is useful if you need to do a `git bisect`.
