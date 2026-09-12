variable "project_id" {
	description = "GCP project ID where staging resources are provisioned."
	type        = string
}

variable "region" {
	description = "GCP region for regional resources."
	type        = string
	default     = "asia-south2"
}

variable "environment" {
	description = "Deployment environment label (staging, production)."
	type        = string
	default     = "staging"
}

variable "raw_landing_bucket_name" {
	description = "Globally unique name for the D0 Raw Landing GCS bucket."
	type        = string
}

variable "storage_bucket_lifecycle" {
	description = "Lifecycle Rules for Google Storage Bucket"
	type        = map(number)
	default     = {
		CHEAPEN = 15
		DELETE  = 30
	}
}

variable "bq_dataset_id" {
	description = "BigQuery dataset ID for the D1 Staged/Enforced layer."
	type        = string
	default     = "d1_staged_enforced"
}

variable "data_engineer_group" {
	description = "Google Group email for engineers who need read/write access to raw landing data."
	type        = string
	validation {
		condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.data_engineer_group))
		error_message = "data_engineer_group must be a valid email address."
	}
}

variable "analytics_reader_group" {
	description = "Google Group email for analysts who may only read row-level-filtered staged data."
	type        = string
	validation {
		condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.analytics_reader_group))
		error_message = "analytics_reader_group must be a valid email address."
	}
}

variable "kms_key_id" {
	description = "Optional CMEK key resource ID for encrypting bucket contents. Leave empty to use Google-managed encryption."
	type        = string
	default     = ""
}

variable "labels" {
	description = "Common resource labels applied to all provisioned resources."
	type        = map(string)
	default     = {
		"owner"       = "data-platform"
		"managed-by"  = "terraform"
		"data-domain" = "student-onboarding"
	}
}