// From the old 31-sched_clientlim test: limited by the receiver application.
local lib = import 'sched-low-speed.libsonnet';

lib.suite('sched-clientlim', [
  lib.test(prof + ' bw=' + bw, {
    profile: prof,
    limit_mode: 'client',
    limit_bw: bw,
  })
  for bw in [5, 10, 50]
  for prof in ['slow_primary', 'balanced', 'huge_lat_primary', 'slow_secondary']
])
