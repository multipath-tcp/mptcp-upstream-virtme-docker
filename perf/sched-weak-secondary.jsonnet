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
  })
  for backup in [false, true]
  for prof in profiles
])
