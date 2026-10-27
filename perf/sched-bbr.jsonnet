// From the old 41-bbr test: BBR used by the sender. The old test only used it
// on the secondary path, not possible with MPTCP upstream.
local lib = import 'sched-low-speed.libsonnet';

local profiles = [
  'slow_primary',
  'balanced',
  'slow_near_primary',
  'high_lat_primary',
  'huge_lat_primary',
  'high_lat_secondary',
  'huge_lat_secondary',
  'slow_secondary',
  'very_fast',
  'bloated_secondary',
  'bloated_slow_secondary',
  'very_bloated_secondary',
  'bad_secondary',
  'far_secondary',
];

lib.suite('sched-bbr', [
  lib.test(prof + ' bbr', { profile: prof, cc: 'bbr' })
  for prof in profiles
])
