"""Small TOML configuration with environment overrides and no secret output."""

import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path


class ConfigError(Exception):
    """An actionable local configuration failure."""


@dataclass(frozen=True)
class Config:
    home: Path
    config_path: Path
    forvo_key: str | None = field(default=None, repr=False)
    mw_key: str | None = field(default=None, repr=False)
    voice: str | None = None
    uk_voice: str | None = None
    wikimedia_user_agent: str | None = None


def load_config() -> Config:
    default = Path.home() / "Library" / "Application Support" / "pron"
    initial = Path(os.environ.get("PRON_HOME", str(default))).expanduser()
    path = Path(os.environ.get("PRON_CONFIG", str(initial / "config.toml"))).expanduser()
    data: dict[str, object] = {}
    try:
        if path.exists():
            with path.open("rb") as stream:
                data = tomllib.load(stream)
        elif "PRON_CONFIG" in os.environ:
            raise ConfigError(f"Config file does not exist: {path}")
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise ConfigError(f"Cannot read config file: {path}") from exc

    def value(name: str, env: str | None = None) -> str | None:
        raw = os.environ.get(env) if env else None
        item = raw if raw is not None else data.get(name)
        if item is None:
            return None
        if not isinstance(item, str) or not item.strip():
            raise ConfigError(f"{name} must be a non-empty string")
        return item.strip()

    home = Path(value("cache_dir", "PRON_HOME") or str(initial)).expanduser().resolve()
    return Config(
        home=home,
        config_path=path.resolve(),
        forvo_key=value("forvo_api_key", "FORVO_API_KEY"),
        mw_key=value("mw_api_key", "MW_API_KEY"),
        voice=value("voice", "PRON_VOICE"),
        uk_voice=value("uk_voice", "PRON_UK_VOICE"),
        wikimedia_user_agent=value("wikimedia_user_agent"),
    )
