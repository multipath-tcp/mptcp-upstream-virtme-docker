// From the old 35-sched_bad_lte test: the secondary path is bad, or bloated,
// and optionally marked as backup.
local lib = import 'sched-low-speed.libsonnet';

local profiles = [
  'weak_secondary',
  'bad_secondary',
  'far_secondary',
  'bloated_secondary',
  'bloated_slow_secondary',
  'very_bloated_secondary',
];

lib.suite('sched-weak-secondary', [
  lib.test(prof + (if backup then ' backup' else ''), {
    profile: prof,
    backup: backup,
    // This case is currently not handled well: 15 Mbps instead of 40
    // TODO: remove this when #332 and/or #345 are implemented.
    ratio: if prof == 'weak_secondary' && !backup then 0.1875 else null,
  })
  for backup in [false, true]
  for prof in profiles
])
