"""Installed package version, read from package metadata.

The version lives only in ``pyproject.toml``; hardcoding it here drifted
(``__version__`` and the routine manifest still said ``0.5.0`` at v0.5.4).
"""

import importlib.metadata as _meta

try:
    __version__ = _meta.version("autonomon")
except _meta.PackageNotFoundError:  # pragma: no cover
    __version__ = "unknown"
