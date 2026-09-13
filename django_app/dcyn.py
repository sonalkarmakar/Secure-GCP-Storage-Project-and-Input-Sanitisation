#################################
# Sonal Karmakar                #
# sonalkarmakar00@gmail.com     #
# sonal.karmakar@protonmail.com #
#################################

"""
dcyn.py

DCYN = Deconstructed Yes/No.

Purpose: eliminate human judgment when converting free-text intake answers into binary logic.
Many onboarding bugs come from silently coercing truthy-ish values ("yes", "Y", "true", "1", "  Yes ")
into booleans with ad-hoc logic scattered across the codebase.
This module makes that conversion a single, strict, fully-tested choke point.

Rules (Poka-Yoke: mistake-proofing by construction, not by reviewer memory):
1. Only the exact, full-form strings "Yes" and "No" are accepted.
2. No abbreviations ("Y"/"N"), no slang, no case-insensitivity,
   no truthy/falsy coercion, no numeric substitutes ("1"/"0"),
   no placeholders (""/None/"TBD"/"N/A").
3. Anything else raises DCYNValidationError -- there is no silent default.
   A missing or malformed answer must fail loudly upstream, never resolve to False by accident.
"""

from __future__ import annotations

from typing import Final

YES: Final[str] = "Yes"
NO: Final[str] = "No"
_VALID_VALUES: Final[frozenset[str]] = frozenset({YES, NO})


# Raised when a value cannot be deconstructed into a binary Yes/No.
class DCYNValidationError(ValueError):
    def __init__(self, field_name: str, raw_value: object):
        self.field_name = field_name
        self.raw_value = raw_value
        super().__init__(
            f"Field '{field_name}' must be exactly 'Yes' or 'No' "
            f"(full form, case-sensitive). Received: {raw_value!r}"
        )


def to_boolean(field_name: str, raw_value: object) -> bool:
    """
    Deconstruct a single DCYN-governed field into a strict boolean.

    Deliberately NOT using `raw_value in ("yes", "y", "true", ...)` style coercion--
    that reintroduces the exact human-judgment gap this library exists to close.
    """
    if not isinstance(raw_value, str):
        raise DCYNValidationError(field_name, raw_value)

    if raw_value not in _VALID_VALUES:
        raise DCYNValidationError(field_name, raw_value)

    return raw_value == YES


def deconstruct_payload(payload: dict, dcyn_fields: list[str]) -> dict:
    """
    Given a raw incoming JSON payload and the list of keys that are governed by DCYN logic,
    return a new dict where each of those keys has been replaced by a strict boolean.

    Non-DCYN keys are passed through untouched.
    Raises DCYNValidationError on the first invalid field encountered (fail-closed, not best-effort/partial).
    """
    result = dict(payload)
    for field_name in dcyn_fields:
        if field_name not in payload:
            raise DCYNValidationError(field_name, "<missing>")
        result[field_name] = to_boolean(field_name, payload[field_name])
    return result
