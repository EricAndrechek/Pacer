"""`arena leakcheck`: the public-repo leak check (see arena/leakcheck.py).
Also runnable before the command is registered: `python -m arena.cli_leakcheck`."""
from __future__ import annotations

import sys

from arena.leakcheck import add_args, run


def register(subparsers) -> None:
    p = subparsers.add_parser("leakcheck", help="scan tracked files, staged content or a commit message "
                                                "for identifiers, money figures and data files")
    add_args(p)
    p.set_defaults(func=run)


def main(argv: list[str] | None = None) -> int:
    import argparse
    p = argparse.ArgumentParser(prog="arena leakcheck")
    add_args(p)
    return run(p.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
