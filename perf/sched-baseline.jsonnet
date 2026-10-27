// From the old 28-sched and 36-sched_baseline tests: no limits.
local lib = import 'sched-low-speed.libsonnet';

local profiles = [
  'slow_primary',
  'tiny_primary',
  'fast_both',
  'balanced',
  'slow_near_primary',
  'slow_secondary',
  'very_fast',
  'shallow_primary',
  'high_lat_primary',
  'huge_lat_primary',
  'high_lat_secondary',
  'huge_lat_secondary',
  'bloated_primary',
  'bloated_secondary',
];

lib.suite('sched-baseline', [
  lib.test(prof, { profile: prof })
  for prof in profiles
] + [
  lib.test(prof + ' upload', { profile: prof, upload: true })
  for prof in ['slow_primary', 'balanced']
] + [
  lib.test(prof + ' parallel=4', { profile: prof, parallel: 4 })
  for prof in ['slow_primary', 'balanced']
])
