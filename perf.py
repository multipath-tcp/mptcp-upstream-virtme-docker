#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0

"""
Perf script interacting with entrypoint
"""

import argparse
import logging
import os
import shutil
import signal
import yaml

import cmd
import entrypoint

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
        default="/perf.yml",
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
        "--verbose",
        "-v",
        action="count",
        default=0,
        help="Increase console output verbosity.",
    )

    return parser


def get_tests(conf_file):
    with open(conf_file, "r") as c:
        config = yaml.safe_load(c)
    return config


def main():
    arg_parser = get_args_parser()
    args = arg_parser.parse_args()

    level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s.%(msecs)03d %(levelname)s %(module)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    command = cmd.CMD(args.dry_run, args.verbose, args.kernel_dir)
    ep = entrypoint.Entrypoint(command, args.mode, args.entrypoint, args.log_dir)

    if args.build:
        ep.build()
    else:
        logger.info("Skip build")

    def handler(signum, frame):
        logger.info(f"Signal handler called with signal: {signum}")
        ep.stop()

    signal.signal(signal.SIGINT, handler)

    ep.run_tests(get_tests(args.config))


if __name__ == "__main__":
    main()
