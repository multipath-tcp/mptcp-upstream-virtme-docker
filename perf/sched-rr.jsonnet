// Request/response with netperf, one transaction at a time: a request of 1
// byte, and a response of a given size. The application limits the transfer:
// what matters is the latency of each transaction. The end of a response stuck
// on a slow path delays the next request.
local lib = import 'sched-low-speed.libsonnet';

local sizes = { '1K': 1024, '64K': 65536, '1M': 1048576 };

local test(prof, size, cc=null) =
  lib.test(prof + ' size=' + size + (if cc != null then ' ' + cc else ''), {
    profile: prof,
    workload: 'rr',
    rr_size: sizes[size],
    cc: cc,
  });

lib.suite('sched-rr', [
  test(prof, size)
  for prof in ['balanced', 'slow_secondary', 'weak_secondary']
  for size in ['1K', '64K', '1M']
] + [
  // BBR sees the idle periods between the responses
  test(prof, '1M', 'bbr')
  for prof in ['slow_secondary', 'weak_secondary']
])
