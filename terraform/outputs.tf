#################################
# Sonal Karmakar                #
# sonalkarmakar00@gmail.com     #
# sonal.karmakar@protonmail.com #
#################################

output "raw_landing_bucket_url" {
	description = "gsutil URI of the D0 raw landing bucket."
	value       = google_storage_bucket.d0_raw_landing.url
}

output "raw_landing_bucket_self_link" {
	value = google_storage_bucket.d0_raw_landing.self_link
}

output "bq_dataset_id" {
	description = "Fully qualified D1 staged/enforced dataset ID."
	value       = "${var.project_id}:${google_bigquery_dataset.d1_staged_enforced.dataset_id}"
}

output "pipeline_runner_service_account" {
	description = "Email of the least-privilege pipeline service account."
	value       = google_service_account.pipeline_runner.email
}

output "student_onboarding_table_id" {
	value = google_bigquery_table.student_onboarding.table_id
}