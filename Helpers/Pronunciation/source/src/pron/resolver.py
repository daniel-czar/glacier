"""Independent IPA/audio cascades with cache-first reuse and attributed failures."""

import unicodedata
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from pron.cache import Cache
from pron.models import AudioHit, Respelling, Source, SourceError, SourceResult, Transcription

IPA_SOURCES = ("wiktionary", "cmudict")
AUDIO_SOURCES = ("forvo", "wiktionary", "mw")


def normalize(term: str) -> str:
    return " ".join(unicodedata.normalize("NFC", term).split())


def variants(term: str) -> list[str]:
    base = normalize(term)
    candidates = [base, base.lower()]
    for candidate in candidates.copy():
        candidates.extend((candidate.replace("-", " "), candidate.replace(" ", "-")))
    return list(dict.fromkeys(candidates))


def accent_rank(accent: str, uk: bool) -> int:
    if accent in ({"UK", "GB", "GBR"} if uk else {"GA", "US", "USA"}):
        return 0
    if accent in {"GA", "US", "USA", "UK", "GB", "GBR"}:
        return 1
    return 3 if accent == "unspecified" else 2


@dataclass
class Resolution:
    term: str
    transcriptions: list[Transcription] = field(default_factory=list)
    audio: list[AudioHit] = field(default_factory=list)
    respellings: list[Respelling] = field(default_factory=list)
    errors: list[dict[str, str]] = field(default_factory=list)
    synthetic: bool = False
    played: str | None = None
    voice: str | None = None

    @property
    def exit_code(self) -> int:
        if self.errors:
            return 2
        return 0 if self.transcriptions or self.audio else 1


class Resolver:
    def __init__(
        self,
        cache: Cache,
        sources: dict[str, Source],
        download: Callable[[str, Path, str], None],
        prepare_online: Callable[[AudioHit], AudioHit] | None = None,
        play_audio: Callable[[AudioHit], None] | None = None,
    ):
        self.cache = cache
        self.sources = sources
        self.download = download
        self.prepare_online = prepare_online
        self.play_audio = play_audio

    def resolve(
        self,
        term: str,
        *,
        uk: bool = False,
        all_sources: bool = False,
        forced_source: str | None = None,
        want_audio: bool = True,
        on_transcriptions: Callable[[list[Transcription]], None] | None = None,
    ) -> Resolution:
        result = Resolution(term=term)
        key = normalize(term)
        self.cache.record_term(key, term)
        memo: dict[tuple[str, str], SourceResult] = {}
        failed_sources: set[str] = set()

        def failure(name: str, exc: SourceError) -> None:
            result.errors.append({"source": name, "message": str(exc)})
            self.cache.log_source(name, False, exc.quota_remaining)

        def lookup(name: str, kind: str) -> SourceResult:
            combined = SourceResult()
            for candidate in variants(key):
                identity = (name, candidate)
                if identity not in memo:
                    if name in failed_sources:
                        break
                    try:
                        memo[identity] = self.sources[name].lookup(candidate)
                        self.cache.log_source(name, True, memo[identity].quota_remaining)
                    except SourceError as exc:
                        failure(name, exc)
                        failed_sources.add(name)
                        break
                response = memo[identity]
                if response.transcriptions and not combined.transcriptions:
                    combined.transcriptions = response.transcriptions
                if response.audio and not combined.audio:
                    combined.audio = response.audio
                combined.respellings.extend(response.respellings)
                if (kind == "ipa" and response.transcriptions) or (
                    kind == "audio" and response.audio
                ):
                    break
            if combined.transcriptions:
                self.cache.store_transcriptions(key, name, combined.transcriptions)
            found = combined.transcriptions if kind == "ipa" else combined.audio
            if not found and name not in failed_sources:
                self.cache.store_miss(key, name, kind)
            if all_sources:
                result.respellings.extend(combined.respellings)
                result.respellings = list(dict.fromkeys(result.respellings))
            return combined

        ipa_names = [
            name
            for name in IPA_SOURCES
            if name in self.sources and (forced_source is None or forced_source == name)
        ]
        if not all_sources:
            for name in ipa_names:
                cached = self.cache.load_transcriptions(key, name)
                if cached:
                    result.transcriptions = cached
                    break
        if not result.transcriptions or all_sources:
            for name in ipa_names:
                cached = self.cache.load_transcriptions(key, name)
                if cached:
                    result.transcriptions.extend(cached)
                elif not self.cache.is_miss(key, name, "ipa"):
                    result.transcriptions.extend(lookup(name, "ipa").transcriptions)
                if result.transcriptions and not all_sources:
                    break
        result.transcriptions = sorted(
            dict.fromkeys(result.transcriptions), key=lambda item: accent_rank(item.accent, uk)
        )
        if on_transcriptions:
            on_transcriptions(result.transcriptions)

        def rank(hit: AudioHit) -> tuple[int, int]:
            return accent_rank(hit.accent, uk), -(hit.votes or 0)

        attempted: set[tuple[str, str]] = set()

        def accept(hit: AudioHit) -> bool:
            """Materialize and optionally play; an unusable hit never stops the cascade."""
            identity = (hit.source, hit.path or hit.url or "")
            if identity in attempted:
                return False
            attempted.add(identity)
            try:
                if hit.cacheable and not hit.path:
                    hit = self.cache.store_audio(key, hit, self.download)
                    local_identity = (hit.source, hit.path or "")
                    if local_identity in attempted:
                        return False
                    attempted.add(local_identity)
                elif not hit.cacheable and not all_sources and self.prepare_online:
                    hit = self.prepare_online(hit)
                if self.play_audio and not all_sources:
                    self.play_audio(hit)
                    result.played = hit.path if hit.cacheable else f"{hit.source}:online"
                result.audio.append(hit)
                return True
            except SourceError as exc:
                failure(hit.source, exc)
                return False

        if want_audio:
            audio_names = [
                name for name in AUDIO_SOURCES if forced_source is None or forced_source == name
            ]
            cached_audio = [
                hit
                for hit in self.cache.load_audio(key, forced_source)
                if hit.source in audio_names
            ]
            cached_audio.sort(key=rank)
            if not all_sources:
                for hit in cached_audio:
                    if accept(hit):
                        break
            if not result.audio or all_sources:
                for name in audio_names:
                    candidates = [hit for hit in cached_audio if hit.source == name]
                    if name in self.sources and not self.cache.is_miss(key, name, "audio"):
                        candidates.extend(lookup(name, "audio").audio)
                    candidates.sort(key=rank)
                    for hit in candidates:
                        if accept(hit) and not all_sources:
                            break
                    if result.audio and not all_sources:
                        break
            result.synthetic = not result.audio and forced_source in {None, "say"}
        return result
