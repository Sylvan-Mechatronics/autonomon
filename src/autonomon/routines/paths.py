"""Confine file paths supplied as routine *params* to operator-approved directories.

Routine params arrive from the device API (an authenticated app user, or the
AI relay) and are forwarded verbatim by nomothetic. Params such as
``model_path``, ``model_config``, and ``rules_path`` name files that the brain
then feeds to large native parsers (onnxruntime, ``cv2.dnn``, tomllib). Review
finding S-10: without confinement a caller can point those parsers at any
readable file on the device.

Paths that come from autonomon's own environment file (written at deploy time
by an operator) are trusted and are **not** passed through here.
"""

from __future__ import annotations

import os
from collections.abc import Iterable
from pathlib import Path

DEFAULT_MODEL_DIR = "/var/lib/nomon/models"


def model_dirs() -> list[Path]:
    """Directories a ``model_path``/``model_config`` param may point into."""
    return [Path(os.environ.get("NOMON_MODEL_DIR", DEFAULT_MODEL_DIR))]


def rules_dirs(bundled: Path) -> list[Path]:
    """Directories a ``rules_path`` param may point into: bundled plus ``NOMON_RULES_DIR``."""
    dirs = [bundled]
    extra = os.environ.get("NOMON_RULES_DIR", "").strip()
    if extra:
        dirs.append(Path(extra))
    return dirs


def confine_param_path(value: str, allowed: Iterable[Path], label: str) -> str:
    """Return *value* if it resolves inside one of *allowed*; otherwise raise.

    Symlinks are resolved before the check so a link inside an allowed
    directory cannot escape it.

    Parameters
    ----------
    value : str
        Path supplied as a routine param.
    allowed : iterable of pathlib.Path
        Directories the path must live under.
    label : str
        Param name for the error message.

    Raises
    ------
    ValueError
        If the path is empty, relative, or outside every allowed directory.
    """
    if not value or not os.path.isabs(value):
        raise ValueError(f"{label} must be an absolute path inside an allowed directory")
    resolved = Path(value).resolve()
    for root in allowed:
        try:
            resolved.relative_to(Path(root).resolve())
            return value
        except ValueError:
            continue
    roots = ", ".join(str(r) for r in allowed)
    raise ValueError(f"{label} must be inside one of: {roots}")
