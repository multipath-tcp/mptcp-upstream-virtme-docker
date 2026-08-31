#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0

"""
Perf script interacting with entrypoint
"""

import argparse
import json
import logging
import os
import shutil
import signal
import sys
from datetime import time

import jsonschema
import yaml

import entrypoint
import logcmd

logger = logging.getLogger("perf")


def check_dir_arg(path):
    if not os.path.isdir(path):
        raise argparse.ArgumentTypeError(f"'{path}' is not a valid directory.")
    return os.path.realpath(path)


def check_file_arg(path):
    if not os.path.isfile(path):
        raise argparse.ArgumentTypeError(f"'{path}' is not a valid path.")
    return os.path.realpath(path)


def check_script_arg(path):
    if not shutil.which(path):
        raise argparse.ArgumentTypeError(f"'{path}' is not a valid script.")
    return path


def get_args_parser():
    parser = argparse.ArgumentParser(
        description="MPTCP Perf checker",
    )

    parser.add_argument(
        "--build",
        "-b",
        action="store_true",
        help="Build the kernel",
    )

    parser.add_argument(
        "--config",
        "-c",
        action="store",
        default="/perf/perf.yml",
        type=check_file_arg,
        help="YAML config file",
    )

    parser.add_argument(
        "--dry-run",
        "-n",
        action="store_true",
        help="Only show the commands without actually running them",
    )

    parser.add_argument(
        "--entrypoint",
        action="store",
        default="/entrypoint.sh",
        type=check_script_arg,
        help="Entrypoint script",
    )

    parser.add_argument(
        "--info",
        "-I",
        action="append",
        metavar="key:value",
        help="Add extra info in the JSON, can be used multiple times",
    )

    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit results in JSON format",
    )

    parser.add_argument(
        "--kernel-dir",
        "-k",
        action="store",
        default=os.path.curdir,
        type=check_dir_arg,
        help="Kernel directory",
    )

    parser.add_argument(
        "--log-dir",
        "-l",
        action="store",
        default=os.path.curdir,
        type=check_dir_arg,
        help="Log directory",
    )

    parser.add_argument(
        "--mode",
        "-m",
        action="store",
        default="normal",
        choices=["normal", "debug"],
        help="Test mode",
    )

    parser.add_argument(
        "--reg-dir",
        "-r",
        action="store",
        type=check_dir_arg,
        help="Regression directory",
    )

    parser.add_argument(
        "--save-results",
        "-s",
        action="store_true",
        help="Save the results of the tests",
    )

    parser.add_argument(
        "--verbose",
        "-v",
        action="count",
        default=0,
        help="Increase console output verbosity.",
    )

    return parser


def get_tests(conf_file):
    with open(conf_file) as c:
        config = yaml.safe_load(c)

    schema_file = os.path.join(os.path.dirname(__file__), "perf", "perf.schema")
    with open(schema_file) as s:
        schema = json.load(s)
    jsonschema.validate(config, schema)

    return config


def main():
    arg_parser = get_args_parser()
    args = arg_parser.parse_args()

    level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s.%(msecs)03d %(levelname)s %(module)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        stream=sys.stderr if args.json else sys.stdout,
    )

    ep = entrypoint.Entrypoint(
        logcmd.CMD(args.dry_run, args.verbose, args.kernel_dir),
        args.mode,
        args.entrypoint,
        args.log_dir,
        args.reg_dir,
        args.save_results,
    )

    if args.build:
        ep.build()
    else:
        logger.info("Skip build")

    def handler(signum, frame):
        logger.info(f"Signal handler called with signal: {signum}")
        ep.stop()

    signal.signal(signal.SIGINT, handler)

    err, reg = ep.run_tests(get_tests(args.config))

    if args.json:
        json_output = {
            "date": time.now().strftime("%Y-%m-%d %H:%M:%S"),
            "git_sha": ep.get_git_sha(),
            "regressions": reg,
            "errors": err,
        }

        for info in args.info:
            info = info.split(":", 1)
            if len(info) != 2:
                logger.warning("Skip info: " + info[0])
                continue

            json_output[info[0]] = info[1]

        print(json.dumps(json_output))
        # No exit with a specific code when emitting JSON here: output is parsed
        return

    exit = 0
    if reg:
        logger.warning(f"Regressions with tests: {reg}")
        exit = 42
    if err:
        logger.error(f"Error with tests: {err}")
        exit = 1
    if exit:
        sys.exit(exit)


if __name__ == "__main__":
    main()
