# MPTCP Upstream Virtme Docker

This repo contains files to build a virtual environment with Virtme to validate
[mptcp_net-next](https://github.com/multipath-tcp/mptcp_net-next) repo.

The idea here is to have automatic builds to publish a docker image that can be
used by devs and CI.

## Entrypoint options

When launching the docker image, you have to specify the mode you want to use:

- `manual-*`: Build the kernel and dependences, start a VM, then leave you with
  a shell prompt inside the VM:
  - `manual-normal`: With a non-debug kernel config.
  - `manual-debug`: With a debug kernel config.
  - `manual-btf-normal`: With BTF support (needed for BPF features), no debug.
  - `manual-btf-debug`: With BTF support (needed for BPF features), with debug.
- `auto-*`: Build the kernel and dependences, start a VM, then run all the
  automatic tests from the VM:
  - `auto-normal`: With a non-debug kernel config.
  - `auto-debug`: With a debug kernel config.
  - `auto-all`: First with a non-debug, then a debug kernel config.
  - `auto-btf-normal`: With BTF support (needed for BPF features), no debug.
  - `auto-btf-debug`: With BTF support (needed for BPF features), with debug.
  - `auto-btf-all`: With BTF support, first without debug, then with debug.
- `make`: Run the `make` command with optional parameters.
- `make.cross`: Run Intel's `make.cross` command with optional parameters.
- `build`: Build everything, but don't start the VM (`normal` mode by default).
- `defconfig`: Only generate the `.config` file (`normal` mode by default).
- `selftests`: Only build the KSelftests.
- `bpftests`: Only build the BPF tests.
- `cmd`: Run the given command in the docker image (not in the VM), e.g.
  `cmd bash` to have a prompt.
- `static`: Run static analysis, with `make W=1 C=1`.
- `vm-manual`: Start the VM with what has already been built (`normal` mode by
  default).
- `vm-auto`: Start the VM with what has already been built, then run the tests
  (`normal` mode by default).
- `lcov2html`: Generate HTML from LCOV file(s) (available when tests have been
  executed with `INPUT_GCOV=1`).
- `src`: `source` a given script file.
- `help`: display all possible commands.

All the `manual-*` and `auto-*` options accept optional arguments for
`scripts/config` script from the kernel source code, e.g. `-e DEBUG_LOCKDEP`

## How to use

### User mode

Without cloning this repo, you can quickly get a ready to use environment:

```bash
cd <kernel source code>
docker run -v "${PWD}:${PWD}:rw" -w "${PWD}" -v "${PWD}/.home:/root:rw" --rm \
  -it --privileged --pull always mptcp/mptcp-upstream-virtme-docker:latest \
  <entrypoint options, see above>
```

This docker image needs to be executed with `--privileged` option to be able to
execute QEmu with KVM acceleration.

Note: if the access to the Docker Hub Registry is blocked, you can also download
the image from the GitHub registry, using `ghcr.io/multipath-tcp/` as prefix,
instead of `mptcp`, e.g.

```
ghcr.io/multipath-tcp/mptcp-upstream-virtme-docker:latest
```

### Developer mode

Clone this repo, then:

```bash
cd <kernel source code>
/PATH/TO/THIS/REPO/run-tests-dev.sh <entrypoint options, see above>
```

This will build and start the docker image.

To avoid using long paths, you can create symlinks:

```bash
cd <kernel source code>
ln -s /PATH/TO/THIS/REPO/run-tests-dev.sh .virtme.sh
ln -s /PATH/TO/THIS/REPO/run-tests-dev-clang.sh .virtme-clang.sh
```

Then simply call `./.virtme.sh` or `.virtme-clang.sh`.

## Extension

### Files

3 files can be created in the root dir of the kernel source code:

- `.virtme-exec-pre`
- `.virtme-exec-run`
- `.virtme-exec-post`

`pre` and `post` are run before and after the tests' suite. `run` is run instead
of the tests' suite.

These scripts are sourced and can use functions from the virtme script.

### Env vars

Env vars can be set to change the behaviour of the script. When using the Docker
command, you need to specify the `-e` parameter, e.g. to set
`INPUT_BUILD_SKIP=1`:

```bash
docker run -e INPUT_BUILD_SKIP=1 (...) mptcp/mptcp-upstream-virtme-docker:latest (...)
```

#### Skip kernel build

If you didn't change the kernel code, it can be useful to skip the compilation
part. You can then set `INPUT_BUILD_SKIP=1` to save a few seconds to start the
VM.

#### Use CLang instead of GCC

Simply set `INPUT_CLANG=1` env var with all the commands you use.

#### Not blocking with questions

You can set `INPUT_NO_BLOCK=1` env var not to block if these files are present.
This is useful if you need to do a `git bisect`.

### Not stop after an error is detected with `run_loop`

You can set `INPUT_RUN_LOOP_CONTINUE=1` env var to continue even if an error is
detected. Failed iterations are logged in `${CONCLUSION}.failed`.

#### Packetdrill

You can set `INPUT_PACKETDRILL_STABLE=1` env var to use the branch for the
current kernel version instead of the dev version following MPTCP net-next.

You can set `INPUT_PACKETDRILL_NO_SYNC=1` env var not to sync Packetdrill with
upstream. This is useful if you mount a local packetdrill repo in the image.

You can also set `INPUT_PACKETDRILL_NO_MORE_TOLERANCE=1` not to increase
Packetdrill's tolerances.

If you run the Docker commands directly, you can use:

```bash
docker run \
  -e INPUT_PACKETDRILL_NO_SYNC=1 \
  -e INPUT_PACKETDRILL_NO_MORE_TOLERANCE=1 \
  -v /PATH/TO/packetdrill:/opt/packetdrill:rw \
  -v "${PWD}:${PWD}:rw" -w "${PWD}" -v "${PWD}/.home:/root:rw" \
  --privileged --rm -it \
  mptcp/mptcp-upstream-virtme-docker:latest \
  manual

cd /opt/packetdrill/gtests/net/
./packetdrill/run_all.py -lvv -P 2 mptcp/dss ## or any other subdirs
```

If you use the `run*.sh` scripts, you can set `VIRTME_PACKETDRILL_PATH` to do
this mount and set the proper env var.

```bash
VIRTME_PACKETDRILL_PATH=/PATH/TO/packetdrill \
  /PATH/TO/THIS/REPO/run-tests-dev.sh <entrypoint options, see above>
```

If packetdrill itself is modified and to continue to use the same build
environment, the recompilation can also be done from the running docker image:

```bash
docker exec -w /opt/packetdrill/gtests/net/packetdrill -it \
  $(docker ps --filter ancestor=mptcp/mptcp-upstream-virtme-docker --format='{{.ID}}') \
    make
```

## Using for other subsystems than MPTCP

These project has been initially created to validate modifications done in MPTCP
Upstream project. But it can also be used to validate other subsystems. Here are
a few tips to use it elsewhere:

- If you only need to run extra steps at the "preparation" phase but keeping the
  same docker image, write them in a `.virtme-prepare-post` file, e.g. to
  compile iproute2 differently.

- Similar to the previous point, you might prefer to extend the docker image not
  to have to install new packages from `.virtme-prepare-post` each time you run
  the docker image. You can use our docker image as a base and then install
  other dependences:
  ```dockerfile
  FROM mptcp/mptcp-upstream-virtme-docker:latest

  RUN apt-get update && apt-get install -y python3-pip python3-scapy
  ```


- Skip the build steps you don't need, e.g.
  ```bash
  docker run (...) \
      -e INPUT_BUILD_SKIP_PERF=1 \
      -e INPUT_BUILD_SKIP_SELFTESTS=1 \
      -e INPUT_BUILD_SKIP_PACKETDRILL=1 \
      (...) \
      mptcp/mptcp-upstream-virtme-docker \
      auto-normal
  ```

- Specify the path to another selftests dir to test by using
  `INPUT_SELFTESTS_DIR` env var, e.g.
  ```bash
  docker run (...) \
      -e INPUT_SELFTESTS_DIR=tools/testing/selftests/tc-testing
      (...)
  ```

- Use `.virtme-exec-run` file (and similar) to execute different tests,
  see above.

An example:

```bash
# Better to extend the docker image (but quick solution here), see above:
cat <<'EOF' > ".virtme-prepare-post"
apt-get update && apt-get install -y python3-pip python3-scapy
EOF

# Only run the selftests
cat <<'EOF' > ".virtme-exec-run"
run_selftest_all
EOF

# skip Packetdrill build (not needed), run TC selftests and add CONFIG_DUMMY
docker run -v "${PWD}:${PWD}:rw" -w "${PWD}" -v "${PWD}/.home:/root:rw" --rm \
  -it --privileged \
  -e INPUT_BUILD_SKIP_PACKETDRILL=1 \
  -e INPUT_SELFTESTS_DIR=tools/testing/selftests/tc-testing \
  --pull always mptcp/mptcp-upstream-virtme-docker:latest \
  auto-normal -e DUMMY
```

Feel free to contact us and/or open Pull Requests to support more cases.

## Compilation issues with Perf or Objtools

If you see such messages:

```
Makefile.config:458: *** No gnu/libc-version.h found, please install glibc-dev[el].  Stop.
```

This can happen when switching between major versions of the compiler. In this
case, it will be required to clean the build dir in `.virtme/build`, e.g.

```bash
docker run -v "${PWD}:${PWD}:rw" -w "${PWD}" --rm -it \
  mptcp/mptcp-upstream-virtme-docker:latest \
  cmd rm -r .virtme/build*/tools
```

## Working with VSCode

If you use [VSCode for Linux kernel development](https://github.com/FlorentRevest/linux-kernel-vscode)
add-on, you can configure it to use this docker image: simply copy all files
from the [`vscode`](/vscode) directory in your `.vscode` dir from the kernel
source (or use symbolic links). `.clangd` needs to be placed at the root of the
kernel source directory.

Notes:
- The VSCode add-on needs some modifications, see
  [PR #5](https://github.com/FlorentRevest/linux-kernel-vscode/pull/5) and
  [PR #6](https://github.com/FlorentRevest/linux-kernel-vscode/pull/6). If these
  PRs are not merged, you can use
  [this fork](https://github.com/matttbe/linux-kernel-vscode/) (`virtme-support`
  branch) for the moment.
- CLang will be used by VSCode instead of GCC. It is then required to launch all
  docker commands with `-e INPUT_CLANG=1`, see above.
- CLangD will be used on the host machine, not in the Docker.

## CLang Analyzer

In the kernel, it is possible to run `make clang-analyzer`, but it will scan all
compiled files, that's too long, and maybe not needed here. Here is a workaround
to scan only MPTCP files:

```bash
cd <kernel source code>
docker run -v "${PWD}:${PWD}:rw" -w "${PWD}" -v "${PWD}/.home:/root:rw" --rm \
  -e INPUT_CLANG=1 \
  -it --privileged --pull always mptcp/mptcp-upstream-virtme-docker:latest \
  build
jq 'map(select(.file | contains ("/mptcp/")))' \
  .virtme/build-clang/compile_commands.json > compile_commands-mptcp.json
docker run -v "${PWD}:${PWD}:rw" -w "${PWD}" -v "${PWD}/.home:/root:rw" --rm \
  -e INPUT_CLANG=1 \
  -it --privileged --pull always mptcp/mptcp-upstream-virtme-docker:latest \
  cmd ./scripts/clang-tools/run-clang-tools.py clang-analyzer compile_commands-mptcp.json
```

Or when using the scripts from this repo:

```bash
./.virtme-clang.sh build
jq 'map(select(.file | contains ("/mptcp/")))' .virtme/build-clang/compile_commands.json > compile_commands-mptcp.json
./.virtme-clang.sh cmd ./scripts/clang-tools/run-clang-tools.py clang-analyzer compile_commands-mptcp.json
```
