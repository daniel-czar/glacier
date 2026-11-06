"""Merriam-Webster Collegiate pronunciation and respelling adapter."""

from __future__ import annotations

from collections.abc import Iterator
from urllib.parse import quote

from pron.http import HttpClient, HttpStatusError, require_http_url
from pron.models import AudioHit, Respelling, SourceError, SourceResult

SOURCE = "mw"
_AUDIO_ROOT = "https://media.merriam-webster.com/audio/prons/en/us/mp3"
_PRONUNCIATION_CONTAINERS = (
    "hwi",
    "ahws",
    "vrs",
    "ins",
    "dros",
    "uros",
    "ri",
    "cats",
    "def",
    "sseq",
    "sense",
    "sdsense",
    "sen",
)
_MAX_NODES = 1000
_MAX_DEPTH = 12


def mw_audio_url(name: str) -> str:
    if not name or "/" in name or "\\" in name or name in {".", ".."}:
        raise SourceError(SOURCE, "mw: invalid audio filename")
    if name.startswith("bix"):
        directory = "bix"
    elif name.startswith("gg"):
        directory = "gg"
    elif not name[0].isalpha():
        directory = "number"
    else:
        directory = name[0].lower()
    return f"{_AUDIO_ROOT}/{directory}/{quote(name, safe='')}.mp3"


def _label(container: str, value: object, inherited: str | None) -> str | None:
    if not isinstance(value, dict):
        return inherited
    name_key = {
        "vrs": "va",
        "ahws": "hw",
        "ins": "if",
        "dros": "drp",
        "uros": "ure",
    }.get(container)
    if name_key is None:
        return inherited
    name = value.get(name_key)
    if not isinstance(name, str) or not name:
        return inherited
    clean_name = name.replace("*", "")
    qualifier = value.get("vl") if container == "vrs" else value.get("il")
    prefix = f"{qualifier} " if isinstance(qualifier, str) and qualifier else ""
    return f"{prefix}{clean_name}"


def _pronunciations(entry: dict[str, object]) -> Iterator[tuple[dict[str, object], str | None]]:
    """Visit documented pronunciation containers, excluding definition text."""
    stack: list[tuple[object, int, str | None]] = [(entry, 0, None)]
    visited = 0
    while stack and visited < _MAX_NODES:
        value, depth, label = stack.pop()
        visited += 1
        if depth > _MAX_DEPTH:
            continue
        if isinstance(value, list):
            stack.extend((item, depth + 1, label) for item in reversed(value))
            continue
        if not isinstance(value, dict):
            continue
        pronunciations = value.get("prs")
        if isinstance(pronunciations, list):
            for pronunciation in pronunciations:
                if isinstance(pronunciation, dict):
                    yield pronunciation, label
        for container in reversed(_PRONUNCIATION_CONTAINERS):
            child = value.get(container)
            if child is None:
                continue
            if isinstance(child, list):
                stack.extend(
                    (item, depth + 1, _label(container, item, label)) for item in reversed(child)
                )
            else:
                stack.append((child, depth + 1, _label(container, child, label)))


class MerriamWebsterSource:
    def __init__(self, client: HttpClient, key: str):
        self.client = client
        self.key = key

    def lookup(self, term: str) -> SourceResult:
        if not self.key:
            raise SourceError(SOURCE, "mw: API key is missing")
        url = (
            "https://www.dictionaryapi.com/api/v3/references/collegiate/json/"
            f"{quote(term, safe='')}?key={quote(self.key, safe='')}"
        )
        try:
            payload = self.client.get_json(url, SOURCE)
        except HttpStatusError as exc:
            if exc.status_code == 404:
                return SourceResult()
            raise
        if not isinstance(payload, list):
            raise SourceError(SOURCE, "mw: invalid API response")
        result = SourceResult()
        seen_audio: set[str] = set()
        seen_spelling: set[str] = set()
        for entry in payload:
            if not isinstance(entry, dict):
                continue  # MW uses strings for spelling suggestions.
            for pronunciation, label in _pronunciations(entry):
                spelling = pronunciation.get("mw")
                if isinstance(spelling, str) and spelling and spelling not in seen_spelling:
                    result.respellings.append(Respelling(text=spelling, source=SOURCE))
                    seen_spelling.add(spelling)
                sound = pronunciation.get("sound")
                if not isinstance(sound, dict):
                    continue
                audio_name = sound.get("audio")
                if not isinstance(audio_name, str) or not audio_name:
                    continue
                try:
                    audio_url = require_http_url(mw_audio_url(audio_name), SOURCE)
                except SourceError:
                    continue
                if audio_url in seen_audio:
                    continue
                seen_audio.add(audio_url)
                attribution = "Merriam-Webster Collegiate Dictionary"
                if label:
                    attribution += f" · {label}"
                result.audio.append(
                    AudioHit(
                        source=SOURCE,
                        accent="GA",
                        attribution=attribution,
                        url=audio_url,
                        cacheable=True,
                        source_url="https://www.merriam-webster.com/dictionary/"
                        + quote(term, safe=""),
                    )
                )
        return result
