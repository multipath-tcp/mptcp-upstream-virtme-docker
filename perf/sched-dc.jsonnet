// As in a data center: very high speed, low latency, and a lot of memory for
// the buffers. The CPU is then the bottleneck: what the kernel computes, or
// sends for nothing, e.g. data reinjected while the paths are equally fast, is
// directly visible in the throughput.
//
// Everything is done in the client VM, between 2 netns linked by 2 veth pairs
// without shaping, the sender on CPU 0, the receiver on CPU 1. Between 2 VMs,
// the results depend too much on where the host runs the threads of the VMs
// and of vhost, e.g. +/- 50% for the same kernel. The server VM is not used.
//
// Even like that, the throughputs and latencies depend on the host: they are
// marked as 'noisy', only reported with 'perf.py --reg-noisy', e.g. on a
// dedicated host. The counters are always checked.

local ip = '10.10.9.2';  // server address, on its loopback
local mbit = 1000000;
local secs = 20;

local lines(cmds) = std.join('\n', cmds) + '\n';
local artifact(f) = '"${RESULTS_DIR}/artifacts/' + f + '"';
local inNs(ns, cmd) = 'ip netns exec ' + ns + ' ' + cmd;

// 'c' sends, 's' receives, through 2 paths: c1-s1 and c2-s2. 128 MB buffers,
// and enough memory not to be under pressure: tcp_mem is global.
local setup(c) = {
  name: 'netns',
  client: lines([
    'sysctl -qw net.ipv4.tcp_mem="1048576 1572864 2097152"',
    'ip netns add c',
    'ip netns add s',
    'for ns in c s; do',
    '  ip -n "${ns}" link set lo up',
    '  ' + inNs('"${ns}"', 'sysctl -qw net.ipv4.tcp_rmem="4096 131072 134217728"'),
    '  ' + inNs('"${ns}"', 'sysctl -qw net.ipv4.tcp_wmem="4096 16384 134217728"'),
    '  ip -n "${ns}" mptcp limits set subflow 2 add_addr_accepted 0',
    'done',
    'ip -n s addr add ' + ip + '/32 dev lo',
    'for i in 1 2; do',
    '  ip link add "c${i}" netns c type veth peer name "s${i}" netns s',
    '  ip -n c addr add "10.10.${i}.1/24" dev "c${i}"',
    '  ip -n s addr add "10.10.${i}.2/24" dev "s${i}"',
    '  ip -n c link set "c${i}" up',
    '  ip -n s link set "s${i}" up',
    '  ip -n c route add default via "10.10.${i}.2" dev "c${i}" metric "$((100 + i))"',
    'done',
  ] + (if c.single then [] else [
         'ip -n c mptcp endpoint add 10.10.2.1 dev c2 subflow',
       ]) + [
    inNs('c', 'nstat -n'),
    inNs('s', 'nstat -n'),
  ]),
};

local waitListen(port) =
  inNs('s', 'sh -c \'until ss -Htnl | grep -q ":' + port + ' "; do sleep 0.1; done\'');

// Values from netperf, latencies in us
local netperfKeys = 'TRANSACTION_RATE,MEAN_LATENCY,P50_LATENCY,P90_LATENCY,P99_LATENCY';

local workload(c) =
  if c.rr then {
    name: 'netperf',
    client: lines([
      inNs('s', 'mptcpize run netserver -4 -L ' + ip + ' >/dev/null'),
      waitListen(12865),
      // one transaction at a time, 1 byte each way, without Nagle
      inNs('c', 'mptcpize run netperf -4 -H ' + ip + ' -t TCP_RR -l ' + secs +
                ' -j -P 0 -T 0,1 -- -D -r 1,1 -k ' + netperfKeys +
                ' > ' + artifact('netperf.txt')),
      'rc=$?',
      'jq -Rn \'[inputs | split("=") | {(.[0]): (.[1] | tonumber)}] | add\' ' +
      artifact('netperf.txt') + ' > ' + artifact('netperf.json'),
      '[ "${rc}" = 0 ]',
    ]),
    timeout_s: secs + 60,
  } else {
    name: 'iperf3',
    client: lines([
      inNs('s', 'iperf3 -m -s -1 -D -B ' + ip + ' -A 1'),
      waitListen(5201),
      inNs('c', std.join(' ', std.prune([
        'iperf3 -m -c',
        ip,
        '-A 0 -J -t',
        std.toString(secs),
        if c.parallel > 1 then '-P ' + c.parallel,
        if c.write_size != null then '-l ' + c.write_size,
        '>',
        artifact('iperf_cli.json'),
      ]))),
    ]),
    timeout_s: secs + 60,
  };

local collect = {
  name: 'counters',
  client: lines([
    inNs('c', 'nstat -jz 2>/dev/null > ' + artifact('nstat_c.json')),
    inNs('s', 'nstat -jz 2>/dev/null > ' + artifact('nstat_s.json')),
    inNs('c', 'cat /sys/class/net/c2/statistics/tx_bytes > ' + artifact('c2_tx_bytes')),
    'for ns in c s; do ip netns pids "${ns}" | xargs -r kill; done',
    'sleep 0.5',
    'ip netns del c',
    'ip netns del s',
  ]),
};

// the client creates the additional subflows: one per connection, and one
// more with netperf, for its control connection
local joins(c) = if c.single then 0 else c.parallel + (if c.rr then 1 else 0);

local validation(c) = [{
  name: 'transfer',
  run: lines(std.prune([
    'set -x',
    if c.rr then 'jq -e \'.TRANSACTION_RATE > 0\' artifacts/netperf.json'
    else 'jq -e \'.end.sum_received.bits_per_second >= ' + 1000 * mbit + '\' artifacts/iperf_cli.json',
    '[ "$(jq -r \'.kernel.MPTcpExtMPJoinSynAckRx // 0\' artifacts/nstat_c.json)" -ge ' + joins(c) + ' ]',
    // the second path is used: not with small writes, on 't/upstream'
    if c.both_paths then '[ "$(cat artifacts/c2_tx_bytes)" -ge 1000000 ]',
  ])),
}];

// After the transfer: more is worse. Small differences are ignored, they are
// often at 0, or vary a lot. Secondary checks: not to make the main ones less
// sensitive.
local counter(name, ns, key, min_diff) = {
  name: name,
  file: 'artifacts/nstat_' + ns + '.json',
  json_field: ['kernel', key],
  direction: 'higher',
  min_diff: min_diff,
  min_diff_pc: 50,
  holm_bonferroni: false,
  // not depending on the host
  noisy: false,
};

local regression(c) = {
  // default alpha: 0.05
  global: {
    history_max_n: 50,
    // see the top of this file
    noisy: true,
    // the CPU speed varies a bit: smaller changes are not relevant
    min_diff_pc: 2,
  },
  steps: (if c.rr then [
            {
              name: 'Transaction rate',
              file: 'artifacts/netperf.json',
              json_field: ['TRANSACTION_RATE'],
              direction: 'lower',
            },
            {
              name: 'P99 latency',
              file: 'artifacts/netperf.json',
              json_field: ['P99_LATENCY'],
              direction: 'higher',
            },
          ] else [{
            name: 'iperf3 received',
            file: 'artifacts/iperf_cli.json',
            json_field: ['end', 'sum_received', 'bits_per_second'],
            direction: 'lower',
          }]) + [
    // e.g. reinjections, while the paths are equally fast
    counter('Duplicated data', 's', 'MPTcpExtDuplicateData', 100),
    // MPTCP-level timeouts: the data was stuck on a subflow
    counter('MPTCP retransmissions', 'c', 'MPTcpExtMPTCPRetrans', 20),
  ],
};

local defaults = {
  single: false,  // only the initial subflow
  parallel: 1,
  write_size: null,  // iperf3 writes, in bytes
  rr: false,  // request/response, 1 byte each way
  both_paths: true,  // the second path is expected to be used
};

local test(name, cfg) =
  local c = defaults + cfg;
  {
    name: name,
    // the sender and the receiver on their own CPU, and room for the buffers
    cpus: 2,
    ram: '4G',
    steps: [setup(c), workload(c), collect],
    validation: validation(c),
    regression: regression(c),
  };

{
  name: 'sched-dc',
  global: {
    timeout_s: 900,
  },
  tests: [
    test('bulk', {}),
    test('bulk single', { single: true, both_paths: false }),
    test('bulk parallel=4', { parallel: 4 }),
    test('bulk write=4K', { write_size: 4096, both_paths: false }),
    test('rr size=1', { rr: true, both_paths: false }),
  ],
}
