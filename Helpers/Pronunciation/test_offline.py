"""Synthetic offline checks; no dictionary lookup, network request, or audio."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "source" / "src"))

import httpx  # noqa: E402

from pron.cli import configured_sources, parser  # noqa: E402
from pron.config import Config  # noqa: E402
from pron.http import HttpClient  # noqa: E402
from pron.models import SourceError  # noqa: E402


class OfflineTests(unittest.TestCase):
    def test_http_client_rejects_requests_and_downloads_before_transport(self) -> None:
        calls: list[httpx.Request] = []

        def record(request: httpx.Request) -> httpx.Response:
            calls.append(request)
            return httpx.Response(200, json={})

        with httpx.Client(transport=httpx.MockTransport(record)) as base:
            client = HttpClient(client=base, offline=True)
            with self.assertRaises(SourceError):
                client.get_json("https://example.invalid/word", "synthetic")
            with tempfile.TemporaryDirectory() as folder:
                with self.assertRaises(SourceError):
                    client.download(
                        "https://example.invalid/audio",
                        Path(folder) / "audio.mp3",
                        "synthetic",
                    )
            self.assertEqual(calls, [])

    def test_offline_sources_exclude_every_remote_provider(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            config = Config(
                home=root,
                config_path=root / "config.toml",
                forvo_key="synthetic",
                mw_key="synthetic",
                wikimedia_user_agent="synthetic-contact",
            )
            with httpx.Client(
                transport=httpx.MockTransport(lambda _: httpx.Response(500))
            ) as base:
                sources = configured_sources(
                    config, HttpClient(client=base, offline=True), offline=True
                )
            self.assertEqual(set(sources), {"cmudict"})

    def test_client_protocol_has_explicit_stdin_and_offline_flags(self) -> None:
        options = parser("lookup").parse_args(
            ["--json-events", "--stdin-term", "--offline"]
        )
        self.assertTrue(options.json_events)
        self.assertTrue(options.stdin_term)
        self.assertTrue(options.offline)


if __name__ == "__main__":
    unittest.main()
