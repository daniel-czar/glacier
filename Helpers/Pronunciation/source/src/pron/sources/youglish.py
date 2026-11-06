"""Youglish links for human speech in context."""

import subprocess
from urllib.parse import quote, urlsplit

from pron.sources.say import SpeechError


def youglish_url(term: str, uk: bool = False) -> str:
    """Build the US or UK English Youglish URL for a word or phrase."""
    if not term.strip():
        raise ValueError("Youglish term is empty")
    region = "uk" if uk else "us"
    return f"https://youglish.com/pronounce/{quote(term.strip(), safe='')}/english/{region}"


def open_youglish(url: str) -> None:
    """Open a generated Youglish link in the macOS default browser."""
    parsed = urlsplit(url)
    if (
        parsed.scheme != "https"
        or parsed.netloc != "youglish.com"
        or not parsed.path.startswith("/pronounce/")
        or not parsed.path.endswith(("/english/us", "/english/uk"))
    ):
        raise SpeechError("Invalid Youglish URL")
    try:
        subprocess.run(["open", url], check=True, capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise SpeechError("open failed") from exc
