# SPDX-License-Identifier: GPL-2.0

"""
Class for the entrypoint.sh script
"""

import json
import logging
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


class Entrypoint:
    def __init__(self, cmd, mode, script, log_dir, reg_dir, save_results):
        self.cmd = cmd
        self.mode = mode
        self.script = script
        self.log_dir_parent = os.path.realpath(log_dir)
        self.reg_dir_parent = None if reg_dir is None else os.path.realpath(reg_dir)
        self.save_results = save_results

        self.hosts = {}
        self.git_sha = self.cmd.output("git rev-parse HEAD", fatal=False)
        self.stopped = False

        logger.info(f"Env ({self.git_sha}) in {self.mode} mode")

    def _set_dirs(self, name):
        self.log_dir = os.path.join(self.log_dir_parent, name)
        os.makedirs(self.log_dir, exist_ok=True)
        os.makedirs(os.path.join(self.log_dir, "artifacts"), exist_ok=True)
        os.makedirs(os.path.join(self.log_dir, "stats"), exist_ok=True)

        if self.reg_dir_parent is not None:
            self.reg_dir = os.path.join(self.reg_dir_parent, name)
            os.makedirs(self.reg_dir, exist_ok=True)
        else:
            self.reg_dir = None

    def build(self):
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

    def stop(self):
        if self.stopped:
            return
        self.stopped = True

        for name in self.hosts:
            host = self.hosts[name]
            host.stop()

    def _get_reg_dir(self, name):
        return os.path.join(self.reg_dir, re.sub(r"\W", "_", name))

    def _get_info(self, file_path, json_field):
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

    def _mark_reg(self, latest, name, check_name, msg):
        open(os.path.join(latest, "skip"), "a").close()
        logger.warning(f"Regression in {name}, check '{check_name}': {msg}")
        return True

    def regression(self, config, name, id, total):
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

        for step in regression["steps"]:
            check = global_config | step
            check_name = check["name"]
            file = check["file"]

            latest_file = os.path.join(latest, file)
            if not os.path.isfile(latest_file):
                msg = f"{file}' is not available in latest"
                reg = self._mark_reg(latest, name, check_name, msg)
                continue

            json_field = check.get("json_field", None)
            last_res = self._get_info(latest_file, json_field)

            alpha = float(check.get("alpha", 0.05))
            if not 0 < alpha < 1:
                raise ValueError(f"{name}: {check_name}: alpha must be between 0 and 1")
            history_max_n = int(check.get("history_max_n", 0))
            history_since = int(check.get("history_since", 0))

            prev = last
            prev_results = []
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

                prev_results.append(self._get_info(file_path, json_field))

            if len(prev_results) < 2:
                logger.info(
                    f"{name}: {check_name}: need at least two previous measurements"
                )
                continue

            mean = statistics.mean(prev_results)
            stdev = statistics.stdev(prev_results, mean)
            if stdev == 0:
                p_value = 1 if last_res == mean else 0
            else:
                p_value = stats.ttest_1samp(prev_results, last_res).pvalue

            if p_value < alpha:
                msg = (
                    f"got {last_res}, had {mean}; "
                    f"p-value {p_value:.6g} is below alpha {alpha:.6g}"
                )
                reg = self._mark_reg(latest, name, check_name, msg)
                continue

            logger.info(
                f"{name}: {check_name}: no regression "
                f"({mean} vs {last_res}, p-value {p_value:.6g})"
            )

        return reg

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
        os.symlink(new_path, latest)

        # symlink to the log dir
        os.symlink(
            os.path.relpath(self.log_dir, new_path),
            os.path.join(self.reg_dir, "logs"),
        )

        # copy stats and artifacts
        shutil.copytree(os.path.join(self.log_dir, "stats"), new_path)
        shutil.copytree(os.path.join(self.log_dir, "artifacts"), new_path)

        if err:
            # easy to handle
            open(os.path.join(new_path, "skip"), "a").close()

    def validation(self, config, name, id, total):
        if "validation" not in config:
            return True

        logger.info(f"Starting validation {id}/{total}: {name}")

        validation = config["validation"]

        dstats = self._parse_dstats(config)
        with open(os.path.join(self.log_dir, "stats", "dstat.json"), "w") as f:
            print(json.dumps(dstats), file=f)

        err = False
        for step in validation:
            name = step["name"]
            cmd = step["run"]
            cmd_file = None
            if "\n" in cmd:
                # in one block to allow more advanced bash
                _, cmd_file = tempfile.mkstemp()
                with open(cmd_file, "w") as f:
                    print(cmd, file=f)

                cmd = f"bash -e{'x' if self.cmd.verbosity() else ''} '{cmd_file}'"
            rc = self.cmd.call(cmd, fatal=False, cwd=self.log_dir)
            if rc > 0:
                logger.error(f"Validation {name} has failed ({rc})")
                err = True

            if cmd_file:
                os.unlink(cmd_file)

        if self.save_results:
            self._save_results(name, err)

        return err

    def _run_steps(self, config):
        if "steps" not in config:
            return True
        steps = config["steps"]
        err = False

        for step in steps:
            name = step["name"]
            dstat_only = step.get("dstat_only", None)
            logger.info(f"test: step: {name}")
            for host in self.hosts:
                self.hosts[host].cmd_send(f"## step: {time.asctime()}: {name}")

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

            if dstat_only == "step" or dstat_only == "start":
                if "dstat" not in config:
                    config["dstat"] = {}
                config["dstat"]["start"] = time.localtime(time.time())

            # then check status
            for host in self.hosts:
                kwargs = {}
                if "timeout_s" in step:
                    kwargs["timeout"] = int(step["timeout_s"])
                ignore_err = step.get("ignore_err", False)
                try:
                    self.hosts[host].wait_for_prompt(**kwargs)
                except TIMEOUT:
                    if not ignore_err:
                        logger.warning(f"{host}: '{cmd}': timeout: '{kwargs}'")
                        err = True
                    continue

                rc = self.hosts[host].cmd_last_status()
                if not ignore_err and rc != 0:
                    logger.warning(f"{host}: '{cmd}': rc: '{rc}'")
                    err = True

            if dstat_only == "step" or dstat_only == "end":
                config["dstat"]["end"] = time.localtime(time.time())

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

        # remove extremes points, before and after the tests if specified
        if "start" in dstat and "end" in dstat:
            dstart = dstat["start"]
            dend = dstat["end"]
            for i in range(len(times)):
                if times[i] < dstart:
                    start = i + 1
                elif times[i] >= dend:
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
        stats = {}
        for name in (*self.hosts.keys(), "host"):
            fpath = os.path.join(self.log_dir, "stats", name, "dstat.csv")
            stats[name] = self._parse_dstat(config, fpath)

        return stats

    def _start_dstat_host(self):
        self.cmd.call("/etc/init.d/pmcd start")
        dirname = os.path.join(self.log_dir, "stats", "host")
        os.makedirs(dirname, exist_ok=True)
        out = os.path.join(dirname, "dstat.csv")
        cmd = f"dstat -tclm -o '{out}'"
        self.dstat = self.cmd.open(cmd, cwd=self.log_dir, mute=True)

    def _stop_dstat_host(self):
        self.dstat.terminate()
        self.dstat.wait(timeout=5)

    def _start_dstat(self, hostname):
        host = self.hosts[hostname]
        ifaces = ",".join(host.get_ifaces()) + ",total"
        dirname = os.path.join(self.log_dir, "stats", hostname)
        os.makedirs(dirname, exist_ok=True)
        out = os.path.join(dirname, "dstat.csv")
        host.cmd_wait("/etc/init.d/pmcd start")
        host.cmd_wait(f"dstat -tclmn -N {ifaces} -o '{out}' &>/dev/null &")

    def _stop_dstat(self, hostname):
        host = self.hosts[hostname]
        host.cmd_wait("killall dstat; sync")

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

            if not tc_args:
                continue

            vbr = f"vir{br['name']}"
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

        self._new_vm("client", env_client, timeout)
        self._new_vm("server", env_server, timeout)

    def run_test(self, config, name, id, total):
        logger.info(f"Starting test {id}/{total}: {name}")

        self._start_dstat_host()

        self._start_vms(config)

        self._setup_hosts()

        self._setup_net(config)

        self._get_stats(config, "pre")

        err = self._run_steps(config)

        self._get_stats(config, "post")
        self.stop()
        self._stop_dstat_host()

        return err

    def run_tests(self, tests_id, config):
        global_name = config["name"]
        global_config = config.get("global", {})
        tests = config["tests"]
        results = {}
        exit = 0
        id = 1
        total = len(tests)

        self._set_dirs(f"{tests_id:02d}-{global_name}")
        logger.info(f"Starting tests {tests_id}: {global_name}")

        for test in tests:
            test_config = global_config | test
            name = test_config["name"]
            results[global_name] = {
                id: {
                    "result": "fail",
                    "name": name,
                }
            }
            if self.run_test(test_config, name, id, total):
                logger.warning(f"{name}: error found, no validation")
                results[global_name][id]["comment"] = "test error"
                exit = 1
            elif self.validation(test_config, name, id, total):
                logger.warning(f"{name}: validation failed, no regression check")
                results[global_name][id]["comment"] = "validation error"
                exit = 42 if exit == 0 else exit
            elif self.regression(test_config, name, id, total):
                logger.warning(f"{name}: regression found")
                results[global_name][id]["comment"] = "regression found"
                exit = 42 if exit == 0 else exit
            else:
                logger.info(f"{name}: success")
                results[global_name][id]["result"] = "pass"

            logger.info(f"Ending test {id}/{total}: {name}")

            id += 1

        logger.info(f"Ending tests {tests_id}: {global_name}")
        return results, exit
