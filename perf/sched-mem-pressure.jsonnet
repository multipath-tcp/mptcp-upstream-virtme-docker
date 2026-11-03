// From the old 39-sched_mem_pressure and 40-bufopti_v2 tests: under memory
// pressure. Only check the transfer is not stalled.
//
// The VMs have 2 CPUs: the memory reserved per CPU (net.core.mem_pcpu_rsv) is
// accounted as allocated, 1 MB each. With many CPUs, that can be above the low
// limit of tcp_mem, and the memory pressure might then never stop: the results
// would depend on the number of CPUs of the host.
local lib = import 'sched-low-speed.libsonnet';

local cpus = 2;

lib.suite('sched-mem-pressure', [
  lib.test('bloated_slow_secondary receiver_tcp_mem parallel=' + p, {
    profile: 'bloated_slow_secondary',
    duration_s: 60,
    parallel: p,
    rmem: 6000,
    receiver_tcp_mem: '1000 2000 10000',
    ratio: 0.1,
    cpus: cpus,
  })
  for p in [1, 16, 99]
] + [
  lib.test(prof + ' both_tcp_mem parallel=' + p, {
    profile: prof,
    parallel: p,
    rmem: 6000,
    wmem: 6000,
    sender_tcp_mem: '30000 40000 50000',
    receiver_tcp_mem: '10000 15000 20000',
    ratio: 0.1,
    cpus: cpus,
  })
  for p in [1, 10]
  for prof in ['very_bloated_primary', 'slow_primary', 'balanced']
])
