"""Shared source and resolver records; provider URLs stay in memory only."""

from dataclasses import dataclass, field
from typing import Protocol


@dataclass(frozen=True)
class Transcription:
    accent: str
    ipa: str
    pos: str | None
    source: str
    raw_tags: tuple[str, ...] = ()
    note: str | None = None


@dataclass(frozen=True)
class AudioHit:
    source: str
    accent: str
    attribution: str
    votes: int | None = None
    url: str | None = field(default=None, repr=False)
    path: str | None = None
    cached: bool = False
    cacheable: bool = True
    source_url: str | None = None
    license: str | None = None


@dataclass(frozen=True)
class Respelling:
    text: str
    source: str


@dataclass
class SourceResult:
    transcriptions: list[Transcription] = field(default_factory=list)
    audio: list[AudioHit] = field(default_factory=list)
    respellings: list[Respelling] = field(default_factory=list)
    quota_remaining: int | None = None


class SourceError(Exception):
    """Safe provider failure; never include credential-bearing URLs."""

    def __init__(self, source: str, message: str, quota_remaining: int | None = None):
        super().__init__(message)
        self.source = source
        self.quota_remaining = quota_remaining


class Source(Protocol):
    def lookup(self, term: str) -> SourceResult: ...
