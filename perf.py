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


def check_min_history_arg(value):
    try:
        n = int(value)
    except ValueError:
        n = 0
    # at least 2 values are needed to compute the standard deviation
    if n < 2:
        raise argparse.ArgumentTypeError(f"'{value}' is not an integer >= 2.")
    return n


def check_uint_arg(value):
    try:
        value = int(value)
        if value < 0:
            raise ValueError
    except ValueError:
        raise argparse.ArgumentTypeError(f"'{value}' is not an integer >= 0.")
    return value


def check_alpha_arg(value):
    try:
        alpha = float(value)
    except ValueError:
        alpha = 0
    if not 0 < alpha < 1:
        raise argparse.ArgumentTypeError(f"'{value}' is not a number in ]0, 1[.")
    return alpha


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
        "--build-only",
        "-B",
        action="store_true",
        help="Only build the kernel, without running the tests",
    )

    parser.add_argument(
        "--config",
        "-c",
        action="append",
        type=check_file_arg,
        help="YAML config file",
    )

    parser.add_argument(
        "--config-dir",
        "-C",
        action="store",
        type=check_dir_arg,
        help="YAML config files directory, take precedence over --config",
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
        "--json-only-fails",
        action="store_true",
        help="Only keep failed tests in the file from --json",
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
        "--reg-alpha",
        action="store",
        type=check_alpha_arg,
        help="Significance level for the regression checks, overriding the"
        " 'alpha' values from the config files (default: 0.05)",
    )

    parser.add_argument(
        "--reg-dir",
        "-r",
        action="store",
        type=check_dir_arg,
        help="Regression directory",
    )

    parser.add_argument(
        "--reg-exclude",
        action="store_true",
        help="Keep the results, but exclude them from the next regression checks,"
        " e.g. when validating WIP code",
    )

    parser.add_argument(
        "--reg-only",
        action="store_true",
        help="Only check the regressions, re-using the results from the previous"
        " run in the log directory, e.g. after modifying the regression checks",
    )

    parser.add_argument(
        "--reg-reset",
        action="store_true",
        help="Restart the regression history from the latest results, e.g. after"
        " an accepted change in behaviour",
    )

    parser.add_argument(
        "--reg-min-history",
        action="store",
        default=20,
        type=check_min_history_arg,
        help="Minimum number of prior measurements to check regressions",
    )

    parser.add_argument(
        "--test-only",
        "-T",
        action="store",
        metavar="NAME",
        help="Only run the test with this name, from the only config file",
    )

    parser.add_argument(
        "--timeout-minutes",
        "-t",
        action="store",
        default=150,
        type=check_uint_arg,
        help="Global timeout for all the tests, 0 to disable: when"
        " reached, the current test is completed, and the next ones are skipped",
    )

    parser.add_argument(
        "--validation-only",
        action="store_true",
        help="Only validate the results, and check the regressions, re-using the"
        " results from the previous run in the log directory, e.g. after"
        " modifying the validation checks or the dstat offsets",
    )

    parser.add_argument(
        "--verbose",
        "-v",
        action="count",
        default=0,
        help="Increase console output verbosity.",
    )

    return parser


def validate_config(conf_file):
    with open(conf_file) as c:
        config = yaml.safe_load(c)

    schema_file = os.path.join(os.path.dirname(__file__), "perf", "perf.schema")
    with open(schema_file) as s:
        schema = json.load(s)
    jsonschema.validate(config, schema)


def add_infos(results, infos):
    for info in infos:
        info = info.split(":", 1)
        if len(info) != 2:
            logger.warning("Skip info: " + info[0])
            continue
        results[info[0]] = info[1]


def only_fails(results):
    fails = {}
    for group, tests in results.items():
        tests = {id: t for id, t in tests.items() if t["result"] != "pass"}
        if tests:
            fails[group] = tests
    return fails


def main():
    arg_parser = get_args_parser()
    args = arg_parser.parse_args()

    for opt, enabled in (
        ("--reg-only", args.reg_only),
        ("--validation-only", args.validation_only),
    ):
        if not enabled:
            continue
        if not args.reg_dir:
            arg_parser.error(f"{opt} requires --reg-dir")
        if not os.path.isfile(os.path.join(args.log_dir, "perf.json")):
            arg_parser.error(f"{opt}: no previous results in {args.log_dir}")

    if args.reg_only and args.validation_only:
        arg_parser.error("--validation-only also checks the regressions")

    if args.reg_reset:
        if not args.reg_dir:
            arg_parser.error("--reg-reset requires --reg-dir")
        if args.reg_exclude:
            arg_parser.error("--reg-reset cannot be used with --reg-exclude")

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
        args.reg_min_history,
        args.reg_alpha,
        args.reg_exclude,
        args.reg_only,
        args.reg_reset,
        args.validation_only,
    )

    if args.build or args.build_only:
        ep.build()

        if args.build_only:
            return
    else:
        logger.info("Skip build")

    def handler(signum, frame):
        logger.info(f"Signal handler called with signal: {signum}")
        ep.interrupt()

    signal.signal(signal.SIGINT, handler)

    def timeout_handler(signum, frame):
        logger.warning(f"Global timeout of {args.timeout_minutes} minutes reached")
        ep.interrupt(graceful=True)

    signal.signal(signal.SIGALRM, timeout_handler)
    signal.alarm(args.timeout_minutes * 60)

    if args.config_dir:
        args.config = [
            os.path.join(args.config_dir, f)
            for f in sorted(os.listdir(args.config_dir))
            if f.endswith(".yml")
        ]
    elif not args.config:
        args.config = [os.path.join(os.path.dirname(__file__), "perf", "perf.yml")]

    for conf_file in args.config:
        validate_config(conf_file)

    if args.test_only and len(args.config) != 1:
        arg_parser.error("--test-only requires exactly one config file")

    results = {}
    exit = 0
    id = 1
    for conf_file in args.config:
        # with a timeout, the next tests are still reported
        if ep.interrupted and not ep.graceful:
            logger.warning(f"Interrupted: skipping {conf_file}")
            continue
        with open(conf_file) as c:
            config = yaml.safe_load(c)
        result, rc = ep.run_tests(id, config, args.test_only)
        results.update(result)
        # keep the lowest error code, e.g. errors (1) before fails (42)
        if rc > 0 and (exit == 0 or rc < exit):
            exit = rc
        id += 1

    signal.alarm(0)

    # keep the results of the suites that have not been checked again
    if args.reg_only or args.validation_only:
        prev = ep.prev_results
        # just in case --test-only is used: keep the other tests
        for suite, tests in results.items():
            tests = {str(id): t for id, t in tests.items()}
            prev[suite] = prev.get(suite, {}) | tests
        results = prev

    # always next to the logs, e.g. for 'analyze' in entrypoint.sh
    with open(os.path.join(args.log_dir, "perf.json"), "w") as f:
        json.dump(results, f)

    if args.json:
        if args.json_only_fails:
            results = only_fails(results)

        if args.info or ep.outliers:
            results = {"results": results}
            if args.info:
                add_infos(results, args.info)
            # also when filtering: to be reviewed, e.g. for passing tests
            if ep.outliers:
                results["outliers"] = "\n".join(ep.outliers)

        with open(args.json, "w") as f:
            json.dump(results, f)

        # No exit with a specific code when emitting JSON here: output is parsed
        return

    if exit:
        sys.exit(exit)


if __name__ == "__main__":
    main()
