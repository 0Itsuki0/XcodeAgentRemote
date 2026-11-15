"""Small helpers shared by the store, the cards and the providers."""

from __future__ import annotations

import subprocess
import sys
from datetime import datetime, timezone
from typing import NoReturn


def now() -> datetime:
    """Current time as a naive UTC datetime (plistlib writes naive datetimes as UTC)."""
    return datetime.now(timezone.utc).replace(tzinfo=None)


def run(args: list[str], cwd: str | None = None) -> str | None:
    """Run a command; return its stdout, or None if it failed."""
    try:
        p = subprocess.run(args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    except OSError:
        return None
    return p.stdout if p.returncode == 0 else None


def fail(message: str) -> NoReturn:
    sys.exit("error: " + message)


def read_text(path: str) -> str | None:
    """A text file's content, or None if it does not exist or is not text."""
    try:
        with open(path) as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return None
