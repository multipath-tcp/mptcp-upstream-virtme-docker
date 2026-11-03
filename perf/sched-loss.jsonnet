// Random losses on the slow path, in both directions, the other path being
// clean: similar to a fast Wi-Fi network, and a slow cellular one with a
// higher latency. What is lost on the slow path holds back the rest of the
// data, until it is retransmitted.
local lib = import 'sched-low-speed.libsonnet';

lib.suite('sched-loss', [
  lib.test(prof + ' loss=' + loss + (if cc != null then ' ' + cc else ''), {
    profile: prof,
    loss_primary: if prof == 'slow_far_primary' then std.parseJson(loss) else null,
    loss_secondary: if prof == 'slow_far_secondary' then std.parseJson(loss) else null,
    cc: cc,
  })
  for cc in [null, 'bbr']
  for prof in ['slow_far_secondary', 'slow_far_primary']
  // mild, frequent, and severe losses; strings to have them as is in the names
  for loss in ['0.1', '1', '5']
])
