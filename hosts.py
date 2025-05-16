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

        kwargs["env"] = env
        kwargs["encoding"] = "utf-8"
        self.p = self._spawn(cmd, args, **kwargs)

    def _log(self, func, *args, **kwargs):
        logger.log(
            self.loglvl, f"{self.host}: expect: {self.cmd}: {func}: {args} ({kwargs})"
        )

    def _spawn(self, *args, **kwargs):
        self._log("spawn", args, kwargs)
        if self.dry_run:
            return None
        return pexpect.spawn(*args, **kwargs)

    def expect(self, *args, **kwargs):
        self._log("expect", args, kwargs)
        if self.dry_run:
            return
        return self.p.expect(*args, **kwargs)

    def send(self, *args, **kwargs):
        self._log("send", args, kwargs)
        if self.dry_run:
            return 0
        return self.p.send(*args, **kwargs)

    def sendline(self, *args, **kwargs):
        self._log("sendline", args, kwargs)
        if self.dry_run:
            return 0
        return self.p.sendline(*args, **kwargs)

    def sendeof(self, *args, **kwargs):
        self._log("sendeof", args, kwargs)
        if self.dry_run:
            return 0
        return self.p.sendeof(*args, **kwargs)

    def terminate(self, *args, **kwargs):
        self._log("terminate", args, kwargs)
        if self.dry_run:
            self.alive = False
            return
        return self.p.terminate(*args, **kwargs)

    def read_nonblocking(self, *args, **kwargs):
        if self.dry_run:
            raise pexpect.TIMEOUT("dry-run")
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
        p.sendeof()
        try:
            p.expect(pexpect.EOF, timeout=60)
        except pexpect.TIMEOUT:
            p.terminate(force=True)

    def terminate(self):
        if self.p.isalive():
            self._terminate(self.p)

    def stop(self):
        if not self.p:
            return

        self.terminate()
        self.p = None

        self.log.close()

    def send_ctrl_c(self):
        self.p.send("\003")
        self.p.sendline()

    def cmd_send(self, cmd):
        # empty buffer
        while True:
            try:
                self.p.read_nonblocking(1024, 0)
            except pexpect.TIMEOUT:
                break
        self.p.sendline(cmd)

    # timeout: time without output in the serial
    def wait(self, expect, timeout):
        lines = []
        buf = ""
        while True:
            try:
                buf += self.p.read_nonblocking(1024, timeout)
            except pexpect.TIMEOUT as e:
                if self.dry_run:
                    lines = [False]
                    break
                self.send_ctrl_c()
                raise e
            lines += buf.split("\r\n")
            buf = lines.pop()  # last line: either empty or not ending with \r\n
            if buf == expect:
                buf = ""
                break

        if buf:
            lines.append(buf)

        return "\n".join(lines[1:])  # skip command

    def wait_for_prompt(self, timeout=20):
        return self.wait(self.prompt, timeout)

    def cmd_output(self, cmd, **kwargs):
        self.cmd_send(cmd)
        return self.wait_for_prompt(**kwargs)

    def cmd_last_status(self):
        if self.dry_run:
            return 0

        try:
            return int(self.cmd_output("echo $?", timeout=1))
        except pexpect.TIMEOUT:
            return 128

    def cmd_output_status(self, cmd, **kwargs):
        try:
            return self.cmd_output(cmd, **kwargs), self.cmd_last_status()
        except pexpect.TIMEOUT:
            return "", 128

    def cmd_wait(self, cmd, ignore_timeout=False, **kwargs):
        try:
            self.cmd_output(cmd, **kwargs)
        except pexpect.TIMEOUT as e:
            if not ignore_timeout:
                raise e

    def cmd_status(self, cmd, **kwargs):
        try:
            self.cmd_wait(cmd, **kwargs)
        except pexpect.TIMEOUT:
            return 128
        return self.cmd_last_status()


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

        super().stop()
