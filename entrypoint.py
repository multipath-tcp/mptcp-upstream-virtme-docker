# SPDX-License-Identifier: GPL-2.0

"""
Class for the entrypoint.sh script
"""

import logging
import os
import shlex
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

    def _validation(self, config):
        if "validation" not in config:
            return True
        validation = config["validation"]

        err = False
        for step in validation:
            name = step["name"]
            cmd = step["run"]
            if "\n" in cmd:
                # in one block to allow more advanced bash
                cmd = shlex.quote(cmd).replace("\n", " ; ")
                cmd = f"bash -ce{'x' if self.cmd.verbosity() else ''} {cmd}"
            rc = self.cmd.call(cmd, fatal=False, cwd=self.log_dir)
            if rc > 0:
                logger.error(f"Validation {name} has failed ({rc})")
                err = True

        return err

    def _run_test(self, config):
        if "test" not in config:
            return True
        test = config["test"]
        err = False

        for step in test:
            name = step["name"]
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
            if err:
                break

        return err

    def _get_stats(self, config, phase):
        if "stats" not in config:
            return
        stats = config["stats"]
        stat_dir = os.path.join(self.log_dir, "stats")

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

    def _get_bridges(self, config, env):
        if "bridges" not in config:
            return

        bridges = []
        for br in config["bridges"]:
            vbr = f"vir{br['name']}"
            bridges.append(vbr)
            for key in br:
                if key == "name":
                    continue
                val = br[key]
                env[f"INPUT_NET_BRIDGE_{vbr}_{key.upper()}"] = str(val)

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

    def run_test(self, config, name, id, total):
        logger.info(f"Starting test {id}/{total}: {name}")

        env_client, env_server = self._get_envs(config)
        timeout = config.get("timeout_s", 3600)

        self._new_vm("client", env_client, timeout)
        self._new_vm("server", env_server, timeout)

        self._get_stats(config, "pre")

        err = self._run_test(config)

        self._get_stats(config, "post")
        self.stop()

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
