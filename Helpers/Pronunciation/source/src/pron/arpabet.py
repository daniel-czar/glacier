"""Convert CMUdict's 39 ARPAbet phonemes to approximate GA IPA.

CMUdict marks stress on vowels. We move each mark to the start of its
syllable using a simple maximal-onset split between vowel nuclei. The split
is intentionally approximate; it is not a full English syllabifier.
"""

import re
from collections.abc import Sequence

PHONEMES: dict[str, str] = {
    "AA": "ɑ",
    "AE": "æ",
    "AH": "ʌ",
    "AO": "ɔ",
    "AW": "aʊ",
    "AY": "aɪ",
    "B": "b",
    "CH": "tʃ",
    "D": "d",
    "DH": "ð",
    "EH": "ɛ",
    "ER": "ɝ",
    "EY": "eɪ",
    "F": "f",
    "G": "ɡ",
    "HH": "h",
    "IH": "ɪ",
    "IY": "i",
    "JH": "dʒ",
    "K": "k",
    "L": "l",
    "M": "m",
    "N": "n",
    "NG": "ŋ",
    "OW": "oʊ",
    "OY": "ɔɪ",
    "P": "p",
    "R": "ɹ",
    "S": "s",
    "SH": "ʃ",
    "T": "t",
    "TH": "θ",
    "UH": "ʊ",
    "UW": "u",
    "V": "v",
    "W": "w",
    "Y": "j",
    "Z": "z",
    "ZH": "ʒ",
}

VOWELS = frozenset(
    {
        "AA",
        "AE",
        "AH",
        "AO",
        "AW",
        "AY",
        "EH",
        "ER",
        "EY",
        "IH",
        "IY",
        "OW",
        "OY",
        "UH",
        "UW",
    }
)
_TOKEN = re.compile(r"^([A-Z]+)([012]?)$")
# A modest set of legal two- and three-consonant English onsets. Single
# consonants generally join the following syllable (except syllable-final NG).
_COMPLEX_ONSETS = frozenset(
    {
        ("B", "L"),
        ("B", "R"),
        ("D", "R"),
        ("D", "W"),
        ("F", "L"),
        ("F", "R"),
        ("G", "L"),
        ("G", "R"),
        ("K", "L"),
        ("K", "R"),
        ("K", "W"),
        ("P", "L"),
        ("P", "R"),
        ("S", "K"),
        ("S", "L"),
        ("S", "M"),
        ("S", "N"),
        ("S", "P"),
        ("S", "T"),
        ("S", "W"),
        ("T", "R"),
        ("T", "W"),
        ("TH", "R"),
        ("SH", "R"),
        ("S", "K", "R"),
        ("S", "K", "W"),
        ("S", "P", "L"),
        ("S", "P", "R"),
        ("S", "T", "R"),
    }
)


def _split_onset(consonants: list[str]) -> int:
    """Return the number of consonants assigned to the preceding syllable."""
    for start in range(len(consonants)):
        suffix = tuple(consonants[start:])
        if suffix in _COMPLEX_ONSETS or (len(suffix) == 1 and suffix[0] != "NG"):
            return start
    return len(consonants)


def arpabet_to_ipa(phonemes: Sequence[str]) -> str:
    """Convert one CMUdict pronunciation; raise ValueError on malformed tokens."""
    if not phonemes:
        raise ValueError("ARPAbet pronunciation is empty")

    bases: list[str] = []
    stresses: list[str] = []
    for token in phonemes:
        match = _TOKEN.fullmatch(token)
        if match is None or match[1] not in PHONEMES:
            raise ValueError(f"Unknown ARPAbet token: {token!r}")
        base, stress = match.groups()
        if (base in VOWELS) != bool(stress):
            raise ValueError(f"Invalid ARPAbet stress: {token!r}")
        bases.append(base)
        stresses.append(stress)

    nuclei = [index for index, base in enumerate(bases) if base in VOWELS]
    if not nuclei:
        raise ValueError("ARPAbet pronunciation has no vowel")

    syllable_starts = [0]
    for prior, following in zip(nuclei, nuclei[1:], strict=False):
        cluster = bases[prior + 1 : following]
        syllable_starts.append(prior + 1 + _split_onset(cluster))

    marks: dict[int, str] = {}
    for start, nucleus in zip(syllable_starts, nuclei, strict=True):
        stress = stresses[nucleus]
        if stress in ("1", "2"):
            marks[start] = "ˈ" if stress == "1" else "ˌ"

    pieces: list[str] = []
    for index, base in enumerate(bases):
        pieces.append(marks.get(index, ""))
        # CMUdict's AH0 and ER0 are schwa-like in GA unstressed syllables.
        if base == "AH" and stresses[index] == "0":
            pieces.append("ə")
        elif base == "ER" and stresses[index] == "0":
            pieces.append("ɚ")
        else:
            pieces.append(PHONEMES[base])
    return "".join(pieces)
