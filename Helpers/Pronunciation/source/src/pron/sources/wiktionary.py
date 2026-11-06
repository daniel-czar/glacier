"""Kaikki/Wiktextract English JSONL adapter; parser also accepts dump entries."""

from __future__ import annotations

import json
from collections.abc import Iterable, Mapping
from typing import Any
from urllib.parse import quote

from pron.http import HttpClient, HttpStatusError, require_http_url
from pron.models import AudioHit, SourceError, SourceResult, Transcription

SOURCE = "wiktionary"
_GA_TAGS = {"US", "General-American"}
_UK_TAGS = {"UK", "Received-Pronunciation"}
_QUALIFIERS = {
    "dialectal",
    "proscribed",
    "obsolete",
    "archaic",
    "rare",
    "nonstandard",
    "informal",
    "colloquial",
    "phonetic",
    "broad",
    "narrow",
}


def kaikki_url(term: str) -> str:
    """Construct the verified per-word JSONL URL."""
    if not term:
        raise SourceError(SOURCE, "wiktionary: empty word")
    return (
        "https://kaikki.org/dictionary/English/meaning/"
        f"{quote(term[0], safe='')}/{quote(term[:2], safe='')}/{quote(term, safe='')}.jsonl"
    )


def _string(value: object) -> str | None:
    return value if isinstance(value, str) and value else None


def _tags(sound: Mapping[str, object]) -> tuple[str, ...]:
    value = sound.get("tags")
    if not isinstance(value, list):
        return ()
    return tuple(tag for tag in value if isinstance(tag, str))


def _accents(tags: tuple[str, ...]) -> tuple[str, ...]:
    mapped: list[str] = []
    if any(tag in _GA_TAGS for tag in tags):
        mapped.append("GA")
    if any(tag in _UK_TAGS for tag in tags):
        mapped.append("UK")
    if mapped:
        return tuple(mapped)
    for tag in tags:
        if tag.lower() not in _QUALIFIERS:
            return (tag.replace("-", " "),)
    return ("unspecified",)


def _sounds(entry: Mapping[str, object]) -> Iterable[tuple[Mapping[str, object], str | None]]:
    pos = _string(entry.get("pos"))
    top = entry.get("sounds")
    if isinstance(top, list):
        for sound in top:
            if isinstance(sound, dict):
                yield sound, pos
    senses = entry.get("senses")
    if isinstance(senses, list):
        for sense in senses:
            if not isinstance(sense, dict):
                continue
            sense_sounds = sense.get("sounds")
            if isinstance(sense_sounds, list):
                for sound in sense_sounds:
                    if isinstance(sound, dict):
                        yield sound, pos


def _form_note(entry: Mapping[str, object]) -> str | None:
    """Label same-spelling verb forms from explicit inflection metadata."""
    if entry.get("pos") == "verb":
        forms = entry.get("forms")
        word = entry.get("word")
        if isinstance(forms, list) and isinstance(word, str):
            same_spelling_tags: set[str] = set()
            for form in forms:
                if not isinstance(form, dict) or form.get("form") != word:
                    continue
                tags = form.get("tags")
                if isinstance(tags, list):
                    same_spelling_tags.update(tag for tag in tags if isinstance(tag, str))
            if {"past", "infinitive"} <= same_spelling_tags:
                heads = entry.get("head_templates")
                if isinstance(heads, list) and any(
                    isinstance(head, dict) and head.get("name") == "en-verb" for head in heads
                ):
                    return "present / infinitive"
    senses = entry.get("senses")
    if not isinstance(senses, list) or not senses:
        return None
    tags_by_sense: list[set[str]] = []
    for sense in senses:
        if not isinstance(sense, dict) or not isinstance(sense.get("tags"), list):
            return None
        tags = {tag for tag in sense["tags"] if isinstance(tag, str)}
        if "form-of" not in tags:
            return None
        tags_by_sense.append(tags)
    all_tags = set().union(*tags_by_sense)
    glosses: list[str] = []
    for sense in senses:
        if not isinstance(sense, dict):
            continue
        raw_glosses = sense.get("glosses")
        if isinstance(raw_glosses, list):
            glosses.extend(gloss for gloss in raw_glosses if isinstance(gloss, str))
    gloss_text = " ".join(glosses).casefold()
    if "simple past" in gloss_text and "past participle" in gloss_text:
        return "simple past; past participle"
    if "past" in all_tags and "participle" in all_tags:
        return "past participle"
    if "past" in all_tags:
        return "past form"
    if "present" in all_tags:
        return "present form"
    return None


def parse_entries(entries: Iterable[Mapping[str, object]]) -> SourceResult:
    """Extract all English pronunciations; usable with live JSONL or a dump stream."""
    result = SourceResult()
    seen_ipa: set[Transcription] = set()
    seen_audio: set[str] = set()
    for entry in entries:
        if entry.get("lang_code") != "en" and entry.get("lang") != "English":
            continue
        form_note = _form_note(entry)
        for sound, pos in _sounds(entry):
            tags = _tags(sound)
            accents = _accents(tags)
            note = _string(sound.get("note"))
            if form_note:
                note = f"{note}; {form_note}" if note else form_note
            ipa = _string(sound.get("ipa"))
            if ipa:
                phonetic = ipa.startswith("[") and ipa.endswith("]")
                delimited = phonetic or (ipa.startswith("/") and ipa.endswith("/"))
                clean_ipa = ipa[1:-1] if delimited else ipa
                if phonetic:
                    note = f"{note}; phonetic" if note else "phonetic"
                for accent in accents:
                    transcription = Transcription(
                        accent=accent,
                        ipa=clean_ipa,
                        pos=pos,
                        source=SOURCE,
                        raw_tags=tags,
                        note=note,
                    )
                    if transcription not in seen_ipa:
                        seen_ipa.add(transcription)
                        result.transcriptions.append(transcription)
            audio_url = _string(sound.get("mp3_url")) or _string(sound.get("ogg_url"))
            if not audio_url or audio_url in seen_audio:
                continue
            try:
                require_http_url(audio_url, SOURCE)
            except SourceError:
                continue
            seen_audio.add(audio_url)
            filename = _string(sound.get("audio")) or audio_url.rsplit("/", 1)[-1]
            description = "https://commons.wikimedia.org/wiki/File:" + quote(
                filename.replace(" ", "_"), safe=""
            )
            attribution = f"Wikimedia Commons · {filename}"
            if note:
                attribution += f" ({note})"
            result.audio.append(
                AudioHit(
                    source=SOURCE,
                    accent=accents[0],
                    attribution=attribution,
                    url=audio_url,
                    cacheable=True,
                    source_url=description,
                )
            )
    return result


def parse_jsonl(content: str) -> SourceResult:
    entries: list[Mapping[str, object]] = []
    for line in content.splitlines():
        if not line.strip():
            continue
        try:
            value: Any = json.loads(line)
        except ValueError:
            raise SourceError(SOURCE, "wiktionary: invalid JSONL response") from None
        if not isinstance(value, dict):
            raise SourceError(SOURCE, "wiktionary: invalid JSONL entry")
        entries.append(value)
    return parse_entries(entries)


class WiktionarySource:
    def __init__(self, client: HttpClient):
        self.client = client

    def lookup(self, term: str) -> SourceResult:
        try:
            return parse_jsonl(self.client.get_text(kaikki_url(term), SOURCE))
        except HttpStatusError as exc:
            if exc.status_code == 404:
                return SourceResult()
            raise
