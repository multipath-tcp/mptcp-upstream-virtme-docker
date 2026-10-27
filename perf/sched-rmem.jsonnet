// From the old 30-sched_rmemlim test: limited by the receive buffer.
local lib = import 'sched-low-speed.libsonnet';

lib.suite('sched-rmem', [
  lib.test(prof + ' rmem=' + rmem, { profile: prof, rmem: rmem })
  for rmem in [200, 800, 2000, 6000]
  for prof in ['slow_primary', 'balanced', 'huge_lat_primary', 'bloated_primary']
])
