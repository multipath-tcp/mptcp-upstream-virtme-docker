#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0

"""
Class for the entrypoint.sh script
"""

import logging
import os
import pexpect

logger = logging.getLogger(__name__)
CID = 3


class PExpectStub:
    def __init__(self, cmd, args, env, loglvl, dry_run, host, **kwargs):
        self.cmd = cmd
        self.args = args
        self.env = env
        self.loglvl = loglvl
        self.dry_run = dry_run
        self.host = host
        self.alive = True

        self.p = (
            None
            if dry_run
            else pexpect.spawn(cmd, args, env=env, encoding="utf-8", **kwargs)
        )

    def _log(self, func, *args, **kwargs):
        logger.log(
            self.loglvl, f"{self.host}: expect: {self.cmd}: {func}: {args} ({kwargs})"
        )

    def expect(self, *args, **kwargs):
        self._log("expect", args, kwargs)
        if self.dry_run:
            return
        return self.p.expect(*args, **kwargs)

    def sendline(self, *args, **kwargs):
        self._log("sendline", args, kwargs)
        if self.dry_run:
            return 0
        return self.p.sendline(*args, **kwargs)

    def terminate(self, *args, **kwargs):
        self._log("terminate", args, kwargs)
        if self.dry_run:
            self.alive = False
            return
        return self.p.terminate(*args, **kwargs)

    def read_nonblocking(self, *args, **kwargs):
        if self.dry_run:
            raise pexpect.TIMEOUT
        return self.p.read_nonblocking(*args, **kwargs)

    def isalive(self):
        if self.dry_run:
            return self.alive
        return self.p.isalive()

    def __str__(self):
        return str(self.p)


class PExpectLog:
    def __init__(self, log, hostname):
        self.log = log
        self.hostname = hostname
        self.buf = ""

    def flush(self):
        pass

    def close(self):
        pass

    def write(self, msg):
        msg = msg.replace("\r", "")
        if not msg or "\n" not in msg:
            self.buf += msg
            return

        lines = msg.split("\n")
        end = lines.pop()  # either empty if msg ending with '\n' or str for buf

        for line in lines:
            if self.buf:
                line = self.buf + line
                self.buf = ""
            self.log(f"{self.hostname}: {line}")

        self.buf += end


class Host:
    def __init__(self, mode, script, log, lvl, dry_run, user, hostname, env, timeout):
        self.mode = mode
        self.script = script
        self.log = log
        self.log_level = lvl
        self.dry_run = dry_run
        self.user = user
        self.hostname = hostname
        self.env = env
        self.timeout = timeout

        self.prompt = f"{user}@{hostname}"
        self.p = None  # PExpectStub

        if log is None:
            self.log = PExpectLog(logger.debug, hostname)

    def _spawn(self, cmd, args=[], env={}):
        logger.log(self.log_level, f"{self.hostname}: spawn: {cmd} {args} ({env})")

        return PExpectStub(
            cmd,
            args,
            os.environ.copy() | env if env else None,
            self.log_level,
            self.dry_run,
            self.hostname,
            logfile=self.log,
            timeout=self.timeout,
        )

    def _terminate(self, p):
        p.sendline("exit")
        try:
            p.expect(pexpect.EOF, timeout=60)
        except pexpect.TIMEOUT:
            p.terminate(force=True)

    def stop(self):
        raise NotImplementedError

    def cmd_output(self, cmd, timeout=20):
        # empty buffer
        while True:
            try:
                self.p.read_nonblocking(1024, 0)
            except pexpect.TIMEOUT:
                break

        logger.debug(f"{self.hostname}: output: '{cmd}': start")

        self.p.sendline(cmd)
        lines = []
        buf = ""
        while True:
            try:
                buf += self.p.read_nonblocking(1024, timeout)
            except pexpect.TIMEOUT:
                logger.info(f"{self.hostname}: output: '{cmd}': timeout: {repr(buf)}")
                break
            lines += buf.split("\r\n")
            buf = lines.pop()  # last line: either empty or not ending with \r\n
            if buf == self.prompt:
                buf = ""
                break

        if buf:
            lines.append(buf)

        logger.debug(f"{self.hostname}: output: '{cmd}': end ({len(lines) - 1})")

        return "\n".join(lines[1:])  # skip command


class VM(Host):
    def __init__(self, mode, script, log, user, lvl, dry_run, hostname, env, timeout):
        super().__init__(mode, script, log, user, lvl, dry_run, hostname, env, timeout)
        global CID

        self.cid = CID
        CID += 1

        self.env["INPUT_HOSTNAME"] = hostname
        self.env["INPUT_VSOCK_CID"] = str(self.cid)

        self.serial = None
        logger.info(f"{hostname}: VM: boot")
        self.serial, self.p = self._boot()
        logger.info(f"{hostname}: VM: ready")

    def _boot(self):
        args = ["vm-manual", self.mode]
        serial = self._spawn(self.script, args, self.env)
        try:
            serial.expect(self.prompt, timeout=60)
        except (pexpect.EOF, pexpect.TIMEOUT) as e:
            logger.fatal("Unable to get VSOCK access")
            self._terminate(serial)
            raise e

        args = ["--mods", "none", "--client", "--port", str(self.cid)]
        vsock = self._spawn("virtme-run", args)
        try:
            vsock.expect(self.prompt, timeout=5)
            self.prompt = f"|{self.prompt}: "
            vsock.sendline(f"PS1='{self.prompt}'")
        except (pexpect.EOF, pexpect.TIMEOUT) as e:
            logger.fatal("Unable to get VSOCK access")
            self._terminate(serial)
            raise e

        return serial, vsock

    def stop(self):
        if not self.serial:
            return

        serial = self.serial
        self.serial = None

        self._terminate(serial)
        if self.p.isalive():
            self.p.terminate(force=True)
        self.p = None

        self.log.close()
