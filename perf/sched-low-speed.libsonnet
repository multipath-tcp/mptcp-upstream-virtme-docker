// Shared definitions for the scheduler perf tests at low speed, ported from
// the old '20-scheduler' tests. Used by the 'sched-*.jsonnet' files, see
// 'gen.sh' to generate the YAML files.
//
// Kernel warnings are detected by 'entrypoint.sh perf', from the VMs output.
//
// Topology: 'client' (10.0.X.2) and 'server' (10.0.X.3), with:
// - br0 (eth0): primary path, used by the initial subflow
// - br1 (eth1): secondary path, signalled by the server

local server_addr = '10.0.0.3';
local server_addr_secondary = '10.0.1.3';
local iperf_port = 5201;
local nc_port = 12345;
local netperf_port = 12865;
local mbit = 1000000;

// One path, with the rate in Mbit/s, the base RTT, and the max queuing delay
// (in ms) in the direction of the data.
local path(rate_mbit, rtt_ms, queue_ms) = {
  rate_mbit: rate_mbit,
  rtt_ms: rtt_ms,
  queue_ms: queue_ms,
};

// 'useful': when false, the secondary path is too bad to be expected to
// increase the throughput.
// 'hard': more variable results, the expectations are even more relaxed.
local profile(primary, secondary, useful=true, hard=false) = {
  primary: primary,
  secondary: secondary,
  useful: useful,
  hard: hard,
};

local profiles = {
  slow_primary: profile(path(8, 20, 20), path(50, 15, 15)),
  tiny_primary: profile(path(2, 20, 20), path(50, 15, 15)),
  fast_both: profile(path(50, 20, 20), path(50, 15, 15)),
  balanced: profile(path(29, 15, 15), path(29, 15, 15)),
  slow_near_primary: profile(path(8, 15, 15), path(50, 20, 20)),
  slow_secondary: profile(path(50, 15, 15), path(8, 20, 20)),
  very_fast: profile(path(100, 8, 32), path(100, 8, 22)),
  shallow_primary: profile(path(50, 8, 12), path(20, 20, 20)),
  high_lat_primary: profile(path(8, 60, 60), path(50, 15, 15)),
  huge_lat_primary: profile(path(8, 120, 480), path(50, 15, 15), hard=true),
  high_lat_secondary: profile(path(8, 20, 20), path(50, 60, 60)),
  huge_lat_secondary: profile(path(8, 20, 20), path(50, 120, 480), hard=true),
  bloated_primary: profile(path(8, 20, 480), path(50, 15, 15), hard=true),
  very_bloated_primary: profile(path(20, 20, 3980), path(30, 15, 15), hard=true),
  bloated_secondary: profile(path(8, 20, 20), path(50, 30, 470), hard=true),
  bloated_slow_secondary: profile(path(100, 20, 20), path(10, 30, 970), hard=true),
  very_bloated_secondary: profile(path(80, 20, 20), path(40, 30, 5970), hard=true),
  weak_secondary: profile(path(80, 20, 20), path(1, 70, 20), useful=false),
  bad_secondary: profile(path(80, 20, 20), path(1, 120, 2380), useful=false, hard=true),
  far_secondary: profile(path(80, 50, 50), path(80, 500, 2000), useful=false, hard=true),
  // the slow and far path is the one with losses, see the 'loss_*' options
  slow_far_secondary: profile(path(50, 10, 10), path(5, 120, 120)),
  slow_far_primary: profile(path(5, 120, 120), path(50, 10, 10)),
};

// netem is applied in both directions: half of the RTT each, the queue size is
// computed by the framework from 'max_latency_ms'. The losses, if any, are in
// both directions too.
local bridge(name, p, loss_pc) = {
  name: name,
  rate_mbit: p.rate_mbit,
  delay_ms: p.rtt_ms / 2,
  max_latency_ms: p.rtt_ms / 2 + p.queue_ms,
} + (if loss_pc != null then { loss_pc: loss_pc } else {});

local defaults = {
  profile: 'slow_primary',
  duration_s: 30,
  upload: false,  // download by default: the server is the sender
  parallel: 1,
  limit_mode: 'none',  // 'server' (iperf3 -b), or 'client' (pv)
  limit_bw: null,  // in Mbit/s
  burst_ms: null,  // with limit_mode 'server' only
  rmem: null,  // receiver max tcp_rmem, in KB
  wmem: null,  // sender max tcp_wmem, in KB
  receiver_tcp_mem: null,
  sender_tcp_mem: null,
  // sender congestion control. Note that it cannot be set per path: MPTCP
  // sets the one from the MPTCP socket on all subflows.
  cc: null,
  backup: false,  // the secondary path is a backup one
  loss_primary: null,  // random losses on the primary path, in percent
  loss_secondary: null,  // same on the secondary path
  cpu_hog: false,  // RT processes preempting the receiver
  cpus: null,
  ratio: null,  // part of the expected throughput required
  // 'bulk': iperf3, or nc with limit_mode 'client'
  // 'rr': request/response with netperf, see 'rr_size'
  // 'bidir': both ways on the same connection with nc
  workload: 'bulk',
  rr_size: null,  // size of the responses, in bytes
};

local fmtInt(n) = std.toString(std.floor(n));

// Multi-line commands, ending with a new line to be displayed as a block
local lines(cmds) = std.join('\n', cmds) + '\n';

local sender(c) = if c.upload then 'client' else 'server';
local receiver(c) = if c.upload then 'server' else 'client';

// netperf: one for the control, one for the data
local connections(c) = if c.workload == 'rr' then 2 else c.parallel;

// Relaxed expected throughput, in bits/s: the regression checks will catch
// smaller variations.
local bound(c) =
  local p = profiles[c.profile];
  local secondary = p.useful && !c.backup;
  // a path with losses can be a lot slower: not counted
  local rate(x, loss) = if loss != null then 0 else x.rate_mbit;
  local rates = (rate(p.primary, c.loss_primary) +
                 (if secondary then rate(p.secondary, c.loss_secondary) else 0)) * mbit;
  local lat(x) = x.rtt_ms + x.queue_ms;
  local rtt = std.max(lat(p.primary), if secondary then lat(p.secondary) else 0);
  local app = if c.limit_bw != null then c.limit_bw * mbit else rates;
  // rmem ~= 2 x rcv win ~= 4 x BDP, rmem in KB
  local win = if c.rmem != null then c.rmem * 1000 * 8 * 1000 / (4 * rtt) else rates;
  std.min(rates, std.min(app, win));

local ratio(c) =
  if c.ratio != null then c.ratio
  else if profiles[c.profile].hard then 0.25
  else 0.5;

// Aggregation is only expected when the primary path is not enough.
local checkSecondary(c) =
  local p = profiles[c.profile];
  p.useful && !c.backup && bound(c) > p.primary.rate_mbit * mbit;

local waitListen(port) =
  'port=":$(printf "%04X" "' + port + '") 0A"; ' +
  'while true; do awk \'{print $2" "$4}\' /proc/net/tcp* | grep -q "${port}" && break; done';

local sysctl(name, value) = 'sysctl -qw ' + name + '="' + value + '"';

local hostSysctls(c, host) =
  local is_sender = host == sender(c);
  local tcp_mem = if is_sender then c.sender_tcp_mem else c.receiver_tcp_mem;
  std.prune([
    if !is_sender && c.rmem != null then
      sysctl('net.ipv4.tcp_rmem', '4096 ' + std.min(131072, c.rmem * 1000) + ' ' + c.rmem * 1000),
    if is_sender && c.wmem != null then
      sysctl('net.ipv4.tcp_wmem', '4096 ' + std.min(16384, c.wmem * 1000) + ' ' + c.wmem * 1000),
    if tcp_mem != null then sysctl('net.ipv4.tcp_mem', tcp_mem),
    // both send with 'bidir'
    if (is_sender || c.workload == 'bidir') && c.cc != null then
      sysctl('net.ipv4.tcp_congestion_control', c.cc),
  ]);

local sysctlsStep(c) =
  local cmds = { [h]: hostSysctls(c, h) for h in ['client', 'server'] };
  if std.length(cmds.client) + std.length(cmds.server) == 0 then []
  else [{ name: 'sysctls' } + {
    [h]: lines(cmds[h])
    for h in ['client', 'server']
    if std.length(cmds[h]) > 0
  }];

local endpointsStep(c) = [{
  name: 'mptcp endpoints',
  server: 'ip mptcp endpoint add ' + server_addr_secondary + ' dev eth1 signal' +
          (if c.backup then ' backup' else ''),
  client: 'ip mptcp limits set subflows 2 add_addr_accepted 2',
}];

// Busy for 40ms every 50ms, on all CPUs, with a RT priority.
local cpuHogStep(c) =
  if !c.cpu_hog then []
  else [{
    name: 'cpu hog',
    [receiver(c)]: 'stress-ng --cpu 0 --cpu-load 80 --cpu-load-slice 40 ' +
                   '--sched rr --sched-prio 90 --timeout ' + (c.duration_s + 30) + ' &>/dev/null & disown',
  }];

local serverStep(c) =
  if c.workload == 'rr' then [{
    name: 'netperf server',
    server: lines(['mptcpize run netserver -4 >/dev/null', waitListen(netperf_port)]),
    timeout_s: 10,
  }]
  // nc sends data to the client too: also used with 'bidir'
  else if c.limit_mode == 'client' || c.workload == 'bidir' then [{
    name: 'nc server',
    server: lines([
      'for i in $(seq 1 ' + c.parallel + '); do',
      // all addresses: the secondary one is used by the additional subflow
      '  mptcpize run nc -kl $((' + nc_port + ' + i)) </dev/zero >/dev/null & disown',
      'done',
      waitListen('$((' + nc_port + ' + ' + c.parallel + '))'),
    ]),
    timeout_s: 10,
  }]
  else [{
    name: 'iperf3 server',
    server: lines(['iperf3 -s -D', waitListen(iperf_port)]),
    timeout_s: 10,
  }];

// Snapshot of the connections, in the middle of the transfer.
// Background jobs are disowned: the shell should not report them later.
local ssStep(c) = [{
  name: 'ss',
  all: '(sleep ' + std.floor(c.duration_s / 2) + '; ss -Mtni > "${RESULTS_DIR}/artifacts/ss_${HOSTNAME}.txt") & disown',
}];

local iperfArgs(c) =
  local burst = c.burst_ms != null && c.burst_ms > 0;
  std.join(' ', std.prune([
    'iperf3 -c',
    server_addr,
    '--mptcp -Z --json',
    '-t ' + c.duration_s,
    if !c.upload then '-R',
    if c.parallel > 1 then '-P ' + c.parallel,
    // per stream
    if c.limit_mode == 'server' then '-b ' + fmtInt(c.limit_bw * mbit / c.parallel),
    if c.limit_mode == 'server' && burst then '-l 8000 --pacing-timer ' + c.burst_ms * 1000,
  ]));

// Values from netperf, also used for the regressions, latencies in us
local netperfKeys = 'TRANSACTION_RATE,MEAN_LATENCY,P50_LATENCY,P90_LATENCY,P99_LATENCY';

local clientStep(c) =
  local timeout = c.duration_s + 60;
  local artifact(f) = '"${RESULTS_DIR}/artifacts/' + f + '"';
  if c.workload == 'rr' then [{
    name: 'netperf client',
    client: lines([
      // one transaction at a time, without Nagle: a request of 1 byte, and
      // the response
      'mptcpize run netperf -H ' + server_addr + ' -t TCP_RR -l ' + c.duration_s +
      ' -j -P 0 -- -D -r 1,' + c.rr_size + ' -k ' + netperfKeys + ' > ' + artifact('netperf.txt'),
      'rc=$?',
      'jq -Rn \'[inputs | split("=") | {(.[0]): (.[1] | tonumber)}] | add\' ' +
      artifact('netperf.txt') + ' > ' + artifact('netperf.json'),
      '[ "${rc}" = 0 ]',
    ]),
    timeout_s: timeout,
    dstat_only: 'step',
  }]
  else if c.workload == 'bidir' then [{
    name: 'nc client',
    client: lines([
      'timeout ' + c.duration_s + ' mptcpize run nc ' + server_addr + ' $((' + nc_port + ' + 1)) ' +
      '</dev/zero >/dev/null',
      // stopped by the timeout, as expected
      '[ "$?" = 124 ]',
    ]),
    timeout_s: timeout,
    dstat_only: 'step',
  }]
  else if c.limit_mode == 'client' then [{
    name: 'nc client',
    client: lines([
      '(for i in $(seq 1 ' + c.parallel + '); do',
      '  timeout ' + c.duration_s + ' mptcpize run nc ' + server_addr + ' $((' + nc_port + ' + i)) |',
      '    pv -q -L ' + fmtInt(c.limit_bw * mbit / 8 / c.parallel) + ' >/dev/null &',
      'done',
      'wait)',
    ]),
    timeout_s: timeout,
    dstat_only: 'step',
  }]
  else [{
    name: 'iperf3 client',
    client: iperfArgs(c) + ' > "${RESULTS_DIR}/artifacts/iperf_cli.json"',
    timeout_s: timeout,
    dstat_only: 'step',
  }];

local jqMean(host, iface) =
  '"$(jq -r \'.' + host + '["net/' + iface + ':recv"].mean | round\' dstat.json || echo 0)"';

local validation(c) =
  local rx = receiver(c);
  local rr = c.workload == 'rr';
  local iperf = c.workload == 'bulk' && c.limit_mode != 'client';
  // with 'bidir', the expected throughput is the same in both directions
  local rxs = if c.workload == 'bidir' then ['client', 'server'] else [rx];
  [{
    name: 'transfer',
    run: lines(std.prune([
      'set -x',
      if iperf then '[ -s artifacts/iperf_cli.json ]',
      if rr then 'jq -e \'.TRANSACTION_RATE > 0\' artifacts/netperf.json',
      'cd stats',
      '[ "$(jq -r \'.host.time.diff\' dstat.json || echo 0)" -ge ' + fmtInt(c.duration_s * 0.6) + ' ]',
      '[ "$(jq -r \'.host.time.diff\' dstat.json || echo 0)" -le ' + (c.duration_s + 5) + ' ]',
    ]) + (if rr then [] else [
            '[ ' + jqMean(h, 'total') + ' -ge ' + fmtInt(ratio(c) * bound(c)) + ' ]'
            for h in rxs
          ] + [
            '[ ' + jqMean(h, 'eth1') + ' -ge 100000 ]'
            for h in rxs
            if checkSecondary(c)
          ])),
  }] + (if c.backup then [{
          name: 'backup',
          run: lines([
            'cd stats',
            'total=' + jqMean(rx, 'total'),
            'backup=' + jqMean(rx, 'eth1'),
            '[ $((backup * 10)) -lt "${total}" ]',
          ]),
        }] else []) + (if c.cc != null then [{
                         name: 'congestion control',
                         run: "grep -qw '" + c.cc + "' artifacts/ss_" + sender(c) + '.txt',
                       }] else []) + [{
    // the client creates the additional subflows, one per MPTCP connection
    name: 'subflows',
    run: lines([
      'set -x',
      '[ "$(jq -r \'.kernel.MPTcpExtMPJoinSynAckRx\' stats/client/post/nstat || echo 0)" -ge ' +
      connections(c) + ' ]',
    ]),
  }];

// A counter from nstat, after the transfer: more is worse. Small differences
// are ignored, they are often at 0, or vary a lot. Secondary checks: not to
// make the throughput ones less sensitive.
local counter(name, host, key, min_diff) = {
  name: name,
  file: 'stats/' + host + '/post/nstat',
  json_field: ['kernel', key],
  direction: 'higher',
  min_diff: min_diff,
  min_diff_pc: 50,
  holm_bonferroni: false,
};

// One direction of the data: from 'tx' to 'rx'
local counters(tx, rx, prefix) = [
  // MPTCP-level timeouts: the data was stuck on a subflow
  counter(prefix + 'MPTCP retransmissions', tx, 'MPTcpExtMPTCPRetrans', 20),
  // e.g. retransmissions, or reinjections, arriving too late
  counter(prefix + 'Duplicated data', rx, 'MPTcpExtDuplicateData', 100),
  // data sent beyond the window: the sender should not do that
  counter(prefix + 'Data beyond the window', rx, 'MPTcpExtNoDSSInWindow', 10),
  // same at the TCP level, e.g. a subflow used while the window is full
  counter(prefix + 'Zero window drops', rx, 'TcpExtTCPZeroWindowDrop', 5),
];

local regression(c) =
  local rx = receiver(c);
  local reg(name, host, iface) = {
    name: name,
    file: 'stats/dstat.json',
    json_field: [host, 'net/' + iface + ':recv', 'mean'],
  };
  local paths(prefix, host) = [
    reg(prefix + ' primary path', host, 'eth0'),
    // a backup path should stay idle: ignore a few packets, e.g. one
    // retransmission, 100 kbit/s on average is too much
    reg(prefix + ' secondary path', host, 'eth1') +
    (if c.backup then { direction: 'higher', min_diff: 100000 } else {}),
    reg(prefix + ' total', host, 'total'),
  ];
  local netperf(name, key, direction) = {
    name: name,
    file: 'artifacts/netperf.json',
    json_field: [key],
    direction: direction,
  };
  {
    // default alpha: 0.05
    global: {
      history_max_n: 50,
      // throughputs: lower values are marked as regressions
      direction: 'lower',
      // smaller changes are not relevant, even if significant
      min_diff_pc: 1,
    },
    steps: if c.workload == 'rr' then [
      netperf('Transaction rate', 'TRANSACTION_RATE', 'lower'),
      netperf('P90 latency', 'P90_LATENCY', 'higher'),
      netperf('P99 latency', 'P99_LATENCY', 'higher'),
    ] + counters(sender(c), rx, '')
    else if c.workload == 'bidir' then
      paths('Download', 'client') + paths('Upload', 'server') +
      counters('server', 'client', 'Download: ') + counters('client', 'server', 'Upload: ')
    else paths('Receiver', rx) + (if c.limit_mode != 'client' then [{
                                    name: 'iperf3 received',
                                    file: 'artifacts/iperf_cli.json',
                                    json_field: ['end', 'sum_received', 'bits_per_second'],
                                  }] else []) + counters(sender(c), rx, ''),
  };

{
  profiles: profiles,

  // cfg: see 'defaults' above
  test(name, cfg)::
    local c = defaults + cfg;
    local p = profiles[c.profile];
    {
      name: name,
      bridges: [
        bridge('br0', p.primary, c.loss_primary),
        bridge('br1', p.secondary, c.loss_secondary),
      ],
      steps: endpointsStep(c) + sysctlsStep(c) + cpuHogStep(c) + serverStep(c) +
             ssStep(c) + clientStep(c),
      validation: validation(c),
      regression: regression(c),
    } + (if c.cpus != null then { cpus: c.cpus } else {}),

  suite(name, tests):: {
    name: name,
    global: {
      timeout_s: 900,
      bridges_hw_accel: false,
      dstat: {
        offset_start: 2,
        offset_end: 1,
      },
      stats: {
        pre: [
          { name: 'nstat', run: 'nstat -n' },
        ],
        post: [
          { name: 'nstat', run: 'nstat -jz' },
          { name: 'mptcp', run: 'ip -j mptcp endpoint show' },
        ],
      },
    },
    tests: tests,
  },
}
