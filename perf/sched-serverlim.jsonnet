// From the old 29-sched_serverlim, 32-sched_serverlim_ref,
// 33-sched_serverlim_bckdel_smallq and 37-sched_serverlim_starv tests: limited
// by the sender application.
local lib = import 'sched-low-speed.libsonnet';

local profiles = ['slow_primary', 'balanced', 'huge_lat_primary', 'slow_secondary'];

lib.suite('sched-serverlim', [
  lib.test(prof + ' bw=' + bw + ' burst=' + burst, {
    profile: prof,
    limit_mode: 'server',
    limit_bw: bw,
    burst_ms: burst,
  })
  for bw in [5, 10, 50]
  for burst in [10, 250]
  for prof in profiles
] + [
  lib.test(prof + ' bw=' + bw + ' burst=10 wmem=6000', {
    profile: prof,
    limit_mode: 'server',
    limit_bw: bw,
    burst_ms: 10,
    wmem: 6000,
  })
  for bw in [10, 50]
  for prof in ['slow_primary', 'balanced']
])
