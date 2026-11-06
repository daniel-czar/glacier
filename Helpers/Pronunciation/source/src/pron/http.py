"""Small, credential-safe HTTP boundary for pronunciation providers."""

from __future__ import annotations

import os
from pathlib import Path
from urllib.parse import urljoin, urlsplit

import httpx

from pron.models import SourceError

MAX_DOWNLOAD_BYTES = 20 * 1024 * 1024
MAX_REDIRECTS = 5
_CREDENTIAL_HOSTS = {"apifree.forvo.com", "www.dictionaryapi.com"}
# Wikimedia access is enabled only with a configured application/operator
# contact. The default label is used only for other explicitly configured APIs.


class HttpStatusError(SourceError):
    """HTTP failure whose status can be inspected without exposing its URL."""

    def __init__(self, source: str, status_code: int):
        super().__init__(source, f"{source}: HTTP {status_code}")
        self.status_code = status_code


def require_http_url(url: str, source: str) -> str:
    """Reject local/non-network URLs and credentials embedded in URLs."""
    try:
        parts = urlsplit(url)
        valid = parts.scheme.lower() in {"http", "https"} and bool(parts.hostname)
        valid = valid and parts.username is None and parts.password is None
    except ValueError:
        valid = False
    if not valid:
        raise SourceError(source, f"{source}: invalid network URL")
    return url


class HttpClient:
    def __init__(
        self,
        timeout: float = 5.0,
        client: httpx.Client | None = None,
        offline: bool = False,
        user_agent: str = "Glacier/0.1",
    ):
        self._client = client if client is not None else httpx.Client(timeout=timeout)
        self._timeout = timeout
        self._offline = offline
        self._headers = {"User-Agent": user_agent}

    def _request(self, url: str, source: str) -> httpx.Response:
        if self._offline:
            raise SourceError(source, f"{source}: network access disabled")
        require_http_url(url, source)
        for attempt in range(2):
            current_url = url
            redirects = 0
            while True:
                try:
                    response = self._client.get(
                        current_url,
                        timeout=self._timeout,
                        follow_redirects=False,
                        headers=self._headers,
                    )
                except (httpx.TimeoutException, httpx.TransportError):
                    if attempt == 0:
                        break
                    raise SourceError(source, f"{source}: network request failed") from None
                if 300 <= response.status_code < 400:
                    current_url = _redirect_target(
                        current_url, response.headers.get("location"), source, redirects
                    )
                    redirects += 1
                    continue
                if response.status_code >= 500 and attempt == 0:
                    break
                if not 200 <= response.status_code < 300:
                    raise HttpStatusError(source, response.status_code)
                return response
        raise SourceError(source, f"{source}: network request failed")

    def get_json(self, url: str, source: str) -> object:
        response = self._request(url, source)
        try:
            return response.json()
        except ValueError:
            raise SourceError(source, f"{source}: invalid JSON response") from None

    def get_text(self, url: str, source: str) -> str:
        return self._request(url, source).text

    def download(self, url: str, destination: Path, source: str) -> None:
        """Download one bounded audio file, replacing destination only on success."""
        if self._offline:
            raise SourceError(source, f"{source}: network access disabled")
        require_http_url(url, source)
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(f".{destination.name}.{os.getpid()}.part")
        try:
            for attempt in range(2):
                current_url = url
                redirects = 0
                try:
                    while True:
                        with self._client.stream(
                            "GET",
                            current_url,
                            timeout=self._timeout,
                            follow_redirects=False,
                            headers=self._headers,
                        ) as response:
                            if 300 <= response.status_code < 400:
                                current_url = _redirect_target(
                                    current_url,
                                    response.headers.get("location"),
                                    source,
                                    redirects,
                                )
                                redirects += 1
                                continue
                            if response.status_code >= 500 and attempt == 0:
                                break
                            if not 200 <= response.status_code < 300:
                                raise HttpStatusError(source, response.status_code)
                            _check_audio_headers(response, source)
                            total = 0
                            prefix = bytearray()
                            with temporary.open("wb") as output:
                                for chunk in response.iter_bytes():
                                    total += len(chunk)
                                    if total > MAX_DOWNLOAD_BYTES:
                                        raise SourceError(
                                            source, f"{source}: audio download too large"
                                        )
                                    if len(prefix) < 64:
                                        prefix.extend(chunk[: 64 - len(prefix)])
                                    output.write(chunk)
                            if total == 0 or _looks_like_document(bytes(prefix)):
                                raise SourceError(source, f"{source}: invalid audio response")
                        temporary.replace(destination)
                        return
                except (httpx.TimeoutException, httpx.TransportError):
                    if attempt == 0:
                        continue
                    raise SourceError(source, f"{source}: network request failed") from None
        finally:
            temporary.unlink(missing_ok=True)

    def close(self) -> None:
        self._client.close()


def _redirect_target(current_url: str, location: str | None, source: str, count: int) -> str:
    if count >= MAX_REDIRECTS or not location:
        raise SourceError(source, f"{source}: invalid redirect")
    target = require_http_url(urljoin(current_url, location), source)
    current = urlsplit(current_url)
    redirect = urlsplit(target)
    if current.scheme == "https" and redirect.scheme != "https":
        raise SourceError(source, f"{source}: insecure redirect")
    if current.hostname in _CREDENTIAL_HOSTS and redirect.hostname != current.hostname:
        raise SourceError(source, f"{source}: unsafe redirect")
    return target


def _check_audio_headers(response: httpx.Response, source: str) -> None:
    media_type = response.headers.get("content-type", "").split(";", 1)[0].strip().lower()
    if (
        media_type.startswith(("text/", "image/"))
        or media_type
        in {"application/json", "application/xml", "application/pdf", "application/javascript"}
        or media_type.endswith(("+json", "+xml"))
    ):
        raise SourceError(source, f"{source}: invalid audio response")
    length = response.headers.get("content-length")
    if length is not None:
        try:
            declared_length = int(length)
        except ValueError:
            raise SourceError(source, f"{source}: invalid audio response") from None
        if declared_length > MAX_DOWNLOAD_BYTES:
            raise SourceError(source, f"{source}: audio download too large")


def _looks_like_document(prefix: bytes) -> bool:
    stripped = prefix.lstrip(b"\xef\xbb\xbf \t\r\n").lower()
    return stripped.startswith(
        (
            b"<",
            b"{",
            b"[",
            b"%pdf-",
            b"not found",
            b"404",
            b"403",
            b"forbidden",
            b"access denied",
            b"bad gateway",
            b"service unavailable",
        )
    )
