"""burn_weights.py - the cache-read price per model for the eval scripts.

Reads scripts/lanes/lib/cache-read-weights.tsv, the one table scripts/lanes/lib/burn-weights.sh
also reads. A model with no row, or none given, reads at the default (0.1);
WORKER_SESSION_BURN_W_CACHE_READ set in the environment prices every model flat.
"""
import os

_TABLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lanes", "lib", "cache-read-weights.tsv")
_FLAT = os.environ.get("WORKER_SESSION_BURN_W_CACHE_READ")
DEFAULT = float(_FLAT) if _FLAT is not None else 0.1
_ROWS = []
with open(_TABLE) as _f:
    for _line in _f:
        _parts = _line.rstrip("\n").split("\t")
        if len(_parts) == 2 and not _parts[0].startswith("#"):
            _ROWS.append((_parts[0], float(_parts[1])))


def cache_read_weight(model):
    if _FLAT is not None:
        return DEFAULT
    for prefix, weight in _ROWS:
        if model and model.startswith(prefix):
            return weight
    return DEFAULT


def result_model(result):
    """The model a `claude -p --output-format json` result ran on: the first modelUsage key, else None."""
    usage = result.get("modelUsage") if isinstance(result, dict) else None
    return next(iter(usage), None) if isinstance(usage, dict) and usage else None


def is_known(model):
    return bool(model) and any(model.startswith(p) for p, _ in _ROWS)
