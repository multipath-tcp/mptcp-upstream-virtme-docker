#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0

"""
Utils: Command class
"""

import logging
import os
import subprocess
import sys

logger = logging.getLogger(__name__)


class CMD:
    def __init__(self, dry_run, verbose, cwd):
        self.dry_run = dry_run
        self.verbose = verbose
        self.cwd = cwd
        self.lvl = logging.INFO if self.dry_run else logging.DEBUG

    def _log(self, cmd, env, name):
        logger.log(self.lvl, f"{name}: {cmd}{f' (extra env: {env})' if env else ''}")

    def _get_env(self, env):
        if env:
            env = os.environ.copy() | env
        return env

    def verbosity(self):
        return self.verbose

    def output(self, cmd, fatal=True, env=None, **kwargs):
        self._log(cmd, env, "output")
        if self.dry_run:
            return "<output>"

        env = self._get_env(env)
        if "cwd" not in kwargs:
            kwargs["cwd"] = self.cwd
        try:
            return (
                subprocess.check_output(cmd, shell=True, env=env, **kwargs)
                .decode(sys.stdout.encoding)
                .rstrip()
            )
        except subprocess.CalledProcessError as e:
            if fatal:
                logger.fatal(f"Unable to execute '{cmd}', error: {e.returncode}")
                sys.exit(1)
            return ""

    def call(self, cmd, fatal=True, env=None, **kwargs):
        self._log(cmd, env, "call")
        if self.dry_run:
            return 0

        env = self._get_env(env)
        if "cwd" not in kwargs:
            kwargs["cwd"] = self.cwd
        if not self.verbose and  "stdout" not in kwargs:
            kwargs["stdout"] = subprocess.DEVNULL

        try:
            subprocess.check_call(cmd, shell=True, env=env, **kwargs)
            return 0
        except subprocess.CalledProcessError as e:
            if fatal:
                logger.fatal(f"Unable to execute '{cmd}', error: {e.returncode}")
                sys.exit(1)
            return e.returncode

    def open(self, cmd, env=None, **kwargs):
        self._log(cmd, env, "open")
        if self.dry_run:
            return None

        env = self._get_env(env)
        if "cwd" not in kwargs:
            kwargs["cwd"] = self.cwd
        return subprocess.Popen(
            cmd,
            env=env,
            stdout=subprocess.PIPE,
            stdin=subprocess.PIPE,
            stderr=subprocess.PIPE,
            **kwargs,
        )
