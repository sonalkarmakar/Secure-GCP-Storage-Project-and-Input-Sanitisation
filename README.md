# Secure GCP Storage & Project and Input Sanitisation
A staging-incident response covering secure IaC provisioning, a fail-closed CI/CD gate that blocks merges on lint failures or hard-coded secrets, and strict schema/DCYN validation for the student onboarding form.

## 1. Project Overview
**Scenario:** a junior developer pushed unencrypted API credentials into raw application code and triggered a database schema mismatch that broke downstream analytics. This project restores system integrity across three fronts: infrastructure, pipeline gating, and data validation.

**What's delivered:**
- Terraform that provisions a secured GCS raw-landing bucket and a BigQuery staged/enforced dataset with IAM conditions and row-level security.
- A GitHub Actions pipeline that fails closed; no deploy is possible unless formatting, linting, secret-scanning, and Django security checks all pass.
- A Django REST Framework serializer built on a custom DCYN (Deconstructed Yes/No) library, so intake data can never resolve to a boolean by accident.

## Folder layout (current)
```
.
├── .github/
│   └── workflows/
│       └── build-gate.yml       # Fail-closed lint/secret/security/deploy pipeline
├── django_app/
│   ├── config/
│   │   ├── __init__.py
│   │   ├── settings/
│   │   │   ├── __init__.py
│   │   │   ├── base.py          # Shared Django settings
│   │   │   └── staging.py       # Staging overrides (security headers, DEBUG=False)
│   │   ├── urls.py
│   │   └── wsgi.py
│   ├── dcyn.py                  # Deconstructed Yes/No strict-boolean library
│   ├── serializers.py           # DRF serializer using DCYN + field validation
│   ├── manage.py
│   ├── requirements.txt         # Django + djangorestframework
│   └── scratch_file.py          # Leftover fail-closed test artifact, safe to remove
├── terraform/
│   ├── main.tf                  # D0 raw landing bucket + D1 BigQuery dataset, IAM, RLS
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars.example # Template for local tfvars (real tfvars/tfstate are gitignored)
│   └── (terraform.tfvars, terraform.tfstate — local only, not committed)
├── .gitignore
└── README.md
```

> [!NOTE]
> `manage.py`, `requirements.txt`, and `config/` live inside `django_app/` rather than at the repo root.
> 
> `build-gate.yml`'s `django-security-check` job sets `working-directory: django_app` accordingly, so `pip install -r requirements.txt` and `manage.py check --deploy` both resolve correctly from there.

## 2. Task 1: Terraform Secure Staging Provisioning (`terraform/`)
**What it provisions:**
- `google_storage_bucket.d0_raw_landing`: uniform bucket-level access (IAM only, no legacy ACLs), versioning on, public access blocked. Lifecycle ages data to Nearline and deletes it after configurable day counts.
- `google_bigquery_dataset.d1_staged_enforced`: explicit, enumerated `access` blocks (no reliance on project-level default roles), containing the `student_onboarding` table and an `analyst_region_map` lookup table.
- `google_bigquery_row_access_policy.student_onboarding_region_rls`: an analyst can only see rows whose `region_code` appears in their own row of `analyst_region_map`, resolved via `SESSION_USER()`. This is enforced by BigQuery itself at query-time, not by application code that could be bypassed.

**Configurable via variables (`variables.tf`):**
- `storage_bucket_lifecycle`: a `map(number)` with `CHEAPEN` and `DELETE` keys (default 15 and 30 days), used in `main.tf`.
- `destroy_all_resources`: a single boolean that simultaneously drives `force_destroy` on the bucket, `delete_contents_on_destroy` on the dataset, and `deletion_protection` on both tables. Set `true` for sandbox/testing so `terraform destroy` removes everything cleanly with no residue. Set `false` before anything touches real student data, so a stray `destroy` can't wipe it out.
- `data_engineer_group` / `analytics_reader_group`: validated with a regex to ensure they're at least email-shaped. IAM bindings currently use `user:` (a real individual account) for local testing, with the `group:` form commented alongside each for production use.

**Least-privilege / IAM conditions:**
- Writers to the raw bucket get `roles/storage.objectCreator` scoped with a CEL condition restricting them to the `incoming/` prefix.
- The dedicated `pipeline_runner` service account gets `roles/bigquery.dataEditor` scoped to the single D1 dataset, plus read-only access to the raw bucket. No Owner/Editor project role.

**To apply:**
```bash
cd terraform
terraform init
terraform apply   # reads terraform.tfvars for project_id, bucket name, and group/email values
```
**To tear down with nothing left behind** (with `destroy_all_resources = true`):
```bash
terraform destroy
```

## 3. Task 2: Poka-Yoke CI/CD Gate (`.github/workflows/build-gate.yml`)
Three independent gate jobs feed into a `deploy-gate` job that is the actual mistake-proofing mechanism:
- **`lint-and-format`**: `black --check`, `isort --check-only`, `flake8`.
- **`secret-scan`**: `gitleaks`, authenticated via `secrets.GITHUB_TOKEN` (required as of the current `gitleaks-action@v2` release for scanning pull request diffs).
- **`django-security-check`**: installs from `django_app/requirements.txt`, runs `bandit`, then `manage.py check --deploy --fail-level WARNING` against `config.settings.staging`. The staging settings enable `SECURE_SSL_REDIRECT`, `SESSION_COOKIE_SECURE`, HSTS, and `XFrameOptionsMiddleware` specifically so this check passes clean, with a CI placeholder `SECRET_KEY` long and varied enough to clear Django's entropy check.

`deploy-gate` runs with `if: always()` and explicitly checks `needs.<job>.result == 'success'` for all three. Anything other than a literal success (failure, cancellation, skip) trips it, uploads a `quarantine-record` artifact, and blocks `deploy-staging`, which is only reachable if `deploy-gate` succeeded.

**Demonstrating the fail-closed trigger:** push a branch with a badly formatted file or a dummy secret (e.g. an `AKIA...`-prefixed string, which gitleaks recognizes as an AWS key signature) in a scratch file, open a PR, and watch `lint-and-format` or `secret-scan` fail, `deploy-gate` block and quarantine, and `deploy-staging` never start.

**Enforcing it at the merge button** (not just a visual warning): add a branch protection rule on `main` requiring the `deploy-gate` status check to pass before merging; this only becomes selectable after the workflow has run at least once.

**Enabling the real deploy step:** `deploy-staging` authenticates via Workload Identity Federation rather than a downloaded key file. It needs two repo secrets—`WIF_PROVIDER` (a workload identity provider resource path) and `DEPLOY_SERVICE_ACCOUNT` (a service account email)—created via a one-time `gcloud` setup (pool → provider scoped to this exact repo → service account → IAM bindings linking them). This step also needs an `app.staging.yaml` App Engine config that doesn't exist yet in this repo, so `deploy-staging` will still fail until that's scaffolded. Not implemented for the three assessed tasks, but the gate logic itself is fully testable without it.

## 4. Task 3: Schema Mapping & DCYN Validation (`django_app/`)
**`dcyn.py`** is the single choke point for every yes/no decision in the intake form. It accepts _only_ the exact strings `"Yes"` and `"No"`—no `"y"`, `"true"`, `"1"`, or empty string—and raises `DCYNValidationError` on anything else. Centralizing this logic means no other file in the codebase reimplements its own truthy/falsy coercion.

**`serializers.py`** maps the incoming JSON payload to the D1 `student_onboarding` schema field-for-field:
- `DCYNField` (built on DRF's `ChoiceField`) replaces `BooleanField` for every binary field, so the wire format itself is restricted to `"Yes"`/`"No"` rather than DRF's normally-lenient boolean parsing.
- Every field is required, none has a `default=`, so a missing answer fails validation instead of silently resolving to `False`.
- `region_code` is a closed `ChoiceField` over five defined codes (Bangalore, Mumbai, Kolkata, Delhi, Nagpur), not free text.
- A cross-field rule in `validate()` enforces that `requires_lsa_support` can only be `True` if `guardian_consent_given` is also `True`.

Run the example at the bottom of `serializers.py` directly (`python serializers.py`, with `djangorestframework` installed) to see a valid payload pass validation end-to-end.

## 5. Running & Testing the Project End-to-End
1. **Provision infrastructure:** `cd terraform && terraform init && terraform apply`.
2. **Verify in the GCP Console:** Cloud Storage → Buckets for the raw landing bucket; BigQuery → Explorer for the `d1_staged_enforced` dataset and its two tables; IAM & Admin → Service Accounts for `d0-d1-pipeline-runner`.
3. **Test the CI/CD gate:** create a branch, add a deliberately broken file (bad formatting + a fake `AKIA...` secret) under `django_app/`, push, and open a PR into `main`. Watch the Actions tab; `lint-and-format` and `secret-scan` should fail, `deploy-gate` should block and quarantine. Fix the file and push again to watch every gate go green.
4. **Add branch protection:** once one workflow run exists, add a rule on `main` requiring the `deploy-gate` check, so a failing PR's merge button is actually disabled, not just flagged.
5. **Test the serializer:** `pip install djangorestframework` then `python django_app/serializers.py`; then try changing a `"Yes"` to `"yes"` in the sample payload to see `DCYNValidationError` fire.
6. **Tear down cleanly:** `terraform destroy` (with `destroy_all_resources = true`) removes the bucket, dataset, tables, and service account with nothing left behind.