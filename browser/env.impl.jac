"""Implementation of the config loader."""

impl _load_env_file {
    # Fast path: already loaded, no lock needed.
    if _ENV_STATE.get("loaded") {
        return;
    }
    with _ENV_LOCK {
        # Re-check inside the lock: another lane may have loaded while we waited.
        if _ENV_STATE.get("loaded") {
            return;
        }
        _load_env_locked();
        # Set last, so no thread can see a partially-filled cache as complete.
        _ENV_STATE["loaded"] = True;
    }
}


impl _load_env_locked {
    here = Path(str(__file__)).resolve();
    for parent in here.parents {
        candidate = parent / ".env";
        if candidate.is_file() {
            for raw in candidate.read_text().splitlines() {
                line = raw.strip();
                if (not line) or line.startswith("#") or ("=" not in line) {
                    continue;
                }
                (key, _, value) = line.partition("=");
                value = value.strip();
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'" {
                    value = value[1:-1];
                }
                _ENV_CACHE[key.strip()] = value;
            }
            _ENV_STATE["path"] = str(candidate);
            return;
        }
    }
}


impl env(key: str, fallback: (str | None) = None, required: bool = False) -> str {
    # A real environment variable always wins over the file.
    value = os.environ.get(key);
    if not value {
        _load_env_file();
        value = _ENV_CACHE.get(key);
    }
    if not value {
        if required {
            raise RuntimeError(
                f"required config {key} is not set (checked the environment and "
                f"{_ENV_STATE.get('path', 'no .env found')})"
            );
        }
        return fallback if fallback is not None else "";
    }
    return value;
}
