# Secure GCP Storage & Project and Input Sanitisation
Staging-incident response: secure IaC provisioning, a fail-closed CI/CD gate to prevent merging sensitive data, and strict schema/DCYN validation for the student onboarding form.

## Folder layout
```
habot-devops-project/
├── terraform/
│   ├── main.tf            # D0 raw landing bucket + D1 BigQuery dataset, IAM, RLS
│   ├── variables.tf
│   └── outputs.tf
├── .github/
│   └── workflows/
│       └── build-gate.yml # Fail-closed lint/security/deploy pipeline
├── django_app/
│   ├── dcyn.py            # Deconstructed Yes/No strict-boolean library
│   └── serializers.py     # DRF serializer using DCYN + field validation
└── README.md
```

## Task 1: Terraform Secure Staging Provisioning (IaC) (`terraform/`)
**What it provisions:**
- `google_storage_bucket.d0_raw_landing`: uniform bucket-level access (IAM only, no legacy ACLs), versioning on, public access blocked, lifecycle rules that age data to Nearline and delete at user-defined days (default ages are 15 and 30 respectively). Optional CMEK via `var.kms_key_id`.
- `google_bigquery_dataset.d1_staged_enforced`: explicit, enumerated `access` blocks (no reliance on project-level default roles), containing the `student_onboarding` table and an `analyst_region_map` lookup table.
- `google_bigquery_row_access_policy.student_onboarding_region_rls`: an analyst can only see rows whose `region_code` appears in their own row of `analyst_region_map`, resolved via `SESSION_USER()`. This is enforced by BigQuery itself at query time, not by application code that could be bypassed.

**Least-privilege / IAM conditions:**
- Writers to the raw bucket get `roles/storage.objectCreator` scoped with a CEL condition restricting them to the `incoming/` prefix. They cannot overwrite or browse already-ingested paths.
- The dedicated `pipeline_runner` service account gets `roles/bigquery.dataEditor` scoped by a condition to the single D1 dataset, and read-only access to the raw bucket. It has no Owner/Editor project role.

**Why this satisfies the Golden Rule of "zero reliance on human memory:"**  
Access is enforced by IAM conditions and RLS predicates evaluated by GCP itself on every request, not by a runbook telling someone to "remember to filter by region".

**To apply:**
```bash
cd terraform
terraform init
terraform plan -var="project_id=YOUR_PROJECT" \
  -var="raw_landing_bucket_name=YOUR_UNIQUE_BUCKET" \
  -var="data_engineer_group=data-eng@yourdomain.com" \
  -var="analytics_reader_group=analytics@yourdomain.com"
terraform apply
```

## Task 2: Poka-Yoke CI/CD Gate (`.github/workflows/build-gate.yml`)
Four independent gate jobs (`lint-and-format`, `secret-scan`, `django-security-check`) feed into a `deploy-gate` job that is the actual mistake-proofing mechanism:
- It runs with `if: always()`, so it evaluates even if an earlier job failed (instead of being skipped, which would otherwise silently short-circuit past a failure in some Actions configurations).
- It explicitly checks `needs.<job>.result == 'success'` for every upstream job. Anything other than a literal `success`—failure, cancellation, or skip—trips the gate.
- On failure it uploads a `quarantine-record` artifact documenting the blocked commit, and the `deploy-staging` job's `if:` condition means it is structurally unreachable unless `deploy-gate` succeeded.

This is "fail-closed" in the literal sense: the default path is no deployment; deployment is the exception that requires proof, not the default that requires an alarm to stop it.

**Demonstrating the fail-closed trigger:**
Push a branch containing an unformatted file or a dummy key string (e.g. `AWS_SECRET_ACCESS_KEY = "AKIA..."`) in a scratch file, open a PR, and show the Actions run: `secret-scan` or `lint-and-format` goes red, `deploy-gate` reports the failure and uploads the quarantine artifact, and `deploy-staging` never starts (visible as "skipped" with the unmet condition, not as a run that failed at the deploy step).

## Task 3: Schema Mapping & DCYN Validation (`django_app/`)
**`dcyn.py`** is the single choke point for every yes/no decision in the intake form. It accepts *only* the exact strings `"Yes"` and `"No"`—no `"y"`, `"true"`, `"1"`, or empty string—and raises `DCYNValidationError` on anything else. Centralizing this logic means no other file in the codebase is allowed to reimplement its own truthy/falsy coercion.

**`serializers.py`** maps the incoming JSON payload to the D1 `student_onboarding` schema field-for-field:
- `DCYNField` (built on DRF's `ChoiceField`) is used for every binary field instead of `BooleanField`, so the wire format itself is restricted to `"Yes"`/`"No"` rather than DRF's normally-lenient boolean parsing.
- Every field is required, none have a `default=`, so a missing answer fails validation instead of silently resolving to `False`.
- `region_code` is a closed `ChoiceField`, not free text.
- A cross-field rule in `validate()` enforces that `requires_lsa_support` can only be `True` if `guardian_consent_given` is also `True`. Thus encoding a business rule as code instead of relying on a reviewer to catch a missing consent by hand.

Run the example at the bottom of `serializers.py` directly (`python serializers.py`, with `djangorestframework` installed and `DJANGO_SETTINGS_MODULE` configured) to see a valid payload pass validation end-to-end.