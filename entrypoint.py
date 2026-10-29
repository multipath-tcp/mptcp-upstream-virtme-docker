# SPDX-License-Identifier: GPL-2.0

"""
Class for the entrypoint.sh script
"""

import copy
import filecmp
import json
import logging
import math
import os
import re
import shlex
import shutil
import statistics
import tempfile
import time

from pexpect import TIMEOUT
from scipy import stats

import hosts

logger = logging.getLogger(__name__)

# Same as kmemleak_scan() in entrypoint.sh
KMEMLEAK_SCAN = """p=/sys/kernel/debug/kmemleak; f={file}
if [ -e "${{p}}" ]; then
    echo "Starting KMemleak scan"
    echo scan > "${{p}}"
    sleep 5 # grace period of 5 sec
    # second scan often surfaces issues the first scan missed
    echo scan > "${{p}}"
    cat "${{p}}" > "${{f}}"
    if [ -s "${{f}}" ]; then
        echo "Potential memory leak found:"
        cat "${{f}}"
    else
        rm -f "${{f}}"
    fi
fi"""


# z-score (or standard score) is the number of standard deviations from the mean
OUTLIER_Z = 5


def outliers(values):
    median = statistics.median(values)
    mad = statistics.median(abs(v - median) for v in values)
    if mad == 0:
        return median, []

    z_scores = [0.6745 * (v - median) / mad for v in values]
    return median, [(i, z) for i, z in enumerate(z_scores) if abs(z) > OUTLIER_Z]


# Holm-Bonferroni: adjusted p-values, to compare with alpha when checking
# multiple values at once, not to increase the risk of false positives
def holm(p_values):
    m = len(p_values)
    adjusted = [0.0] * m
    running = 0.0
    for rank, i in enumerate(sorted(range(m), key=lambda i: p_values[i])):
        running = max(running, min(1.0, (m - rank) * p_values[i]))
        adjusted[i] = running
    return adjusted


class Entrypoint:
    def __init__(
        self,
        cmd,
        mode,
        script,
        log_dir,
        reg_dir,
        reg_min_history,
        reg_alpha,
        reg_exclude,
        reg_only,
        reg_reset,
        validation_only,
    ):
        self.cmd = cmd
        self.mode = mode
        self.script = script
        self.log_dir_parent = os.path.realpath(log_dir)
        self.reg_dir_parent = None if reg_dir is None else os.path.realpath(reg_dir)
        self.reg_min_history = reg_min_history
        self.reg_alpha = reg_alpha
        self.reg_exclude = reg_exclude
        self.reg_only = reg_only
        self.reg_reset = reg_reset
        self.validation_only = validation_only

        self.outliers = []
        self.reuse = reg_only or validation_only
        self.prev_results = {}
        if self.reuse:
            with open(os.path.join(self.log_dir_parent, "perf.json")) as f:
                self.prev_results = json.load(f)

        self.hosts = {}
        self.git_sha = self.cmd.output("git rev-parse HEAD", fatal=False)
        self.stopped = False
        self.interrupted = False
        self.graceful = False

        logger.info(f"Env ({self.git_sha}) in {self.mode} mode")

    # one dir per test, not to mix stats and artifacts from different tests
    def _set_test_dirs(self, id, name):
        slug = re.sub(r"\W", "_", name)
        self.log_dir = os.path.join(self.suite_dir, f"{id:02d}-{slug}")
        os.makedirs(os.path.join(self.log_dir, "artifacts"), exist_ok=True)
        os.makedirs(os.path.join(self.log_dir, "stats"), exist_ok=True)

    # one dir per suite
    def _set_dirs(self, name):
        self.suite_dir = os.path.join(self.log_dir_parent, name)
        if not self.reuse:
            shutil.rmtree(self.suite_dir, ignore_errors=True)
        os.makedirs(self.suite_dir, exist_ok=True)

        if self.reg_dir_parent is not None:
            self.reg_dir = os.path.join(self.reg_dir_parent, name)
            os.makedirs(self.reg_dir, exist_ok=True)
        else:
            self.reg_dir = None

    def build(self):
        logger.info(f"Building kernel ({self.mode})")
        cmd = f"{self.script} build {self.mode}"
        self.cmd.call(cmd)

    def _new_vm(self, hostname, env, timeout):
        if int(self.cmd.verbosity()) > 1:
            log = None
        else:
            # the log will be closed during the vm.stop() step
            log = open(os.path.join(self.log_dir, f"{hostname}.log"), "a")  # noqa: SIM115

        vm = hosts.VM(
            self.mode,
            self.script,
            log,
            self.cmd.lvl,
            self.cmd.dry_run,
            "root",
            hostname,
            env,
            timeout,
        )
        self.hosts[hostname] = vm

        return vm

    def _kmemleak_scan(self, name, host):
        file = os.path.join(self.log_dir, f"{name}_kmemleak.txt")
        cmd = KMEMLEAK_SCAN.format(file=shlex.quote(file))
        host.cmd_wait(f"{{\n{cmd}\n}}", ignore_timeout=True, timeout=600)

    # graceful: the current test is completed, not the next ones
    def interrupt(self, graceful=False):
        if graceful and self.interrupted:
            return
        self.interrupted = True
        self.graceful = graceful
        if not graceful:
            self.stop(kmemleak=False)

    # kmemleak: not to wait for the scan, e.g. when interrupted
    def stop(self, kmemleak=True):
        if self.stopped:
            return
        self.stopped = True

        logger.info("Stopping VMs")

        for name in self.hosts:
            host = self.hosts[name]
            if kmemleak:
                self._kmemleak_scan(name, host)
            host.stop()

    def _get_reg_dir(self, name):
        return os.path.join(self.reg_dir, re.sub(r"\W", "_", name))

    # None if the value cannot be read, e.g. missing JSON field after an error
    def _get_info(self, file_path, json_field):
        try:
            with open(file_path) as f:
                if json_field:
                    info = json.load(f)
                    for field in json_field:
                        if field.isdigit():
                            field = int(field)
                        info = info[field]
                else:
                    info = f.readline().strip("\n")

            return float(info)
        except (OSError, ValueError, LookupError, TypeError) as e:
            logger.warning(f"{file_path}: {json_field}: cannot get the value: {e!r}")
            return None

    # results kept, but not used as reference for the next regression checks
    def _mark_skip(self, path, reason):
        with open(os.path.join(path, "skip"), "a") as f:
            print(reason, file=f)

    def _mark_reg(self, latest, global_name, name, check_name, msg, msgs):
        output = f"{check_name}: {msg}"
        msgs.append(output)
        logger.warning(f"Regression: {output}")

        self._mark_skip(latest, f"regression: {check_name}")
        with open(os.path.join(self.log_dir, "regs.txt"), "a") as f:
            print(f"{global_name}: {name}: {output}", file=f)

        return True

    def _mark_improv(self, global_name, name, check_name, msg, improvs):
        output = f"{check_name}: {msg}"
        improvs.append(output)
        logger.info(f"Improvement: {output}")

        with open(os.path.join(self.log_dir, "improvement.txt"), "a") as f:
            print(f"{global_name}: {name}: {output}", file=f)

    def _mark_outlier(self, global_name, name, check_name, msg, outs):
        output = f"{check_name}: {msg}"
        outs.append(output)
        self.outliers.append(f"{global_name}: {name}: {output}")
        logger.warning(f"Outlier in the history: {output}")

        with open(os.path.join(self.log_dir, "outliers.txt"), "a") as f:
            print(f"{global_name}: {name}: {output}", file=f)

        return output

    def _new_outliers(self, dir_path, last, global_name, name, odd):
        prev_keys = None  # all new if never checked before
        for prev in range(last - 1, -1, -1):
            path = os.path.join(dir_path, str(prev), "outliers")
            if os.path.isfile(path):
                with open(path) as f:
                    prev_keys = {line.rstrip("\n") for line in f}
                break

        # even if empty: for the next run
        with open(os.path.join(dir_path, str(last), "outliers"), "w") as f:
            for key in odd:
                print(key, file=f)

        new = [key for key in odd if prev_keys is None or key not in prev_keys]
        if new:
            with open(os.path.join(self.log_dir, "outliers_new.txt"), "w") as f:
                for key in new:
                    print(f"{global_name}: {name}: {odd[key]}", file=f)

    def regression(self, config, global_name, name, id, total, msgs, improvs, outs):
        reg = False
        if self.reg_dir is None or self.cmd.dry_run or "regression" not in config:
            return reg

        logger.info(f"Checking regression {id}/{total}: {name}")

        regression = config["regression"]

        global_config = regression.get("global", {})
        dir_path = self._get_reg_dir(name)
        latest = os.path.join(dir_path, "latest")
        last = int(os.path.basename(os.path.realpath(latest)))

        if last == 0:
            logger.info("Nothing to compare: first time")

        # set by --reg-reset, e.g. after an accepted change in behaviour
        reset_since = 0
        reset_file = os.path.join(dir_path, "history_since")
        if os.path.isfile(reset_file):
            with open(reset_file) as f:
                reset_since = int(f.readline())

        tested = []
        odd_outputs = {}  # '<check>: run <N>': the rest changes with the history
        for step in regression["steps"]:
            check = global_config | step
            check_name = check["name"]
            file = check["file"]

            latest_file = os.path.join(latest, file)
            if not os.path.isfile(latest_file):
                msg = f"{file} is not available in latest"
                reg = self._mark_reg(latest, global_name, name, check_name, msg, msgs)
                continue

            json_field = check.get("json_field", None)
            last_res = self._get_info(latest_file, json_field)
            if last_res is None:
                msg = f"{file}: cannot get the value from latest"
                reg = self._mark_reg(latest, global_name, name, check_name, msg, msgs)
                continue

            if self.reg_alpha is not None:
                alpha = self.reg_alpha
            else:
                alpha = float(check.get("alpha", 0.05))
            if not 0 < alpha < 1:
                raise ValueError(f"{name}: {check_name}: alpha must be between 0 and 1")
            history_max_n = int(check.get("history_max_n", 0))
            history_since = max(int(check.get("history_since", 0)), reset_since)
            direction = check.get("direction", "different")

            prev = last
            prev_results = []
            prev_runs = []
            while prev > history_since and (
                history_max_n == 0 or len(prev_results) < history_max_n
            ):
                prev -= 1

                prev_dir = os.path.join(dir_path, str(prev))
                file_path = os.path.join(prev_dir, file)
                if (
                    not os.path.isdir(prev_dir)
                    or os.path.isfile(os.path.join(prev_dir, "skip"))
                    or not os.path.isfile(file_path)
                ):
                    logger.debug(f"skip: {prev_dir}")
                    continue

                prev_res = self._get_info(file_path, json_field)
                if prev_res is not None:
                    prev_results.append(prev_res)
                    prev_runs.append(prev)

            if len(prev_results) < self.reg_min_history:
                logger.info(
                    f"{name}: {check_name}: need at least "
                    f"{self.reg_min_history} previous measurements"
                )
                continue

            mean = statistics.mean(prev_results)
            stdev = statistics.stdev(prev_results, mean)
            n = len(prev_results)
            if stdev == 0:
                t = 0 if last_res == mean else math.copysign(math.inf, last_res - mean)
            else:
                # prediction interval: does this new value belong to the
                # history? Not ttest_1samp(): it checks the mean of the history
                # instead, with a margin getting narrower with more history.
                t = (last_res - mean) / (stdev * math.sqrt(1 + 1 / n))
            p_lower = stats.t.cdf(t, n - 1)
            p_higher = stats.t.sf(t, n - 1)
            p_value = 2 * min(p_lower, p_higher)

            # one-sided test when only one way is a regression: more power
            if direction == "lower":
                p_reg = p_lower
            elif direction == "higher":
                p_reg = p_higher
            else:
                p_reg = p_value

            median, odd = outliers(prev_results)
            for i, z in odd:
                msg = (
                    f"run {prev_runs[i]}: got {prev_results[i]}, median {median}; "
                    f"modified z-score {z:.3g}"
                )
                output = self._mark_outlier(global_name, name, check_name, msg, outs)
                odd_outputs[f"{check_name}: run {prev_runs[i]}"] = output

            tested.append(
                {
                    "name": check_name,
                    "alpha": alpha,
                    "msg": f"got {last_res}, had {mean}",
                    "p_reg": p_reg,
                    "p_value": p_value,
                }
            )

        # multiple checks per test: the more checks, the more false positives
        use_holm = regression.get("holm_bonferroni", True)
        for key in ("p_reg", "p_value"):
            p_values = [c[key] for c in tested]
            adjusted = holm(p_values) if use_holm else p_values
            for c, adj in zip(tested, adjusted, strict=True):
                c[f"{key}_adj"] = adj

        for c in tested:
            check_name, alpha = c["name"], c["alpha"]
            if c["p_reg_adj"] < alpha:
                msg = (
                    f"{c['msg']}; p-value {c['p_reg']:.6g}, "
                    f"adjusted {c['p_reg_adj']:.6g} is below alpha {alpha:.6g}"
                )
                reg = self._mark_reg(latest, global_name, name, check_name, msg, msgs)
                continue

            # the other way, with a two-sided test not to report small changes
            if c["p_value_adj"] < alpha:
                msg = (
                    f"{c['msg']}; p-value {c['p_value']:.6g}, "
                    f"adjusted {c['p_value_adj']:.6g} is below alpha {alpha:.6g}"
                )
                self._mark_improv(global_name, name, check_name, msg, improvs)
                continue

            logger.info(
                f"{name}: {check_name}: no regression ({c['msg']}, "
                f"p-value {c['p_reg']:.6g}, adjusted {c['p_reg_adj']:.6g})"
            )

        self._new_outliers(dir_path, last, global_name, name, odd_outputs)

        return reg

    # same ID as before, just in case it changes
    def _prev_suite_id(self, global_name, tests_id):
        for suite_id in self.prev_results:
            # e.g. 01-name
            if suite_id.split("-", 1)[-1] == global_name:
                return suite_id

        return f"{tests_id:02d}-{global_name}"

    # detect previous errors: not to check something invalid
    def _prev_result(self, global_name_n, name_n, msgs):
        for result in self.prev_results.get(global_name_n, {}).values():
            if result["name"] != name_n:
                continue

            comment = result.get("comment", "")
            for prefix, status in (
                ("error: ", (True, False)),
                ("validation: ", (False, True)),
            ):
                if comment.startswith(prefix):
                    msgs.append(comment.removeprefix(prefix))
                    return status
            return False, False

        msgs.append("no previous results")
        return True, False

    # remove what was produced by the previous regression check
    def _reset_regression(self, name, msgs):
        latest = os.path.join(self._get_reg_dir(name), "latest")
        dstat = os.path.join("stats", "dstat.json")
        try:
            same = filecmp.cmp(
                os.path.join(latest, dstat),
                os.path.join(self.log_dir, dstat),
                shallow=False,
            )
        except OSError:
            same = False
        # safety check looking at dstat.json
        if not same:
            msgs.append(f"{latest}: not the results from the previous run")
            return True

        for f in ("regs.txt", "improvement.txt", "outliers.txt", "outliers_new.txt"):
            path = os.path.join(self.log_dir, f)
            if os.path.isfile(path):
                os.remove(path)

        self._remove_skip_reasons(latest, "regression: ")

        return False

    # e.g. to check again: the other reasons are kept
    def _remove_skip_reasons(self, path, prefix):
        skip = os.path.join(path, "skip")
        if not os.path.isfile(skip):
            return

        with open(skip) as f:
            reasons = [r for r in f if not r.startswith(prefix)]
        if reasons:
            with open(skip, "w") as f:
                f.writelines(reasons)
        else:
            os.remove(skip)

    def _dstat_window_file(self):
        return os.path.join(self.log_dir, "stats", "dstat_window.json")

    # the dstat window is set while running the steps: needed to re-validate
    def _save_dstat_window(self, config):
        dstat = config.get("dstat", {})
        window = {k: time.mktime(dstat[k]) for k in ("start", "end") if k in dstat}
        with open(self._dstat_window_file(), "w") as f:
            json.dump(window, f)

    def _load_dstat_window(self, config, msgs):
        try:
            with open(self._dstat_window_file()) as f:
                window = json.load(f)
        except FileNotFoundError:
            msgs.append("no saved dstat window (older run?): a full run is needed")
            return True
        except (OSError, ValueError) as e:
            msgs.append(f"cannot read the saved dstat window: {e}")
            return True

        dstat = config.setdefault("dstat", {})
        for k, v in window.items():
            dstat[k] = time.localtime(v)

        return False

    # with --validation-only: update the latest results, not adding new ones
    def _update_results(self, name, err):
        latest = os.path.join(self._get_reg_dir(name), "latest")
        stats = os.path.join(latest, "stats")
        shutil.rmtree(stats)
        shutil.copytree(os.path.join(self.log_dir, "stats"), stats)

        self._remove_skip_reasons(latest, "validation failed")
        if err:
            self._mark_skip(latest, "validation failed")

    def _save_results(self, name, err):
        if self.reg_dir is None or self.cmd.dry_run:
            logger.warning("Regressions are not tracked")
            return

        # create new dir and point latest to it
        dir_path = self._get_reg_dir(name)
        latest = os.path.join(dir_path, "latest")
        if os.path.islink(latest):
            prev = os.path.basename(os.path.realpath(latest))
            new = f"{int(prev) + 1}"
            os.remove(latest)
        else:
            new = "0"
        new_path = os.path.join(dir_path, new)
        os.makedirs(new_path, exist_ok=True)
        os.symlink(new, latest)

        # copy stats and artifacts
        shutil.copytree(
            os.path.join(self.log_dir, "stats"), os.path.join(new_path, "stats")
        )
        shutil.copytree(
            os.path.join(self.log_dir, "artifacts"), os.path.join(new_path, "artifacts")
        )

        if err:
            self._mark_skip(new_path, "validation failed")
        if self.reg_exclude:
            self._mark_skip(new_path, "excluded")

    def validation(self, config, global_name, name, id, total, msgs):
        logger.info(f"Starting validation {id}/{total}: {name}")

        # optional: the results are still saved, e.g. for the regressions
        validation = config.get("validation", [])

        if self.validation_only:
            path = os.path.join(self.log_dir, "validations.txt")
            if os.path.isfile(path):
                os.remove(path)
        else:
            self._save_dstat_window(config)

        dstats = self._parse_dstats(config)
        with open(os.path.join(self.log_dir, "stats", "dstat.json"), "w") as f:
            print(json.dumps(dstats), file=f)

        err = False
        for step in validation:
            sname = step["name"]
            cmd = step["run"]
            cmd_file = None
            if "\n" in cmd:
                # in one block to allow more advanced bash
                fd, cmd_file = tempfile.mkstemp()
                with os.fdopen(fd, "w") as f:
                    print(cmd, file=f)

                cmd = f"bash -e{'x' if self.cmd.verbosity() else ''} '{cmd_file}'"
            rc = self.cmd.call(cmd, fatal=False, cwd=self.log_dir)
            if rc > 0:
                logger.error(f"Validation {sname} has failed ({rc})")
                cmd = step["run"].rstrip().replace("\n", " ; ")
                output = f"{sname}: '{cmd}': failed ({rc})"
                msgs.append(output)
                with open(os.path.join(self.log_dir, "validations.txt"), "a") as f:
                    print(f"{global_name}: {name}: {output}", file=f)
                err = True

            if cmd_file:
                os.unlink(cmd_file)

        if self.validation_only:
            self._update_results(name, err)
        else:
            self._save_results(name, err)

        return err

    def _run_steps(self, config, msgs):
        if "steps" not in config:
            msgs.append("no steps to run")
            return True
        steps = config["steps"]
        err = False

        for step in steps:
            name = step["name"]
            dstat_only = step.get("dstat_only", None)
            logger.info(f"test: step: {name}")
            for host in self.hosts:
                self.hosts[host].cmd_send(f"## step: {time.asctime()}: {name}")

            cmds = {}
            for who in (*self.hosts.keys(), "all"):
                if who not in step:
                    continue

                cmd = step[who]
                if "\n" in cmd:
                    cmd = f"{{\n{cmd}\n}}"

                hosts = self.hosts.keys() if who == "all" else [who]
                # run commands of the same step in parallel
                for host in hosts:
                    self.hosts[host].cmd_send(cmd)
                    cmds.setdefault(host, []).append(cmd)

            if dstat_only == "step" or dstat_only == "start":
                config.setdefault("dstat", {})["start"] = time.localtime(time.time())

            # then check status
            for host in self.hosts:
                kwargs = {}
                if "timeout_s" in step:
                    kwargs["timeout"] = int(step["timeout_s"])
                ignore_err = step.get("ignore_err", False)
                cmd = " ; ".join(cmds.get(host, [])) or f"step {name}"
                try:
                    self.hosts[host].wait_for_prompt(**kwargs)
                except TIMEOUT:
                    if not ignore_err:
                        logger.warning(f"{host}: '{cmd}': timeout: '{kwargs}'")
                        msgs.append(f"{host}: '{cmd}': timeout: '{kwargs}'")
                        err = True
                    continue

                rc = self.hosts[host].cmd_last_status()
                if not ignore_err and rc != 0:
                    logger.warning(f"{host}: '{cmd}': rc: '{rc}'")
                    msgs.append(f"{host}: '{cmd}': rc: '{rc}'")
                    err = True

            if dstat_only == "step" or dstat_only == "end":
                config.setdefault("dstat", {})["end"] = time.localtime(time.time())

            if err:
                break

        return err

    def _parse_dstat(self, config, fpath):
        if not os.path.isfile(fpath):
            logger.warning(f"No dstat file: {fpath}")
            return {}

        now = time.localtime(time.time())
        stats = {}
        with open(fpath) as csvfile:
            # skip the extra headers
            for _ in range(5):
                csvfile.readline()

            # "real" header
            keys = csvfile.readline().rstrip().replace('"', "").split(",")
            lkeys = len(keys)
            for key in keys:
                stats[key] = {"raw": []}

            for line in csvfile:
                line = line.rstrip().split(",")
                if len(line) != lkeys:
                    continue
                for i in range(lkeys):
                    val = line[i]
                    if ":" in val:
                        # 16-05 21:42:59
                        # Add year: https://github.com/python/cpython/issues/70647
                        val = f"{now.tm_year}-{val}"
                        val = time.strptime(val, "%Y-%d-%m %H:%M:%S")
                    elif "." in val:
                        val = float(val)
                    else:
                        val = int(val)
                    stats[keys[i]]["raw"].append(val)

        dstat = config.get("dstat", {})
        times = stats["time"]["raw"]
        start, end = 0, len(times)

        # remove extremes points, before and/or after the tests if specified
        dstart = dstat.get("start")
        dend = dstat.get("end")
        if dstart or dend:
            for i in range(len(times)):
                if dstart and times[i] < dstart:
                    start = i + 1
                elif dend and times[i] >= dend:
                    end = i - 1
                    break
        else:
            logger.warning("No 'dstat_only' in the yaml")

        # offset to avoid start / end noise.
        start += dstat.get("offset_start", 1)
        end -= dstat.get("offset_end", 1)

        for key in keys:
            s = stats[key]

            s["filtered"] = filtered = s["raw"][start:end]

            # not enough samples, e.g. short test: no stats, the validation fails
            if len(filtered) < 2:
                logger.warning(f"{fpath}: {key}: only {len(filtered)} sample(s)")
                continue

            if key == "time":
                s["raw_str"] = [time.asctime(x) for x in s["raw"]]
                s["str"] = [time.asctime(x) for x in filtered]
                s["sec"] = [int(time.mktime(x)) for x in filtered]
                s["diff"] = s["sec"][-1] - s["sec"][0]
                continue

            # convert from bytes to bits
            if key.startswith("net/"):
                s["raw_bits"] = [int(x * 8) for x in s["raw"]]
                s["bytes"] = filtered
                s["filtered"] = filtered = [int(x * 8) for x in filtered]

            s["sum"] = sum(filtered)
            s["diff"] = filtered[-1] - filtered[0]
            s["min"] = min(filtered)
            s["max"] = max(filtered)
            s["mean"] = mean = statistics.mean(filtered)
            s["median"] = statistics.median(filtered)
            s["variance"] = statistics.variance(filtered, mean)
            s["stdev"] = statistics.stdev(filtered, mean)
            s["pvariance"] = statistics.pvariance(filtered, mean)
            s["pstdev"] = statistics.pstdev(filtered, mean)
            s["quartiles"] = statistics.quantiles(filtered, n=4)
            s["deciles"] = statistics.quantiles(filtered, n=10)
            s["percentiles"] = statistics.quantiles(filtered, n=100)

        return stats

    def _parse_dstats(self, config):
        names = [*self.hosts.keys(), "host"]
        # e.g. with --validation-only: no VMs, but their stats are on disk
        if not self.hosts:
            stats_dir = os.path.join(self.log_dir, "stats")
            names = [
                d
                for d in sorted(os.listdir(stats_dir))
                if d != "host"
                and os.path.isfile(os.path.join(stats_dir, d, "dstat.csv"))
            ] + ["host"]

        stats = {}
        for name in names:
            fpath = os.path.join(self.log_dir, "stats", name, "dstat.csv")
            stats[name] = self._parse_dstat(config, fpath)

        return stats

    def _start_dstat_host(self):
        dirname = os.path.join(self.log_dir, "stats", "host")
        os.makedirs(dirname, exist_ok=True)
        out = os.path.join(dirname, "dstat.csv")
        cmd = f"dstat -tclm -o '{out}'"
        self.dstat = self.cmd.open(cmd, cwd=self.log_dir, mute=True)

    def _stop_dstat_host(self):
        if self.dstat is None:  # dry-run
            return
        self.dstat.terminate()
        self.dstat.wait(timeout=5)

    def _start_dstat(self, hostname):
        host = self.hosts[hostname]
        ifaces = ",".join(host.get_ifaces()) + ",total"
        dirname = os.path.join(self.log_dir, "stats", hostname)
        os.makedirs(dirname, exist_ok=True)
        out = os.path.join(dirname, "dstat.csv")
        host.cmd_wait(f"dstat -tclmn -N {ifaces} -o '{out}' &>/dev/null &")

    def _stop_dstat(self, hostname):
        host = self.hosts[hostname]
        host.cmd_wait("pgrep -f /usr/bin/dstat | xargs -r kill; sync")

    def _get_stats(self, config, phase):
        if "stats" not in config:
            return
        stats = config["stats"]
        stat_dir = os.path.join(self.log_dir, "stats")

        if phase == "post":
            for host in self.hosts:
                self._stop_dstat(host)

        for key in (phase, "all"):
            if key not in stats:
                continue

            for stat in stats[key]:
                name = stat["name"]
                cmd = stat["run"]
                hosts = [stat["target"]] if "target" in stat else self.hosts.keys()
                for host in hosts:
                    d = os.path.join(stat_dir, host, phase)
                    os.makedirs(d, exist_ok=True)
                    with open(os.path.join(d, name), "a") as f:
                        print(self.hosts[host].cmd_output(cmd), file=f)

        if phase == "pre":
            for host in self.hosts:
                self._start_dstat(host)

    # The queue can hold up to (max_latency - delay) of traffic, + what is in
    # the delay line
    def _netem_limit(self, br, hw_accel):
        if "limit_pkts" in br:
            return br["limit_pkts"]

        rate = br["rate_mbit"]
        delay = br.get("delay_ms", 0)
        max_lat = br.get("max_latency_ms", 2 * delay)
        bytes_per_ms = rate * 1000 / 8
        mtu = 12000 if hw_accel else 1500

        queue_bytes = bytes_per_ms * (max_lat - delay) if max_lat > delay else mtu

        return max(math.ceil((bytes_per_ms * delay + queue_bytes) / mtu), 10)

    def _setup_net(self, config):
        if "bridges" not in config:
            return

        hw_accel = config.get("bridges_hw_accel", True)
        hw_cmd = "ethtool -K '{}' gro off gso off tso off tx off rx off sg off"

        for br in config["bridges"]:
            tc_args = []
            for key in br:
                if not br[key]:
                    continue
                if key == "rate_mbit":
                    tc_args += ["rate", f"{br[key]}mbit"]
                elif key == "delay_ms":
                    tc_args += ["delay", f"{br[key]}ms"]
                elif key == "loss_pc":
                    tc_args += ["loss", f"{br[key]}%"]

            if br.get("rate_mbit"):
                tc_args += ["limit", str(self._netem_limit(br, hw_accel))]

            if not tc_args:
                continue

            vbr = f"vir{br['name']}"
            if self.cmd.dry_run:
                # bridges are created when booting the VMs
                ifaces = [f"<{vbr}-port>"]
            else:
                ifaces = os.listdir(f"/sys/devices/virtual/net/{vbr}/brif/")
            netem_cmd = "tc qdisc add dev '{}' root netem " + " ".join(tc_args)

            for iface in ifaces:
                self.cmd.call(f"ip link set {iface} mtu 12000")
                self.cmd.call(netem_cmd.format(iface))

            if not hw_accel:
                self.cmd.call(hw_cmd.format(vbr))
                for iface in ifaces:
                    self.cmd.call(hw_cmd.format(iface))

    def _setup_hosts(self):
        results_dir = f"RESULTS_DIR={shlex.quote(self.log_dir)}"
        for host in self.hosts.values():
            host.cmd_wait(results_dir)

    def _get_bridges(self, config, env):
        if "bridges" not in config:
            return

        bridges = []
        for br in config["bridges"]:
            vbr = f"vir{br['name']}"
            bridges.append(vbr)

        if bridges:
            env["INPUT_NET_BRIDGES"] = ",".join(bridges)

    def _get_cpus(self, config):
        return str(config.get("cpus", int(os.cpu_count() / 2)))

    def _get_ram(self, config):
        if "ram" in config:
            return str(config["ram"])

        try:
            ram = "awk '/^MemAvailable:/ {print $2}' /proc/meminfo"
            ram = int(self.cmd.output(ram)) / 1024
        except ValueError:
            ram = 2048 * 3

        return f"{int(ram / 3)}M"

    def _get_envs(self, config):
        env = {
            "INPUT_CPUS": self._get_cpus(config),
            "INPUT_RAM": self._get_ram(config),
        }

        self._get_bridges(config, env)

        env_client = env
        env_server = env.copy()

        env_client["INPUT_MAC_ADDRESS_PREFIX"] = "52:54:00:12:34=2"
        env_server["INPUT_MAC_ADDRESS_PREFIX"] = "52:54:00:12:35=3"

        return env_client, env_server

    def _start_vms(self, config):
        env_client, env_server = self._get_envs(config)
        timeout = config.get("timeout_s", 3600)

        self.stopped = False
        self._new_vm("client", env_client, timeout)
        self._new_vm("server", env_server, timeout)

    def run_test(self, config, name, id, total, msgs):
        logger.info(f"Starting test {id}/{total}: {name}")

        self._start_dstat_host()

        try:
            self._start_vms(config)

            self._setup_hosts()

            self._setup_net(config)

            self._get_stats(config, "pre")

            err = self._run_steps(config, msgs)

            self._get_stats(config, "post")
        except Exception:
            # e.g. VM not booting: no need to wait for the kmemleak scan
            self.stop(kmemleak=False)
            raise
        finally:
            self.stop()
            self._stop_dstat_host()

        return err

    # the latest results are the first ones of the new history
    def _reset_history(self, name):
        dir_path = self._get_reg_dir(name)
        last = os.path.basename(os.path.realpath(os.path.join(dir_path, "latest")))
        with open(os.path.join(dir_path, "history_since"), "w") as f:
            print(last, file=f)
        logger.info(f"{name}: regression history reset, starting from {last}")

    def run_tests(self, tests_id, config, only_this_name=None):
        global_name = config["name"]
        if self.reuse:
            global_name_n = self._prev_suite_id(global_name, tests_id)
        else:
            global_name_n = f"{tests_id:02d}-{global_name}"
        global_config = config.get("global", {})
        tests = config["tests"]
        results = {}
        exit = 0
        id = 1
        total = len(tests)

        self._set_dirs(global_name)
        logger.info(f"Starting tests {global_name_n}")

        for test in tests:
            if self.interrupted and not self.graceful:
                logger.warning("Interrupted: skipping the next tests")
                break

            # deep copy: the config is modified during the test, e.g. 'dstat'
            test_config = copy.deepcopy(global_config | test)
            name = test_config["name"]

            if only_this_name is not None and name != only_this_name:
                id += 1
                continue

            name_n = f"{global_name}: {name}"
            results.setdefault(global_name_n, {})[id] = {
                "result": "fail",
                "name": name_n,
            }

            # reported as errors, not to hide them
            if self.interrupted:
                logger.warning(f"{global_name}: {name}: timeout, skipped")
                results[global_name_n][id]["comment"] = "error: global timeout reached"
                exit = 1
                id += 1
                continue

            msgs = []
            improvs = []
            outs = []
            self._set_test_dirs(id, name)
            err, val_err, reg = False, False, False
            # one bad test should not stop the others
            try:
                if self.reuse:
                    err, val_err = self._prev_result(global_name_n, name_n, msgs)
                    # previous validation errors are checked again
                    if self.validation_only and val_err:
                        msgs.clear()
                        val_err = False
                    if not err and not val_err:
                        err = self._reset_regression(name, msgs)
                    if self.validation_only and not err:
                        err = self._load_dstat_window(test_config, msgs)
                    if self.validation_only and not err:
                        val_err = self.validation(
                            test_config, global_name, name, id, total, msgs
                        )
                else:
                    err = self.run_test(test_config, name, id, total, msgs)
                    val_err = not err and self.validation(
                        test_config, global_name, name, id, total, msgs
                    )

                if not err and not val_err:
                    if self.reg_reset:
                        self._reset_history(name)
                    reg = self.regression(
                        test_config, global_name, name, id, total, msgs, improvs, outs
                    )
            except Exception as e:
                if self.interrupted and not self.graceful:
                    raise
                logger.exception(f"{global_name}: {name}: unexpected error")
                msgs.append(f"unexpected error: {e}")
                err = True

            if err:
                logger.warning(f"{global_name}: {name}: error found, no validation")
                results[global_name_n][id]["comment"] = f"error: {'\n'.join(msgs)}"
                exit = 1
            elif val_err:
                logger.warning(
                    f"{global_name}: {name}: validation failed, no regression check"
                )
                results[global_name_n][id]["comment"] = f"validation: {'\n'.join(msgs)}"
                exit = 42 if exit == 0 else exit
            elif reg:
                logger.warning(f"{global_name}: {name}: regression found")
                results[global_name_n][id]["comment"] = f"regres: {'\n'.join(msgs)}"
                exit = 42 if exit == 0 else exit
            else:
                logger.info(f"{global_name}: {name}: success")
                results[global_name_n][id]["result"] = "pass"

            for prefix, extra in (("improv", improvs), ("outliers", outs)):
                if not extra:
                    continue
                result = results[global_name_n][id]
                comment = f"{prefix}: {'\n'.join(extra)}"
                if "comment" in result:
                    comment = f"{result['comment']}\n{comment}"
                result["comment"] = comment

            logger.info(f"Ending test {id}/{total}: {name}")

            id += 1

        logger.info(f"Ending tests: {global_name_n}")
        return results, exit
