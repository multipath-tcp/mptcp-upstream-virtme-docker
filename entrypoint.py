#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0

"""
Class for the entrypoint.sh script
"""

import logging
import os

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
        for name in self.hosts:
            host = self.hosts[name]
            host.stop()
        self.hosts.clear()

    def _get_stat(self, stats, hosts, phase):
        stat_dir = os.path.join(self.log_dir, "stats")
        for stat in stats:
            for host in hosts:
                d = os.path.join(stat_dir, host, phase)
                os.makedirs(d, exist_ok=True)
                with open(os.path.join(d, stat), "a") as f:
                    print(self.hosts[host].cmd_output(stats[stat]), file=f)

    def _get_stats(self, config, phase):
        if "stats" not in config:
            return
        stats = config["stats"]

        for key in (phase, "all"):
            if key not in stats:
                continue

            s = stats[key].copy()
            for host in self.hosts:
                if host not in s:
                    continue

                self._get_stat(s.pop(host), [host], phase)

            self._get_stat(s, self.hosts, phase)

    def _get_envs(self, config):
        try:
            ram = "awk '/^MemAvailable:/ {print $2}' /proc/meminfo"
            ram = int(self.cmd.output(ram)) / 1024
        except ValueError:
            ram = 2048 * 3

        env = {
            "INPUT_CPUS": str(int(os.cpu_count() / 2)),
            "INPUT_RAM": f"{int(ram / 3)}M",
        }

        if "bridges" in config:
            bridges = []
            for br in config["bridges"]:
                vbr = f"vir{br}"
                bridges.append(vbr)
                for key in config["bridges"][br]:
                    val = config["bridges"][br][key]
                    env[f"INPUT_NET_BRIDGE_{vbr}_{key.upper()}"] = str(val)

            if bridges:
                env["INPUT_NET_BRIDGES"] = ",".join(bridges)

        env_client = env
        env_server = env.copy()

        env_client["INPUT_MAC_ADDRESS_PREFIX"] = "52:54:00:12:34=2"
        env_server["INPUT_MAC_ADDRESS_PREFIX"] = "52:54:00:12:35=3"

        return env_client, env_server

    def run_test(self, name, config, id, total):
        logger.info(f"Starting test {id}/{total}: {name}")

        env_client, env_server = self._get_envs(config)
        timeout = config.get("timeout_s", 3600)

        self._new_vm("client", env_client, timeout)
        self._new_vm("server", env_server, timeout)

        self._get_stats(config, "pre")

        # TODO: tests

        self._get_stats(config, "post")
        self.stop()

        # TODO: validations

    def run_tests(self, tests):
        id = 1
        total = len(tests)
        for name in tests:
            self.run_test(name, tests[name], id, total)
