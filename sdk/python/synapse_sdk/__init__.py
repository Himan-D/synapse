"""Synapse Python SDK — instrument harnesses and call agent verbs."""

from .client import Synapse
from . import pipes, instrument

__all__ = ["Synapse", "pipes", "instrument"]
__version__ = "0.3.0"
