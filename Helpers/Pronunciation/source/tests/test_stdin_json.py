"""The bundled app request is isolated from ambient config and network access."""

import io
import json
import sys
from pathlib import Path

import pytest

from pron.cli import parser, request_config
from pron.config import ConfigError


def _stdin(monkeypatch: pytest.MonkeyPatch, payload: object) -> None:
    stream = io.TextIOWrapper(io.BytesIO(json.dumps(payload).encode("utf-8")))
    monkeypatch.setattr(sys, "stdin", stream)


def test_stdin_json_builds_request_config_without_ambient_keys(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("PRON_HOME", str(tmp_path))
    monkeypatch.setenv("FORVO_API_KEY", "ambient-key-must-not-be-read")
    _stdin(
        monkeypatch,
        {
            "term": "epitome",
            "offline": False,
            "accent": "uk",
            "voice": "Samantha",
            "uk_voice": None,
            "wikimedia_user_agent": "Glacier/0.1 contact=person@example.test",
            "forvo_key": "selected-forvo-key",
            "mw_key": None,
        },
    )
    args = parser("lookup").parse_args(["--stdin-json", "--json-events"])
    config = request_config(args)
    assert config.forvo_key == "selected-forvo-key"
    assert config.mw_key is None
    assert config.home == tmp_path
    assert args.request_term == "epitome"
    assert args.uk is True


def test_stdin_json_offline_disables_remote_sources_even_with_supplied_keys(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("PRON_HOME", str(tmp_path))
    _stdin(
        monkeypatch,
        {
            "term": "epitome",
            "offline": True,
            "accent": "us",
            "forvo_key": "not-used",
            "mw_key": "not-used",
            "wikimedia_user_agent": "Glacier/0.1 contact=person@example.test",
        },
    )
    args = parser("lookup").parse_args(["--stdin-json", "--json-events"])
    config = request_config(args)
    assert args.offline is True
    assert config.forvo_key is None
    assert config.mw_key is None
    assert config.wikimedia_user_agent is None


def test_stdin_json_rejects_unknown_fields_and_header_controls(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("PRON_HOME", str(tmp_path))
    args = parser("lookup").parse_args(["--stdin-json", "--json-events"])
    _stdin(monkeypatch, {"term": "epitome", "offline": True, "accent": "us", "extra": "x"})
    with pytest.raises(ConfigError, match="invalid fields"):
        request_config(args)
    _stdin(
        monkeypatch,
        {
            "term": "epitome",
            "offline": False,
            "accent": "us",
            "wikimedia_user_agent": "Glacier/0.1\r\nX-Injected: yes",
        },
    )
    with pytest.raises(ConfigError, match="invalid preferences"):
        request_config(args)
