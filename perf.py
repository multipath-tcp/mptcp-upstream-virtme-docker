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

import jsonschema
import yaml

import entrypoint
import logcmd

logger = logging.getLogger("perf")


def logger_color(level: int, color: str):
    logging.addLevelName(
        level, f"\033[1;{color}m{logging.getLevelName(level)}\033[1;0m"
    )


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


def check_output_file_arg(path):
    try:
        with open(path, "w"):
            pass
    except OSError:
        raise argparse.ArgumentTypeError(f"'{path}' is not a valid output file.")
    return os.path.realpath(path)


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
        action="append",
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
        action="store",
        type=check_output_file_arg,
        help="Output results to this file in JSON format",
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


def add_infos(results, infos):
    for info in infos:
        info = info.split(":", 1)
        if len(info) != 2:
            logger.warning("Skip info: " + info[0])
            continue
        results[info[0]] = info[1]


def main():
    arg_parser = get_args_parser()
    args = arg_parser.parse_args()

    level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s.%(msecs)03d %(levelname)s %(module)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    logger_color(logging.DEBUG, "30")
    logger_color(logging.INFO, "34")
    logger_color(logging.WARNING, "33")
    logger_color(logging.ERROR, "31")
    logger_color(logging.FATAL, "41")

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

    if not args.config:
        args.config = [os.path.join(os.path.dirname(__file__), "perf", "perf.yml")]

    results = {}
    id = 1
    for conf_file in args.config:
        result, exit = ep.run_tests(id, get_tests(conf_file))
        results.update(result)
        id += 1

    if args.json:
        if args.info:
            results = {"results": results}
            add_infos(results, args.info)

        with open(args.json, "w") as f:
            json.dump(results, f)

        # No exit with a specific code when emitting JSON here: output is parsed
        return

    if exit:
        sys.exit(exit)


if __name__ == "__main__":
    main()
