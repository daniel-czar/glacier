"""macOS speech, playback, and clipboard helpers."""

import re
import subprocess
from collections.abc import Iterator
from contextlib import contextmanager
from contextvars import ContextVar
from pathlib import Path


class SpeechError(Exception):
    """A local speech or clipboard command failed."""


_VOICE_LINE = re.compile(r"^(.+?)\s+([a-z]{2}_[A-Z]{2})\s+#", re.IGNORECASE)
_CANCELLABLE_PLAYBACK: ContextVar[bool] = ContextVar("pron_cancellable_playback", default=False)


@contextmanager
def cancellable_playback(enabled: bool) -> Iterator[None]:
    token = _CANCELLABLE_PLAYBACK.set(enabled)
    try:
        yield
    finally:
        _CANCELLABLE_PLAYBACK.reset(token)


def _run(command: list[str], *, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    if not _CANCELLABLE_PLAYBACK.get():
        try:
            return subprocess.run(
                command,
                input=input_text,
                text=True,
                capture_output=True,
                check=True,
            )
        except (OSError, subprocess.CalledProcessError) as exc:
            raise SpeechError(f"{command[0]} failed") from exc

    try:
        with subprocess.Popen(
            command,
            stdin=subprocess.PIPE if input_text is not None else None,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ) as process:
            try:
                stdout, stderr = process.communicate(input=input_text)
            except BaseException:
                # SIGTERM in event mode becomes KeyboardInterrupt. Reap the
                # active player before the caller removes transient audio.
                if process.poll() is None:
                    try:
                        process.terminate()
                    except ProcessLookupError:
                        pass
                try:
                    process.communicate(timeout=1)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate()
                raise
            if process.returncode:
                raise SpeechError(f"{command[0]} failed")
            return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    except OSError as exc:
        raise SpeechError(f"{command[0]} failed") from exc


def _voice_records() -> list[tuple[str, str]]:
    output = _run(["say", "-v", "?"]).stdout
    records: list[tuple[str, str]] = []
    for line in output.splitlines():
        match = _VOICE_LINE.match(line)
        if match:
            records.append((match[1].strip(), match[2].lower()))
    return records


def available_voices() -> list[str]:
    """List installed macOS voice names."""
    return [name for name, _locale in _voice_records()]


def choose_voice(preferred: str | None = None, uk: bool = False) -> str:
    """Select an installed English voice, favoring the requested accent and quality."""
    records = _voice_records()
    if preferred is not None:
        for name, _locale in records:
            if name.casefold() == preferred.casefold():
                return name
        raise SpeechError(f"Voice is not installed: {preferred}")
    if not records:
        raise SpeechError("No macOS speech voices are available")

    target = "en_gb" if uk else "en_us"
    accent = [name for name, locale in records if locale == target]
    quality = [name for name in accent if _quality_rank(name) < 2]
    if quality:
        return sorted(quality, key=lambda name: (_quality_rank(name), name))[0]
    if accent:
        return accent[0]
    english = [name for name, locale in records if locale.startswith("en_")]
    if english:
        return english[0]
    raise SpeechError("No English macOS speech voice is available")


def _quality_rank(name: str) -> int:
    name = name.casefold()
    if "premium" in name:
        return 0
    if "enhanced" in name:
        return 1
    return 2


def speak(text: str, voice: str, rate: int | None = None) -> None:
    """Speak text via stdin so untrusted text cannot become command options."""
    if not text.strip():
        raise SpeechError("No text to speak")
    if not voice.strip() or voice.startswith("-") or "\x00" in voice:
        raise SpeechError("Invalid voice name")
    if rate is not None and rate <= 0:
        raise SpeechError("Speech rate must be positive")
    command = ["say", "-v", voice]
    if rate is not None:
        command.extend(["-r", str(rate)])
    _run(command, input_text=text)


def play_file(path: str) -> None:
    """Play a local audio file with afplay."""
    local_path = Path(path).expanduser().resolve()
    if not local_path.is_file():
        raise SpeechError(f"Audio file does not exist: {path}")
    _run(["afplay", str(local_path)])


def clipboard_text() -> str:
    """Read the clipboard as plain text; an empty clipboard yields an empty string."""
    return _run(["pbpaste"]).stdout
