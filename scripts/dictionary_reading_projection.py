"""Offline public-dictionary projection matching the shared carrier boundary.

This is preparation, never per-key processing. Source words and private models
are not changed in place. Unaligned/mixed spellings remain unknown.
"""
from decimal import Decimal
import modern_reading_reference as reference

class ReadingProjection:
    def __init__(self):
        self.allowed = reference.allowed_readings()
        self.weights = {}
        for character, reading, weight in reference.dictionary_rows(reference.REFERENCE / 'cn_dicts/8105.dict.yaml'):
            if character in self.allowed and reading in self.allowed[character]:
                self.weights.setdefault(character, {})[reading] = max(1, int(weight or 1))
        self.stats = {'restoredOriginalCarriers': 0, 'filteredSingleReadings': 0,
                      'correctedUnambiguousWords': 0, 'unresolvedAmbiguousWords': 0,
                      'normalizedCharacterPriors': 0}

    def permits(self, word, reading):
        parts = reading.split(' ')
        return len(word) != len(parts) or all(c not in self.allowed or p in self.allowed[c] for c, p in zip(word, parts))

    def character_weight(self, character, reading):
        values = self.weights[character]
        ratio = Decimal(values[reading]) * 100 / sum(values.values())
        return format(ratio, '.12f').rstrip('0').rstrip('.') + '%'

    def project(self, original_word, converted_word, reading, weight):
        word = converted_word
        if len(original_word) == 1 and original_word != converted_word and reading in self.allowed.get(original_word, ()):
            word = original_word
            self.stats['restoredOriginalCarriers'] += 1
        if not self.permits(word, reading):
            if len(word) == 1:
                self.stats['filteredSingleReadings'] += 1
                return None
            parts = reading.split(' ')
            # Correct public annotation only where the accepted carrier has one
            # possible reading. Never guess a new polyphonic word from its text.
            for i, character in enumerate(word):
                values = self.allowed.get(character)
                if values is not None and parts[i] not in values:
                    if len(values) != 1:
                        self.stats['unresolvedAmbiguousWords'] += 1
                        return None
                    parts[i] = next(iter(values))
            reading = ' '.join(parts)
            self.stats['correctedUnambiguousWords'] += 1
        if len(word) == 1 and word in self.allowed:
            weight = self.character_weight(word, reading)
            self.stats['normalizedCharacterPriors'] += 1
        return word, reading, weight
