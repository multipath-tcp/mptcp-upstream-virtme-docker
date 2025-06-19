# SPDX-License-Identifier: GPL-2.0

"""
Class for the entrypoint.sh script
"""

import json
import logging
import os
import shlex
import statistics
import tempfile
import time

from pexpect import TIMEOUT

import hosts

logger = logging.getLogger(__name__)


class Entrypoint:
    def __init__(self, cmd, mode, script, log_dir):
        self.cmd = cmd
        self.mode = mode
        self.script = script
        self.log_dir = os.path.realpath(log_dir)

        self.hosts = {}
        self.git_sha = self.cmd.output("git rev-parse HEAD", fatal=False)
        self.stopped = False

        logger.info(f"Env ({self.git_sha}) in {self.mode} mode")

    def build(self):
        cmd = f"{self.script} build {self.mode}"
        self.cmd.call(cmd)

    def _new_vm(self, hostname, env, timeout):
        if int(self.cmd.verbosity()) > 1:
            log = None
        else:
            os.makedirs(self.log_dir, exist_ok=True)
            log = open(os.path.join(self.log_dir, f"{hostname}.log"), "a")

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

    def _validation(self, config):
        if "validation" not in config:
            return True
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

        return err

    def _run_test(self, config):
        if "test" not in config:
            return True
        test = config["test"]
        err = False

        for step in test:
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
                        logger.warn(f"{host}: '{cmd}': timeout: '{kwargs}'")
                        err = True
                    continue

                rc = self.hosts[host].cmd_last_status()
                if not ignore_err and rc != 0:
                    logger.warn(f"{host}: '{cmd}': rc: '{rc}'")
                    err = True

            if dstat_only == "step" or dstat_only == "end":
                config["dstat"]["end"] = time.localtime(time.time())

            if err:
                break

        return err

    def _parse_dstat(self, config, fpath):
        if not os.path.isfile(fpath):
            logger.warn(f"No dstat file: {fpath}")
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

            for line in csvfile.readlines():
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
            logger.warn("No 'dstat_only' in the yaml")

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
            for host in self.hosts.keys():
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
            for host in self.hosts.keys():
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

        err = self._run_test(config)

        self._get_stats(config, "post")
        self.stop()
        self._stop_dstat_host()

        if err:
            logger.info("error(s) found during the tests, no validation")
        else:
            err = self._validation(config)

        return err

    def run_tests(self, tests):
        err = []
        id = 1
        total = len(tests)
        for config in tests:
            name = config["name"]
            if self.run_test(config, name, id, total):
                err.append(name)
            id += 1

        return err
