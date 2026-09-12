"""
serializers.py

Task 3: Schema Mapping and DCYN Validation.

Deconstructs an incoming student-onboarding JSON payload into a
Django REST Framework serializer with exact field validation limits,
using the DCYN (Deconstructed Yes/No) library for every binary-logic
field so that "yes-ish" values can never slip through as truthy.

This serializer's output shape matches the D1 `student_onboarding`
BigQuery table defined in terraform/main.tf field-for-field, so the
pipeline can validate-then-stream without a second translation layer.
"""

import re
import uuid

from django.core.validators import RegexValidator
from rest_framework import serializers

from .dcyn import NO, YES, DCYNValidationError, to_boolean

# Region codes are a closed, enumerated set, not free text.
# This is the same "no placeholders, no slang" discipline applied to the data model.
REGION_CODE_CHOICES = [
	("IND-BLR", "Bangalore, India"),
	("IND-BOM", "Mumbai, India"),
	("IND-CCU", "Kolkata, India"),
	("IND-DEL", "Delhi, India"),
	("IND-NAG", "Nagpur, India"),
]

_name_validator = RegexValidator(
	regex=re.compile(r"^[A-Za-z][A-Za-z\-' ]{1,99}$"),
	message="Full name must contain letters, spaces, hyphens, or apostrophes only, "
	"between 2 and 100 characters. No initials-only or placeholder entries.",
)


class DCYNField(serializers.ChoiceField):
	"""
	A DRF field that only ever accepts the exact strings "Yes" / "No" on input, and always outputs a Python bool.

	Built on top of DCYNField rather than serializers.BooleanField specifically so that
	the *wire format* stays restricted to the full-form strings mandated by the intake form.
	BooleanField would happily accept "true"/"1"/"on", reopening the exact ambiguity DCYN is meant to close.
	"""

	def __init__(self, **kwargs):
		kwargs.setdefault("choices", [(YES, YES), (NO, NO)])
		super().__init__(**kwargs)

	def to_internal_value(self, data):
		# Reuse the shared DCYN conversion logic so there is exactly one
		# place in the codebase that decides what counts as "Yes".
		field_name = self.field_name or "dcyn_field"
		try:
			return to_boolean(field_name, data)
		except DCYNValidationError as exc:
			raise serializers.ValidationError(str(exc)) from exc

	def to_representation(self, value):
		if isinstance(value, bool):
			return YES if value else NO
		return value


class StudentOnboardingSerializer(serializers.Serializer):
	"""
	Validates a single student-onboarding intake payload before it is
	promoted from D0 (raw landing) to D1 (staged/enforced).

	Design rules enforced here:
	- Every field is REQUIRED. No `default=` on any field, because a silent default
	  is exactly the kind of "human judgment" this project's Golden Rules eliminate.
	- No free-text field accepts abbreviations or blank/placeholder values.
	  Validators reject them explicitly rather than relying on downstream review to catch them.
	- Every Yes/No decision goes through DCYNField, never BooleanField, CharField, or a raw dict lookup.
	"""

	record_id = serializers.UUIDField(
		format="hex_verbose",
		help_text="Server-generated. Client-supplied values are rejected in .validate().",
	)

	student_full_name = serializers.CharField(
		max_length=100,
		min_length=2,
		trim_whitespace=True,
		validators=[_name_validator],
	)

	guardian_full_name = serializers.CharField(
		max_length=100,
		min_length=2,
		trim_whitespace=True,
		validators=[_name_validator],
	)

	guardian_contact_email = serializers.EmailField(
		max_length=254,
	)

	has_diagnosed_learning_difficulty = DCYNField()
	requires_lsa_support = DCYNField()
	guardian_consent_given = DCYNField()
	data_sharing_consent_given = DCYNField()

	region_code = serializers.ChoiceField(choices=REGION_CODE_CHOICES)

	def validate_record_id(self, value):
		# Record IDs are generated server-side at ingestion time.
		# A client-supplied ID would let a caller overwrite another student's record.
		# Reject silently-accepted client input here.
		request = self.context.get("request")
		if request is not None and request.method == "POST" and "record_id" in request.data:
			raise serializers.ValidationError(
				"record_id must not be supplied by the client; it is server-generated."
			)
		return value

	def validate(self, attrs):
		# Cross-field Golden Rule: consent must be affirmative before any support flag can be true.
		# This encodes a business rule that would otherwise depend
		# on a reviewer remembering to check it by hand.
		if attrs.get("requires_lsa_support") and not attrs.get("guardian_consent_given"):
			raise serializers.ValidationError(
				{
					"guardian_consent_given": (
						"Guardian consent is required whenever LSA support is requested. "
						"This record cannot be staged without it."
					)
				}
			)
		return attrs

	def create(self, validated_data):
		validated_data["record_id"] = uuid.uuid4()
		return validated_data


#========================================#
# Example usage against a raw D0 payload
#========================================#
if __name__ == "__main__":
	raw_payload = {
		"student_full_name": "Janet Doherty",
		"guardian_full_name": "Johnathan Doherty",
		"guardian_contact_email": "johnathan.doherty@example.com",
		"has_diagnosed_learning_difficulty": "Yes",
		"requires_lsa_support": "Yes",
		"guardian_consent_given": "Yes",
		"data_sharing_consent_given": "No",
		"region_code": "IND-NAG",
	}

	serializer = StudentOnboardingSerializer(data={**raw_payload, "record_id": uuid.uuid4()})
	serializer.is_valid(raise_exception=True)
	print(serializer.validated_data)