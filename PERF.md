# Performance regressions

Performance regressions is a tricky topic: the idea is to control most
parameters, and compare some specific aspects with a tolerance.

## Deployment

Two modes are currently supported: virtual only, with physical network cards.

### Virtual only

This mode is ideal for the developments and easy to deploy tests. The drawbacks
are that using virtual NIC, e.g. the way the SKB are allocated are completely
different, especially on the reception part.

```
 ----------------------------------------------
|  --------                          --------  |
| |        |                        |        | |
| |  VM 1  | ------- bridge ------- |  VM 2  | |
| |        |  netem          netem  |        | |
|  --------                          --------  |
|                   Container                  |
 ----------------------------------------------
```

### With physical network cards

In order to simulate more real network conditions, it is recommended to use a
minimum of 2 machines, each with 2 Ethernet ports:

- one running 2 VMs: sender and receiver
- one in charge of the shaping

It is better to avoid using TC for the shaping on the interfaces used by the
sender or receiver because this will use different paths from the "normal"
behaviour on the kernel side.

```
 ---------------------------
|  -----------------------  |    ------------------------
| |  --------             | |   |         Netem          |
| | |        | --- Eth 1 ---------- Eth 1 ---            |
| | |  VM 1  |            | |   |            |           |
| | |        |            | |   |            B           |
| |  --------             | |   |            R           |
| |                       | |   |            I           |
| |         Host 1        | |   |            D   Host 2  |
| |                       | |   |            G           |
| |  --------             | |   |            E           |
| | |        |            | |   |            |           |
| | |  VM 2  |            | |   |            /           |
| | |        | --- Eth 2 ---------- Eth 2 --             |
| |  --------             | |   |         Netem          |
| |       Container       | |    ------------------------
| |      --net=host       | |
|  -----------------------  |
 ---------------------------
```

## Run

The Docker image described in [README.md](README.md) can be used. To get more
details, see:

```shell
docker run (...) perf-normal -h
```
