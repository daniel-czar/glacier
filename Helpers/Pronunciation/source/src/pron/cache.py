"""Persistent IPA metadata and locally owned audio files."""

from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import tempfile
from collections.abc import Callable
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

from pron.models import AudioHit, Transcription

IPA_TTL = timedelta(days=180)
MISS_TTL = timedelta(days=7)
_SOURCE = re.compile(r"[a-z][a-z0-9_-]*\Z")
_CACHE_FILE = re.compile(r"[a-z0-9-]+-[0-9a-f]{16}\.(?:mp3|ogg|wav|m4a)\Z")
_EXTENSIONS = {".mp3", ".ogg", ".wav", ".m4a"}


class CacheError(Exception):
    """An unavailable or unsafe cache location."""


def _now() -> str:
    return datetime.now(UTC).isoformat()


def _fresh(value: str, ttl: timedelta) -> bool:
    try:
        timestamp = datetime.fromisoformat(value)
        age = datetime.now(UTC) - timestamp
        return timestamp.tzinfo is not None and timedelta(0) <= age < ttl
    except (TypeError, ValueError):
        return False


def _source_name(source: str) -> str:
    if not _SOURCE.fullmatch(source):
        raise ValueError("invalid audio source name")
    return source


def _public_url(value: str | None) -> str | None:
    """Keep only ordinary public attribution links, without query credentials."""
    if not value:
        return None
    try:
        parts = urlsplit(value)
        if (
            parts.scheme.lower() not in {"https", "http"}
            or not parts.hostname
            or parts.username is not None
            or parts.password is not None
            or (
                Path(parts.path).suffix.lower() in _EXTENSIONS
                and not parts.path.startswith("/wiki/File:")
            )
            or any(word in parts.path.lower() for word in ("apikey", "api_key", "token="))
        ):
            return None
        return urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))
    except ValueError:
        return None


class Cache:
    def __init__(self, root: Path):
        self.root = root.expanduser().absolute()
        try:
            self.root.mkdir(parents=True, exist_ok=True)
            if self.root.is_symlink():
                raise CacheError("cache root cannot be a symbolic link")
            self.root = self.root.resolve()
            db_path = self.root / "pron.sqlite"
            if db_path.is_symlink():
                raise CacheError("cache database cannot be a symbolic link")
            self._db = sqlite3.connect(db_path)
            self._db.row_factory = sqlite3.Row
            self._db.executescript(
                """
                CREATE TABLE IF NOT EXISTS terms (
                    term TEXT PRIMARY KEY, display TEXT NOT NULL,
                    first_seen TEXT NOT NULL, last_seen TEXT NOT NULL,
                    hit_count INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS transcriptions (
                    term TEXT NOT NULL, source TEXT NOT NULL,
                    accent TEXT NOT NULL, ipa TEXT NOT NULL, pos TEXT,
                    raw_tags TEXT NOT NULL, note TEXT, fetched_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS transcriptions_lookup
                    ON transcriptions(term, source);
                CREATE TABLE IF NOT EXISTS audio (
                    term TEXT NOT NULL, source TEXT NOT NULL,
                    accent TEXT NOT NULL, path TEXT NOT NULL UNIQUE,
                    attribution TEXT NOT NULL, votes INTEGER,
                    source_url TEXT, license TEXT, fetched_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS audio_lookup ON audio(term, source);
                CREATE TABLE IF NOT EXISTS misses (
                    term TEXT NOT NULL, source TEXT NOT NULL, kind TEXT NOT NULL,
                    fetched_at TEXT NOT NULL,
                    PRIMARY KEY(term, source, kind)
                );
                CREATE TABLE IF NOT EXISTS source_log (
                    id INTEGER PRIMARY KEY, source TEXT NOT NULL,
                    ts TEXT NOT NULL, ok INTEGER NOT NULL, quota_remaining INTEGER
                );
                """
            )
        except (sqlite3.Error, OSError) as exc:
            raise CacheError("cache cannot be initialized") from exc

    def close(self) -> None:
        try:
            self._db.close()
        except sqlite3.Error as exc:
            raise CacheError("cache cannot be closed") from exc

    def record_term(self, term: str, display: str) -> None:
        try:
            with self._db:
                self._db.execute(
                    """INSERT INTO terms VALUES (?, ?, ?, ?, 1)
                    ON CONFLICT(term) DO UPDATE SET display=excluded.display,
                    last_seen=excluded.last_seen, hit_count=hit_count+1""",
                    (term, display, _now(), _now()),
                )
        except sqlite3.Error as exc:
            raise CacheError("term cannot be recorded") from exc

    def load_transcriptions(self, term: str, source: str) -> list[Transcription] | None:
        try:
            rows = self._db.execute(
                "SELECT * FROM transcriptions WHERE term=? AND source=?", (term, source)
            ).fetchall()
            if not rows or not all(_fresh(row["fetched_at"], IPA_TTL) for row in rows):
                return None
            return [
                Transcription(
                    accent=row["accent"],
                    ipa=row["ipa"],
                    pos=row["pos"],
                    source=source,
                    raw_tags=tuple(json.loads(row["raw_tags"])),
                    note=row["note"],
                )
                for row in rows
            ]
        except (sqlite3.Error, ValueError, TypeError) as exc:
            raise CacheError("transcriptions cannot be read") from exc

    def store_transcriptions(self, term: str, source: str, items: list[Transcription]) -> None:
        try:
            with self._db:
                self._db.execute(
                    "DELETE FROM transcriptions WHERE term=? AND source=?", (term, source)
                )
                self._db.executemany(
                    """INSERT INTO transcriptions
                    (term,source,accent,ipa,pos,raw_tags,note,fetched_at)
                    VALUES (?,?,?,?,?,?,?,?)""",
                    [
                        (
                            term,
                            source,
                            item.accent,
                            item.ipa,
                            item.pos,
                            json.dumps(item.raw_tags),
                            item.note,
                            _now(),
                        )
                        for item in items
                    ],
                )
        except sqlite3.Error as exc:
            raise CacheError("transcriptions cannot be stored") from exc

    def _audio_dir(self, source: str) -> Path:
        path = self.root / "audio"
        if path.is_symlink():
            raise CacheError("audio directory cannot be a symbolic link")
        path.mkdir(exist_ok=True)
        folder = path / _source_name(source)
        if folder.is_symlink():
            raise CacheError("audio source cannot be a symbolic link")
        folder.mkdir(exist_ok=True)
        return folder

    def _safe_audio_path(self, value: str) -> Path | None:
        relative = Path(value)
        if (
            relative.is_absolute()
            or len(relative.parts) != 3
            or relative.parts[0] != "audio"
            or not _SOURCE.fullmatch(relative.parts[1])
            or not _CACHE_FILE.fullmatch(relative.parts[2])
        ):
            return None
        path = self.root / relative
        if any(parent.is_symlink() for parent in (path.parent.parent, path.parent, path)):
            return None
        if not path.resolve().is_relative_to(self.root):
            return None
        return path

    def load_audio(self, term: str, source: str | None = None) -> list[AudioHit]:
        try:
            if source is None:
                rows = self._db.execute("SELECT * FROM audio WHERE term=?", (term,)).fetchall()
            else:
                rows = self._db.execute(
                    "SELECT * FROM audio WHERE term=? AND source=?", (term, source)
                ).fetchall()
            hits: list[AudioHit] = []
            for row in rows:
                path = self._safe_audio_path(row["path"])
                if path is None or not path.is_file():
                    continue
                hits.append(
                    AudioHit(
                        source=row["source"],
                        accent=row["accent"],
                        attribution=row["attribution"],
                        votes=row["votes"],
                        path=str(path),
                        cached=True,
                        source_url=row["source_url"],
                        license=row["license"],
                    )
                )
            return hits
        except (sqlite3.Error, OSError) as exc:
            raise CacheError("audio cache cannot be read") from exc

    def store_audio(
        self,
        term: str,
        hit: AudioHit,
        download: Callable[[str, Path, str], None],
    ) -> AudioHit:
        if not hit.cacheable or hit.source.lower() == "forvo":
            raise ValueError("this source does not permit persistent audio caching")
        if not hit.url:
            raise ValueError("audio hit has no download URL")
        source = _source_name(hit.source)
        slug = re.sub(r"[^a-z0-9]+", "-", term.lower()).strip("-")[:48] or "audio"
        identity = "\0".join((term, source, hit.accent, hit.attribution, hit.url))
        digest = hashlib.sha256(identity.encode()).hexdigest()[:16]
        suffix = Path(urlsplit(hit.url).path).suffix.lower()
        if suffix not in _EXTENSIONS:
            suffix = ".mp3"
        relative = Path("audio") / source / f"{slug}-{digest}{suffix}"
        target = self.root / relative
        temporary: Path | None = None
        try:
            folder = self._audio_dir(source)
            if target.is_symlink():
                raise CacheError("audio target cannot be a symbolic link")
            existing = self._db.execute(
                "SELECT path FROM audio WHERE path=?", (str(relative),)
            ).fetchone()
            if existing is not None and target.is_file():
                return replace(
                    hit,
                    url=None,
                    path=str(target),
                    cached=True,
                    source_url=_public_url(hit.source_url),
                )
            fd, name = tempfile.mkstemp(prefix=".pron-", suffix=".part", dir=folder)
            os.close(fd)
            temporary = Path(name)
            download(hit.url, temporary, source)
            if temporary.is_symlink() or not temporary.is_file():
                raise CacheError("download did not produce a regular audio file")
            temporary.replace(target)
            temporary = None
            with self._db:
                self._db.execute(
                    """INSERT INTO audio
                    (term,source,accent,path,attribution,votes,source_url,license,fetched_at)
                    VALUES (?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(path) DO UPDATE SET
                    accent=excluded.accent, attribution=excluded.attribution,
                    votes=excluded.votes, source_url=excluded.source_url,
                    license=excluded.license, fetched_at=excluded.fetched_at""",
                    (
                        term,
                        source,
                        hit.accent,
                        str(relative),
                        hit.attribution,
                        hit.votes,
                        _public_url(hit.source_url),
                        hit.license,
                        _now(),
                    ),
                )
            return replace(
                hit,
                url=None,
                path=str(target),
                cached=False,
                source_url=_public_url(hit.source_url),
            )
        except (sqlite3.Error, OSError) as exc:
            if temporary is None and target.exists():
                target.unlink(missing_ok=True)
            raise CacheError("audio cannot be stored") from exc
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)

    def is_miss(self, term: str, source: str, kind: str) -> bool:
        try:
            row = self._db.execute(
                "SELECT fetched_at FROM misses WHERE term=? AND source=? AND kind=?",
                (term, source, kind),
            ).fetchone()
            return row is not None and _fresh(row["fetched_at"], MISS_TTL)
        except sqlite3.Error as exc:
            raise CacheError("cache miss cannot be read") from exc

    def store_miss(self, term: str, source: str, kind: str) -> None:
        try:
            with self._db:
                self._db.execute(
                    """INSERT INTO misses VALUES (?,?,?,?)
                    ON CONFLICT(term,source,kind) DO UPDATE SET fetched_at=excluded.fetched_at""",
                    (term, source, kind, _now()),
                )
        except sqlite3.Error as exc:
            raise CacheError("cache miss cannot be stored") from exc

    def log_source(self, source: str, ok: bool, quota_remaining: int | None = None) -> None:
        try:
            with self._db:
                self._db.execute(
                    "INSERT INTO source_log(source,ts,ok,quota_remaining) VALUES (?,?,?,?)",
                    (source, _now(), int(ok), quota_remaining),
                )
        except sqlite3.Error as exc:
            raise CacheError("source status cannot be stored") from exc

    def source_status(self) -> dict[str, dict[str, object]]:
        try:
            rows = self._db.execute(
                "SELECT source,ts,ok,quota_remaining FROM source_log ORDER BY id DESC"
            ).fetchall()
            status: dict[str, dict[str, object]] = {}
            for row in rows:
                entry = status.setdefault(
                    row["source"], {"last_success": None, "quota_remaining": None}
                )
                if bool(row["ok"]) and entry["last_success"] is None:
                    entry["last_success"] = row["ts"]
                if row["quota_remaining"] is not None and entry["quota_remaining"] is None:
                    entry["quota_remaining"] = row["quota_remaining"]
            return status
        except sqlite3.Error as exc:
            raise CacheError("source status cannot be read") from exc

    def stats(self) -> dict[str, int | str]:
        try:
            counts: dict[str, int | str] = {}
            for table in ("terms", "transcriptions", "audio", "misses"):
                counts[table] = int(self._db.execute(f"SELECT count(*) FROM {table}").fetchone()[0])
            counts["audio_bytes"] = sum(
                path.stat().st_size
                for row in self._db.execute("SELECT path FROM audio")
                if (path := self._safe_audio_path(row["path"])) is not None and path.is_file()
            )
            counts["database_bytes"] = (self.root / "pron.sqlite").stat().st_size
            return counts
        except (sqlite3.Error, OSError) as exc:
            raise CacheError("cache statistics cannot be read") from exc

    def clear(self) -> dict[str, int | str]:
        try:
            before = self.stats()
            paths = [
                self._safe_audio_path(row["path"])
                for row in self._db.execute("SELECT path FROM audio")
            ]
            for path in paths:
                if path is not None and (path.is_file() or path.is_symlink()):
                    path.unlink()
            audio_root = self.root / "audio"
            if audio_root.is_dir() and not audio_root.is_symlink():
                for folder in audio_root.iterdir():
                    if (
                        folder.is_dir()
                        and not folder.is_symlink()
                        and _SOURCE.fullmatch(folder.name)
                    ):
                        for path in folder.iterdir():
                            if (
                                path.is_file()
                                and not path.is_symlink()
                                and _CACHE_FILE.fullmatch(path.name)
                            ):
                                path.unlink()
                        if not any(folder.iterdir()):
                            folder.rmdir()
                if not any(audio_root.iterdir()):
                    audio_root.rmdir()
            with self._db:
                for table in ("terms", "transcriptions", "audio", "misses", "source_log"):
                    self._db.execute(f"DELETE FROM {table}")
            return before
        except (sqlite3.Error, OSError) as exc:
            raise CacheError("cache cannot be cleared") from exc
