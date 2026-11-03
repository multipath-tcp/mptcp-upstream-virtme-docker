// Both ways at the same time, on the same MPTCP connection, with nc: in each
// direction, the data and the acknowledgements of the other direction share the
// same queues.
local lib = import 'sched-low-speed.libsonnet';

lib.suite('sched-bidir', [
  lib.test(prof + ' bidir' + (if cc != null then ' ' + cc else ''), {
    profile: prof,
    workload: 'bidir',
    cc: cc,
    // With CUBIC, the acknowledgements wait behind a full queue of data in the
    // other direction: around 12 Mbit/s instead of 58.
    ratio: if prof == 'bloated_secondary' && cc == null then 0.1 else null,
  })
  for cc in [null, 'bbr']
  for prof in ['balanced', 'slow_primary', 'bloated_secondary']
])
