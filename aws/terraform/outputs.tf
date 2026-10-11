output "aws_account_id" {
  description = "AWS account id corrente."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "Regione configurata per lo stack."
  value       = var.aws_region
}

output "textract_bucket_name" {
  description = "Bucket S3 temporaneo per documenti Textract asincroni."
  value       = aws_s3_bucket.textract_documents.bucket
}

output "textract_bucket_arn" {
  description = "ARN del bucket S3 temporaneo Textract."
  value       = aws_s3_bucket.textract_documents.arn
}

output "price_centric_bucket_name" {
  description = "Bucket S3 privato per upload price-centric temporanei."
  value       = aws_s3_bucket.price_centric_documents.bucket
}

output "price_centric_bucket_arn" {
  description = "ARN del bucket S3 per upload price-centric temporanei."
  value       = aws_s3_bucket.price_centric_documents.arn
}

output "document_ai_policy_arn" {
  description = "ARN della policy condivisa per Bedrock, Textract e storage price-centric."
  value       = aws_iam_policy.document_ai.arn
}

output "vps_app_user_name" {
  description = "Nome dell'utente IAM dedicato alla VPS, se creato."
  value       = var.create_vps_app_user ? aws_iam_user.vps_app[0].name : null
}

output "vps_app_user_arn" {
  description = "ARN dell'utente IAM dedicato alla VPS, se creato."
  value       = var.create_vps_app_user ? aws_iam_user.vps_app[0].arn : null
}

output "app_runner_document_ai_role_arn" {
  description = "Ruolo IAM pronto per essere assegnato come instance role di App Runner."
  value       = aws_iam_role.app_runner_document_ai.arn
}
