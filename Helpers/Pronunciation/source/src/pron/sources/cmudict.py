"""Offline CMUdict pronunciation source (General American only)."""

from functools import lru_cache
from itertools import islice, product
from math import prod

import cmudict

from pron.arpabet import arpabet_to_ipa
from pron.models import SourceResult, Transcription

# A phrase with several homographs can grow exponentially. Keep the first 128
# dictionary-order combinations; individual words still return every variant.
MAX_PHRASE_VARIANTS = 128


@lru_cache(maxsize=1)
def _dictionary() -> dict[str, list[list[str]]]:
    return cmudict.dict()


class CmudictSource:
    """Look up words or compose complete space-separated phrases offline."""

    name = "cmudict"

    def lookup(self, term: str) -> SourceResult:
        words = term.strip().casefold().split()
        if not words:
            return SourceResult()

        dictionary = _dictionary()
        pronunciations = [dictionary.get(word, []) for word in words]
        if any(not variants for variants in pronunciations):
            return SourceResult()

        if len(words) == 1:
            transcriptions = [
                Transcription(
                    "GA",
                    arpabet_to_ipa(variant),
                    None,
                    self.name,
                    note="approximate syllable boundaries",
                )
                for variant in pronunciations[0]
            ]
        else:
            combinations = islice(product(*pronunciations), MAX_PHRASE_VARIANTS)
            note = "approximate syllable boundaries"
            if prod(len(variants) for variants in pronunciations) > MAX_PHRASE_VARIANTS:
                note += f"; limited to first {MAX_PHRASE_VARIANTS} phrase variants"
            transcriptions = [
                Transcription(
                    "GA",
                    " ".join(arpabet_to_ipa(variant) for variant in combination),
                    None,
                    self.name,
                    note=note,
                )
                for combination in combinations
            ]
        return SourceResult(transcriptions=transcriptions)
