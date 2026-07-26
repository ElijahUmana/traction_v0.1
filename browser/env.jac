"""Process configuration: real environment first, .env file as a fallback.

Kept deliberately small and dependency-free so the browser stack can be run
standalone (`jac run traction/browser/live_proof.jac`) before the wider app
config layer exists.
"""

import os;
import from pathlib { Path }

glob _ENV_CACHE: dict = {};
glob _ENV_STATE: dict = {};

"""Walk up from this file looking for a .env and parse it once."""
def _load_env_file;

"""Read a config key. Raises if it is required and absent — a missing API key
should fail at the top of a run, not halfway through a live browser session."""
def env(key: str, fallback: (str | None) = None, required: bool = False) -> str;
