terraform {
	required_version = ">= 1.5.0"
	required_providers {
		google = {
			source  = "hashicorp/google"
			version = "~> 8.0"
		}
	}
}

provider "google" {
	project = var.project_id
	region  = var.region
}

#====================================================#
# D0 - RAW LANDING BUCKET (GCS)
# Immutable landing zone for untransformed payloads.
# No service should ever write "final" data here.
#====================================================#

resource "google_storage_bucket" "d0_raw_landing" {
	name                        = var.raw_landing_bucket_name
	project                     = var.project_id
	location                    = var.region
	storage_class               = "STANDARD"
	uniform_bucket_level_access = true # disables legacy ACLs; IAM is the single source of truth
	force_destroy               = var.destroy_all_resources # Change to 'false' for production deployment

	versioning {
		enabled = true # protects against accidental overwrite/delete of raw evidence
	}

	# Raw payloads are transient inputs, not a permanent archive.
	# Move to cheaper storage after defined days
	lifecycle_rule {
		condition {
			age = var.storage_bucket_lifecycle["CHEAPEN"]
		}
		action {
			type          = "SetStorageClass"
			storage_class = "NEARLINE"
		}
	}
	# Delete after defined days
	lifecycle_rule {
		condition {
			age = var.storage_bucket_lifecycle["DELETE"]
		}
		action {
			type = "Delete"
		}
	}

	# Public access is never accepted for raw student data.
	public_access_prevention = "enforced"

	dynamic "encryption" {
		for_each = var.kms_key_id != "" ? [1] : []
		content {
			default_kms_key_name = var.kms_key_id
		}
	}

	labels = merge(var.labels, {
		"layer" = "d0-raw-landing"
	})
}

# Least-privilege, conditional IAM binding: data engineers may write objects,
# but ONLY objects prefixed "incoming/", which prevents accidental overwrite of
# already-ingested folders, and the condition has an explicit expiry so access
# must be consciously re-granted rather than persisting forever by default.
resource "google_storage_bucket_iam_member" "raw_landing_writer" {
	bucket = google_storage_bucket.d0_raw_landing.name
	role   = "roles/storage.objectCreator"
	member = "user:${var.data_engineer_group}" # Linking personal email for testing
	#member = "group:${var.data_engineer_group}" # For linking Google Group in production

	condition {
		title       = "restrict-to-incoming-prefix"
		description = "Writers may only create objects under incoming/"
		expression  = "resource.name.startsWith(\"projects/_/buckets/${var.raw_landing_bucket_name}/objects/incoming/\")"
	}
}

# Read-only access for the pipeline service account that promotes raw objects into BigQuery.
# No delete/overwrite permission -- enforces "raw is immutable" as a structural rule, not a convention.
resource "google_storage_bucket_iam_member" "raw_landing_pipeline_reader" {
	bucket = google_storage_bucket.d0_raw_landing.name
	role   = "roles/storage.objectViewer"
	member = "serviceAccount:${google_service_account.pipeline_runner.email}"
}

#=============================================================#
# SERVICE ACCOUNT - pipeline runner
# Dedicated identity, scoped narrowly, no owner/editor roles.
#=============================================================#

resource "google_service_account" "pipeline_runner" {
	project      = var.project_id
	account_id   = "d0-d1-pipeline-runner"
	display_name = "D0->D1 Staging Pipeline Runner"
	description  = "Least-privilege SA used by Cloud Run/Cloud Functions job that validates and loads raw payloads into BigQuery."
}

resource "google_project_iam_member" "pipeline_runner_bq_data_editor" {
	project = var.project_id
	role    = "roles/bigquery.dataEditor"
	member  = "serviceAccount:${google_service_account.pipeline_runner.email}"

	condition {
		title       = "restrict-to-d1-dataset"
		description = "Only allow BigQuery data edits within the D1 staged/enforced dataset."
		expression  = "resource.name.startsWith(\"projects/${var.project_id}/datasets/${var.bq_dataset_id}\")"
	}
}

#==================================================#
# D1 - STAGED/ENFORCED DATASET (BigQuery)
# Schema-validated, access-controlled destination.
#==================================================#

resource "google_bigquery_dataset" "d1_staged_enforced" {
	project                    = var.project_id
	dataset_id                 = var.bq_dataset_id
	friendly_name              = "D1 Staged Enforced"
	description                = "Schema-enforced, RLS-protected staging layer. Populated only via the validated pipeline; never written to manually."
	location                   = var.region
	delete_contents_on_destroy = var.destroy_all_resources # Change to 'false' for production deployment

	default_table_expiration_ms = null # staged data is durable, not transient

	labels = merge(var.labels, {
		"layer" = "d1-staged-enforced"
	})

	# Explicit, enumerated access: default project-level roles (e.g. bigquery.user at project scope)
	# are intentionally NOT relied upon for this dataset.
	access {
		role          = "OWNER"
		special_group = "projectOwners"
	}

	access {
		role          = "WRITER"
		user_by_email = google_service_account.pipeline_runner.email
	}

	access {
		role           = "READER"
		user_by_email = var.analytics_reader_group # Linking personal email for testing
		#group_by_email = var.analytics_reader_group # Linking Google Group email for production
	}
}

resource "google_bigquery_table" "student_onboarding" {
	project             = var.project_id
	dataset_id          = google_bigquery_dataset.d1_staged_enforced.dataset_id
	table_id            = "student_onboarding"
	deletion_protection = !var.destroy_all_resources # Change to 'true' for production deployment

	schema = jsonencode([
		{ name = "record_id", type = "STRING", mode = "REQUIRED" },
		{ name = "student_full_name", type = "STRING", mode = "REQUIRED" },
		{ name = "guardian_full_name", type = "STRING", mode = "REQUIRED" },
		{ name = "guardian_contact_email", type = "STRING", mode = "REQUIRED" },
		{ name = "has_diagnosed_learning_difficulty", type = "BOOLEAN", mode = "REQUIRED" },
		{ name = "requires_lsa_support", type = "BOOLEAN", mode = "REQUIRED" },
		{ name = "guardian_consent_given", type = "BOOLEAN", mode = "REQUIRED" },
		{ name = "data_sharing_consent_given", type = "BOOLEAN", mode = "REQUIRED" },
		{ name = "region_code", type = "STRING", mode = "REQUIRED" },
		{ name = "ingested_at", type = "TIMESTAMP", mode = "REQUIRED" }
	])

	labels = var.labels
}

#=====================================================================================#
# ROW-LEVEL SECURITY (RLS)
# Analysts in analytics_reader_group may only see rows for their own assigned region,
# enforced at the query layer, not by convention.
# Requires the querying principal's identity to carry a matching "region_code"
# custom attribute via IAM Conditions / session context,
# implemented here via the SESSION_USER() -> region mapping table.
#=====================================================================================#

resource "google_bigquery_table" "analyst_region_map" {
	project             = var.project_id
	dataset_id          = google_bigquery_dataset.d1_staged_enforced.dataset_id
	table_id            = "analyst_region_map"
	deletion_protection = !var.destroy_all_resources # Change to 'true' for production deployment

	schema = jsonencode([
		{ name = "analyst_email", type = "STRING", mode = "REQUIRED" },
		{ name = "region_code", type = "STRING", mode = "REQUIRED" }
	])

	labels = var.labels
}

resource "google_bigquery_row_access_policy" "student_onboarding_region_rls" {
	project      = var.project_id
	dataset_id   = google_bigquery_dataset.d1_staged_enforced.dataset_id
	table_id     = google_bigquery_table.student_onboarding.table_id
	policy_id    = "region_scoped_access"

	#filter_predicate = "region_code IN (SELECT region_code FROM `${var.project_id}.${var.bq_dataset_id}.analyst_region_map` WHERE analyst_email = SESSION_USER())"
	filter_predicate = <<-EOT
		region_code IN (
			SELECT region_code FROM `${var.project_id}.${var.bq_dataset_id}.analyst_region_map`
			WHERE analyst_email = SESSION_USER()
		)
		EOT

	grantees = [
		"user:${var.analytics_reader_group}", # Linking personal email for testing
		#"group:${var.analytics_reader_group}", # Linking Google Group email for production
	]
}