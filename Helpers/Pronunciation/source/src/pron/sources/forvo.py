"""Forvo's English pronunciation API; its audio must never be persisted."""

from __future__ import annotations

from urllib.parse import quote

from pron.http import HttpClient, HttpStatusError, require_http_url
from pron.models import AudioHit, SourceError, SourceResult

SOURCE = "forvo"


def _number(value: object) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str) and value.strip().lstrip("-").isdigit():
        return int(value)
    return None


def _accent(country: object) -> str:
    if not isinstance(country, str) or not country.strip():
        return "unspecified"
    name = country.strip()
    if name.casefold() in {"usa", "united states", "united states of america"}:
        return "US"
    if name.casefold() in {"uk", "gbr", "united kingdom", "great britain"}:
        return "UK"
    return name


class ForvoSource:
    def __init__(self, client: HttpClient, key: str):
        self.client = client
        self.key = key

    def lookup(self, term: str) -> SourceResult:
        if not self.key:
            raise SourceError(SOURCE, "forvo: API key is missing")
        url = (
            "https://apifree.forvo.com/key/"
            f"{quote(self.key, safe='')}/format/json/action/word-pronunciations/"
            f"word/{quote(term, safe='')}/language/en/order/rate-desc"
        )
        try:
            payload = self.client.get_json(url, SOURCE)
        except HttpStatusError as exc:
            if exc.status_code == 404:
                return SourceResult()
            raise
        if not isinstance(payload, dict):
            raise SourceError(SOURCE, "forvo: invalid API response")
        quota = _number(payload.get("quota_remaining"))
        if payload.get("error") or payload.get("errors"):
            raise SourceError(SOURCE, "forvo: API reported an error", quota_remaining=quota)
        items = payload.get("items")
        if not isinstance(items, list):
            raise SourceError(SOURCE, "forvo: invalid API response", quota_remaining=quota)
        result = SourceResult(quota_remaining=quota)
        seen_urls: set[str] = set()
        for item in items:
            if not isinstance(item, dict):
                continue
            lang = item.get("lang", item.get("language"))
            if isinstance(lang, str) and lang.casefold() not in {"en", "english"}:
                continue
            audio_url = item.get("pathmp3") or item.get("pathogg")
            if not isinstance(audio_url, str) or audio_url in seen_urls:
                continue
            try:
                require_http_url(audio_url, SOURCE)
            except SourceError:
                continue
            seen_urls.add(audio_url)
            username = item.get("username")
            speaker = username if isinstance(username, str) and username else "unknown speaker"
            result.audio.append(
                AudioHit(
                    source=SOURCE,
                    accent=_accent(item.get("country")),
                    attribution=f"Forvo · {speaker}",
                    votes=_number(item.get("rate")),
                    url=audio_url,
                    cacheable=False,
                    source_url="https://forvo.com/word/" + quote(term, safe="") + "/#en",
                )
            )
        return result
