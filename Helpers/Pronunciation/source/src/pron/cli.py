"""Command entry point: text first, machine output when requested, local playback."""

import argparse
import json
import os
import signal
import subprocess
import sys
import tempfile
from collections.abc import Callable, Iterator, Sequence
from contextlib import contextmanager
from dataclasses import asdict, replace
from pathlib import Path
from typing import Any, Never

from pron.cache import Cache, CacheError
from pron.config import Config, ConfigError, load_config
from pron.http import HttpClient
from pron.models import AudioHit, Source, SourceError, Transcription
from pron.resolver import Resolution, Resolver, normalize
from pron.sources.cmudict import CmudictSource
from pron.sources.forvo import ForvoSource
from pron.sources.mw import MerriamWebsterSource
from pron.sources.say import (
    SpeechError,
    cancellable_playback,
    choose_voice,
    clipboard_text,
    play_file,
    speak,
)
from pron.sources.wiktionary import WiktionarySource
from pron.sources.youglish import open_youglish, youglish_url


class Parser(argparse.ArgumentParser):
    def error(self, message: str) -> Never:
        raise ConfigError(message)


def parser(command: str) -> Parser:
    result = Parser(
        prog="pron" if command == "lookup" else f"pron {command}",
        allow_abbrev=command != "lookup",
    )
    if command == "lookup":
        output = result.add_mutually_exclusive_group()
        output.add_argument("--json", action="store_true", help="print one JSON object")
        output.add_argument(
            "--json-events", action="store_true", help="stream versioned JSON events"
        )
        result.description = "English IPA and audio. With no term, read the clipboard."
        result.epilog = "Commands: pron say TEXT, pron sources, pron cache stats|clear"
        result.add_argument("term", nargs="*")
        result.add_argument("--stdin-term", action="store_true", help=argparse.SUPPRESS)
        result.add_argument("--stdin-json", action="store_true", help=argparse.SUPPRESS)
        result.add_argument("--uk", action="store_true", help="prefer UK IPA and audio")
        result.add_argument("--no-audio", action="store_true", help="text only; no audio fetch")
        result.add_argument("--all", action="store_true", help="include every available source")
        result.add_argument(
            "--offline", action="store_true", help="use only local dictionary and speech"
        )
        result.add_argument("--source", choices=["wiktionary", "cmudict", "forvo", "mw", "say"])
        result.add_argument("--open", action="store_true", help="open Youglish")
    else:
        result.add_argument("--json", action="store_true", help="print one JSON object")
    if command == "say":
        result.add_argument("sentence", nargs="+", help="English sentence to speak")
        result.add_argument("--voice")
        rates = result.add_mutually_exclusive_group()
        rates.add_argument("--rate", type=int, metavar="WPM")
        rates.add_argument("--slow", action="store_true", help="speak at 120 words per minute")
        result.add_argument("--open", action="store_true", help="also open Youglish")
    elif command == "cache":
        result.add_argument("action", choices=["stats", "clear"])
    return result


def print_ipa(items: list[Transcription]) -> None:
    if not items:
        print("  —    no dictionary transcription found", flush=True)
    for item in items:
        ipa = item.ipa
        if not (ipa.startswith("[") and ipa.endswith("]")):
            ipa = f"/{ipa.strip('/')}/"
        qualifiers = ", ".join(
            tag
            for tag in item.raw_tags
            if tag not in {"US", "UK", "General-American", "Received-Pronunciation"}
        )
        details = "; ".join(part for part in (item.pos, qualifiers, item.note) if part)
        qualification = f" ({details})" if details else ""
        print(f"  {item.accent:<12} {ipa:<30} {item.source}{qualification}", flush=True)


def audio_description(hit: AudioHit) -> str:
    votes = f" · {hit.votes} votes" if hit.votes is not None else ""
    state = " [cached]" if hit.cached else " [online only]" if not hit.cacheable else ""
    return f"  ▶ {hit.source} · {hit.attribution} · {hit.accent}{votes}{state}"


def emit_json(value: object) -> None:
    print(json.dumps(value, ensure_ascii=False))


def emit_event(event: str, **fields: object) -> None:
    print(json.dumps({"version": 1, "event": event, **fields}, ensure_ascii=False), flush=True)


def audio_json(hit: AudioHit) -> dict[str, object]:
    return {
        "source": hit.source,
        "accent": hit.accent,
        "attribution": hit.attribution,
        "votes": hit.votes,
        "path": hit.path if hit.cacheable else None,
        "cached": hit.cached,
        "online": not hit.cacheable,
        "source_url": hit.source_url,
        "license": hit.license,
    }


def audio_event(hit: AudioHit, voice: str | None = None) -> None:
    # Source URLs are attribution metadata in the final result, but the stream
    # carries no URLs or transient playback paths to its UI consumer.
    public = audio_json(hit)
    public.pop("source_url")
    emit_event("audio", audio=public, voice=voice, synthetic=False)


def result_json(result: Resolution, url: str) -> dict[str, object]:
    audio = [audio_json(hit) for hit in result.audio]
    if result.synthetic:
        audio.append(
            {
                "source": "say",
                "accent": "synthetic",
                "attribution": result.voice,
                "path": None,
                "cached": False,
                "synthetic": True,
            }
        )
    return {
        "term": result.term,
        "transcriptions": [asdict(item) for item in result.transcriptions],
        "audio": audio,
        "respellings": [asdict(item) for item in result.respellings],
        "played": result.played,
        "youglish": url,
        "errors": result.errors,
        "exit_code": result.exit_code,
    }


def configured_sources(
    config: Config, client: HttpClient, offline: bool = False
) -> dict[str, Source]:
    sources: dict[str, Source] = {
        "cmudict": CmudictSource(),
    }
    if offline:
        return sources
    # Wikimedia requires an application/operator contact. Until Glacier has
    # an approved public identity, its remote source stays unavailable.
    if config.wikimedia_user_agent:
        sources["wiktionary"] = WiktionarySource(client)
    if config.forvo_key:
        sources["forvo"] = ForvoSource(client, config.forvo_key)
    if config.mw_key:
        sources["mw"] = MerriamWebsterSource(client, config.mw_key)
    return sources


def lookup(args: argparse.Namespace, config: Config, cache: Cache) -> int:
    if ((args.stdin_term or args.stdin_json) and args.term) or (
        args.stdin_term and args.stdin_json
    ):
        raise ConfigError("Choose one explicit pronunciation input source")
    if args.json_events and not args.term and not args.stdin_term and not args.stdin_json:
        raise ConfigError("--json-events requires an explicit non-empty term")
    if args.stdin_json:
        incoming = args.request_term
    elif args.stdin_term:
        incoming = sys.stdin.read(4_097)
        if len(incoming.encode("utf-8")) > 4_096:
            raise ConfigError("Pronunciation input is too long")
    else:
        incoming = " ".join(args.term) if args.term else clipboard_text()
    term = normalize(incoming)
    if not term:
        raise ConfigError(
            "--json-events requires an explicit non-empty term"
            if args.json_events
            else "No text to look up; copy a word or pass a term"
        )
    if args.offline and args.open:
        raise ConfigError("Youglish cannot open while offline")
    if args.offline and args.source not in (None, "cmudict", "say"):
        raise ConfigError("That pronunciation source requires network access")
    if args.source == "forvo" and not config.forvo_key:
        raise ConfigError(
            "Forced source forvo requires FORVO_API_KEY or forvo_api_key in config.toml"
        )
    if args.source == "mw" and not config.mw_key:
        raise ConfigError("Forced source mw requires MW_API_KEY or mw_api_key in config.toml")
    if not (args.json or args.json_events):
        print(term, flush=True)
    url = youglish_url(term, uk=args.uk)
    client = HttpClient(
        offline=args.offline, user_agent=config.wikimedia_user_agent or "Glacier/0.1"
    )
    try:
        with tempfile.TemporaryDirectory(prefix="pron-play-") as temporary:
            sequence = 0

            def prepare_online(hit: AudioHit) -> AudioHit:
                nonlocal sequence
                if hit.path:
                    return hit
                if not hit.url:
                    raise SourceError(hit.source, "No playable recording URL")
                sequence += 1
                destination = Path(temporary) / f"recording-{sequence}.mp3"
                client.download(hit.url, destination, hit.source)
                return replace(hit, path=str(destination))

            def play_selected(hit: AudioHit) -> None:
                if not hit.path:
                    raise SourceError(hit.source, "Recording has no local playback file")
                if args.json_events:
                    audio_event(hit)
                elif not args.json:
                    print(audio_description(hit), flush=True)
                    if hit.source == "forvo":
                        print("  Pronunciations by Forvo · https://forvo.com", flush=True)
                try:
                    play_file(hit.path)
                except SpeechError as exc:
                    raise SourceError(hit.source, str(exc)) from exc

            resolver = Resolver(
                cache,
                configured_sources(config, client, offline=args.offline),
                client.download,
                prepare_online,
                play_selected,
            )
            on_transcriptions: Callable[[list[Transcription]], None] | None
            if args.json_events:

                def stream_transcriptions(items: list[Transcription]) -> None:
                    emit_event(
                        "transcriptions", term=term, transcriptions=[asdict(item) for item in items]
                    )

                on_transcriptions = stream_transcriptions
            else:
                on_transcriptions = None if args.json else print_ipa
            result = resolver.resolve(
                term,
                uk=args.uk,
                all_sources=args.all,
                forced_source=args.source,
                want_audio=not args.no_audio,
                on_transcriptions=on_transcriptions,
            )
            if args.all and not (args.json or args.json_events):
                for entry in result.respellings:
                    print(f"  {entry.source} respelling: {entry.text}", flush=True)
                for hit in result.audio:
                    print(audio_description(hit), flush=True)
                    if hit.source_url:
                        print(f"    {hit.source_url}", flush=True)
            if result.audio and not args.no_audio and not result.played:
                for hit in result.audio:
                    try:
                        playable = prepare_online(hit) if not hit.cacheable else hit
                        if not playable.path:
                            raise SpeechError("Recording has no local playback file")
                        if args.json_events:
                            audio_event(hit)
                        elif not args.json and not args.all:
                            print(audio_description(hit), flush=True)
                        if hit.source == "forvo" and not (args.json or args.json_events):
                            print("  Pronunciations by Forvo · https://forvo.com", flush=True)
                        play_file(playable.path)
                        result.played = hit.path if hit.cacheable else "forvo:online"
                        break
                    except (SpeechError, SourceError) as exc:
                        result.errors.append({"source": hit.source, "message": str(exc)})
                if result.played is None and args.source is None:
                    result.synthetic = True
            if result.synthetic and not args.no_audio:
                try:
                    result.voice = choose_voice(
                        config.uk_voice if args.uk else config.voice, uk=args.uk
                    )
                    if args.json_events:
                        emit_event(
                            "audio",
                            audio={
                                "source": "say",
                                "accent": "synthetic",
                                "attribution": result.voice,
                                "path": None,
                                "cached": False,
                                "synthetic": True,
                            },
                            voice=result.voice,
                            synthetic=True,
                        )
                    elif not args.json:
                        print(f"  ▶ say · {result.voice} · synthetic", flush=True)
                    speak(term, result.voice)
                    result.played = f"say:{result.voice}"
                except SpeechError as exc:
                    result.errors.append({"source": "say", "message": str(exc)})
            if args.open:
                try:
                    open_youglish(url)
                except SpeechError as exc:
                    result.errors.append({"source": "youglish", "message": str(exc)})
            if args.json_events:
                emit_event("complete", result=result_json(result, url))
            elif args.json:
                emit_json(result_json(result, url))
            else:
                print(f"  Youglish · {url}")
                for error in result.errors:
                    print(f"  ! {error['source']}: {error['message']}", file=sys.stderr)
            return result.exit_code
    finally:
        client.close()


def request_config(args: argparse.Namespace) -> Config:
    """Read one bounded app request; never load config, dotenv or inherited keys."""
    raw = sys.stdin.buffer.read(16_385)
    if len(raw) > 16_384:
        raise ConfigError("Pronunciation request is too large")
    try:
        payload = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ConfigError("Pronunciation request is invalid") from exc
    required = {"term", "offline", "accent"}
    optional = {"voice", "uk_voice", "wikimedia_user_agent", "forvo_key", "mw_key"}
    if (
        not isinstance(payload, dict)
        or not required.issubset(payload)
        or not set(payload).issubset(required | optional)
    ):
        raise ConfigError("Pronunciation request has invalid fields")
    term = payload["term"]
    offline = payload["offline"]
    accent = payload["accent"]
    if (
        not isinstance(term, str)
        or not term.strip()
        or len(term.encode("utf-8")) > 4_096
        or type(offline) is not bool
        or not isinstance(accent, str)
        or accent not in {"us", "uk"}
    ):
        raise ConfigError("Pronunciation request has invalid input")

    def optional_text(name: str, limit: int) -> str | None:
        value = payload.get(name)
        if value is None:
            return None
        if not isinstance(value, str) or not value.strip() or len(value.encode("utf-8")) > limit:
            raise ConfigError("Pronunciation request has invalid preferences")
        if any(ord(character) < 32 or ord(character) == 127 for character in value):
            raise ConfigError("Pronunciation request has invalid preferences")
        return value.strip()

    home = os.environ.get("PRON_HOME")
    if not home or not Path(home).is_absolute():
        raise ConfigError("Pronunciation cache path is unavailable")
    root = Path(home).resolve()
    config = Config(home=root, config_path=root / "unused-config.toml")
    effective_offline = args.offline or offline
    config = replace(
        config,
        forvo_key=None if effective_offline else optional_text("forvo_key", 4_096),
        mw_key=None if effective_offline else optional_text("mw_key", 4_096),
        voice=optional_text("voice", 100),
        uk_voice=optional_text("uk_voice", 100),
        wikimedia_user_agent=None
        if effective_offline
        else optional_text("wikimedia_user_agent", 512),
    )
    args.request_term = term
    args.offline = effective_offline
    args.uk = accent == "uk"
    return config


def say_command(args: argparse.Namespace, config: Config) -> int:
    sentence = normalize(" ".join(args.sentence))
    if not sentence:
        raise ConfigError("Provide a non-empty sentence")
    rate = 120 if args.slow else args.rate
    if rate is not None and rate <= 0:
        raise ConfigError("--rate must be a positive words-per-minute value")
    voice = choose_voice(args.voice or config.voice)
    url = youglish_url(sentence)
    if not args.json:
        print(f"  ▶ say · {voice} · synthetic", flush=True)
    speak(sentence, voice, rate)
    if args.open:
        open_youglish(url)
    if args.json:
        emit_json(
            {
                "term": sentence,
                "voice": voice,
                "rate": rate,
                "synthetic": True,
                "played": f"say:{voice}",
                "youglish": url,
                "exit_code": 0,
            }
        )
    else:
        print(f"  Youglish · {url}")
    return 0


def sources_command(args: argparse.Namespace, config: Config, cache: Cache) -> int:
    status = cache.source_status()
    rows: list[dict[str, Any]] = []
    for name, enabled in (
        ("wiktionary", True),
        ("cmudict", True),
        ("forvo", bool(config.forvo_key)),
        ("mw", bool(config.mw_key)),
        ("say", True),
    ):
        rows.append(
            {
                "source": name,
                "configured": enabled,
                "key_present": enabled if name in {"forvo", "mw"} else None,
                **status.get(name, {}),
            }
        )
    if args.json:
        emit_json(
            {
                "sources": rows,
                "cache_dir": str(config.home),
                "config_file": str(config.config_path),
                "exit_code": 0,
            }
        )
    else:
        for row in rows:
            quota = row.get("quota_remaining")
            print(
                f"{row['source']:<12} {'ready' if row['configured'] else 'key not configured'}"
                f" · quota: {quota if quota is not None else 'unknown'}"
            )
        print("Forvo: online only; Pronunciations by Forvo · https://forvo.com")
        print("Merriam-Webster's Collegiate® Dictionary · https://dictionaryapi.com")
        print(f"Cache: {config.home}\nConfig: {config.config_path}")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    option_end = arguments.index("--") if "--" in arguments else len(arguments)
    json_mode = "--json" in arguments[:option_end]
    event_mode = "--json-events" in arguments[:option_end]
    command = (
        arguments.pop(0) if arguments and arguments[0] in {"say", "sources", "cache"} else "lookup"
    )
    try:
        with event_sigterm_handler(event_mode), cancellable_playback(event_mode):
            return _run_with_handler(arguments, command, json_mode, event_mode)
    except KeyboardInterrupt:
        return 130


@contextmanager
def event_sigterm_handler(enabled: bool) -> Iterator[None]:
    if not enabled:
        yield
        return

    def cancel(_signal: int, _frame: object) -> Never:
        raise KeyboardInterrupt

    previous = signal.signal(signal.SIGTERM, cancel)
    try:
        yield
    finally:
        signal.signal(signal.SIGTERM, previous)


def _run_with_handler(arguments: list[str], command: str, json_mode: bool, event_mode: bool) -> int:
    cache: Cache | None = None
    try:
        if event_mode and ("--help" in arguments or "-h" in arguments):
            raise ConfigError("Help is unavailable with --json-events")
        args = parser(command).parse_args(arguments)
        config = request_config(args) if command == "lookup" and args.stdin_json else load_config()
        if command == "say":
            return say_command(args, config)
        cache = Cache(config.home)
        if command == "sources":
            return sources_command(args, config, cache)
        if command == "cache":
            stats = cache.clear() if args.action == "clear" else cache.stats()
            if args.json:
                emit_json({"action": args.action, **stats, "exit_code": 0})
            else:
                print("Cache cleared" if args.action == "clear" else "Cache statistics")
                for name, value in stats.items():
                    print(f"  {name}: {value}")
            return 0
        return lookup(args, config, cache)
    except (ConfigError, CacheError) as exc:
        code = 3
        message = str(exc)
    except (SpeechError, SourceError) as exc:
        code = 2
        message = str(exc)
    except (OSError, subprocess.SubprocessError) as exc:
        code = 2
        message = "Local operation failed" if event_mode else str(exc)
    except KeyboardInterrupt:
        return 130
    finally:
        if cache:
            cache.close()
    if event_mode:
        emit_event("error", message=message, exit_code=code)
    elif json_mode:
        emit_json({"error": message, "exit_code": code})
    else:
        print(f"pron: {message}", file=sys.stderr)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
