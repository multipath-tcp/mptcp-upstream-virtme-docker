// From the old 38-sched_delayed_ack test: the receiver is preempted by RT
// processes, with a single CPU.
local lib = import 'sched-low-speed.libsonnet';

lib.suite('sched-cpu-preempt', [
  lib.test('shallow_primary' + (if hog then ' cpu_hog' else ''), {
    profile: 'shallow_primary',
    cpus: 1,
    cpu_hog: hog,
    ratio: if hog then 0.1 else null,
  })
  for hog in [false, true]
])
