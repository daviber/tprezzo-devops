data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_iam_policy_document" "app_runner_assume_role" {
  statement {
    sid     = "AllowAppRunnerTasks"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["tasks.apprunner.amazonaws.com"]
    }
  }
}

locals {
  name_prefix               = lower("${var.project_name}-${var.environment}")
  textract_bucket_name      = var.textract_bucket_name_override != null ? var.textract_bucket_name_override : lower("${local.name_prefix}-${data.aws_caller_identity.current.account_id}-${var.aws_region}-textract")
  price_centric_bucket_name = var.price_centric_bucket_name_override != null ? var.price_centric_bucket_name_override : lower("${local.name_prefix}-${data.aws_caller_identity.current.account_id}-${var.aws_region}-price-centric")
  vps_app_user_name         = var.vps_app_user_name_override != null ? var.vps_app_user_name_override : "${local.name_prefix}-vps-app"
  app_runner_role_name      = var.app_runner_role_name_override != null ? var.app_runner_role_name_override : "${local.name_prefix}-app-runner-document-ai"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Stack       = "document-ai"
  }
}

resource "aws_s3_bucket" "textract_documents" {
  bucket        = local.textract_bucket_name
  force_destroy = var.textract_bucket_force_destroy
}

resource "aws_s3_bucket_public_access_block" "textract_documents" {
  bucket = aws_s3_bucket.textract_documents.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "textract_documents" {
  bucket = aws_s3_bucket.textract_documents.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "textract_documents" {
  bucket = aws_s3_bucket.textract_documents.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "textract_documents" {
  bucket = aws_s3_bucket.textract_documents.id

  rule {
    id     = "expire-temporary-documents"
    status = "Enabled"

    filter {
      prefix = ""
    }

    expiration {
      days = var.textract_documents_expiration_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket" "price_centric_documents" {
  bucket        = local.price_centric_bucket_name
  force_destroy = var.price_centric_bucket_force_destroy
}

resource "aws_s3_bucket_public_access_block" "price_centric_documents" {
  bucket = aws_s3_bucket.price_centric_documents.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "price_centric_documents" {
  bucket = aws_s3_bucket.price_centric_documents.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "price_centric_documents" {
  bucket = aws_s3_bucket.price_centric_documents.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "price_centric_documents" {
  bucket = aws_s3_bucket.price_centric_documents.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "price_centric_documents" {
  bucket = aws_s3_bucket.price_centric_documents.id

  rule {
    id     = "expire-temporary-price-centric-documents"
    status = "Enabled"

    filter {
      prefix = ""
    }

    expiration {
      days = var.price_centric_documents_expiration_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "document_ai" {
  statement {
    sid = "AllowTextract"

    actions = [
      "textract:AnalyzeDocument",
      "textract:AnalyzeExpense",
      "textract:DetectDocumentText",
      "textract:GetDocumentAnalysis",
      "textract:GetDocumentTextDetection",
      "textract:GetExpenseAnalysis",
      "textract:StartDocumentAnalysis",
      "textract:StartDocumentTextDetection",
      "textract:StartExpenseAnalysis"
    ]

    resources = ["*"]
  }

  statement {
    sid = "AllowBedrockInference"

    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream"
    ]

    # Converse uses InvokeModel IAM permission. Explicit model/profile ARNs only.
    resources = var.bedrock_inference_resource_arns
  }

  statement {
    sid = "AllowTextractBucketList"

    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket"
    ]

    resources = [
      aws_s3_bucket.textract_documents.arn,
      aws_s3_bucket.price_centric_documents.arn
    ]
  }

  statement {
    sid = "AllowTextractBucketObjects"

    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:PutObject"
    ]

    resources = [
      "${aws_s3_bucket.textract_documents.arn}/*",
      "${aws_s3_bucket.price_centric_documents.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "document_ai" {
  name        = "${local.name_prefix}-document-ai"
  description = "Permessi minimi per Tprezzo su Textract, Bedrock e bucket S3 temporaneo."
  policy      = data.aws_iam_policy_document.document_ai.json
}

resource "aws_iam_user" "vps_app" {
  count = var.create_vps_app_user ? 1 : 0
  name  = local.vps_app_user_name
}

resource "aws_iam_user_policy_attachment" "vps_app_document_ai" {
  count      = var.create_vps_app_user ? 1 : 0
  user       = aws_iam_user.vps_app[0].name
  policy_arn = aws_iam_policy.document_ai.arn
}

resource "aws_iam_role" "app_runner_document_ai" {
  name               = local.app_runner_role_name
  assume_role_policy = data.aws_iam_policy_document.app_runner_assume_role.json
}

resource "aws_iam_role_policy_attachment" "app_runner_document_ai" {
  role       = aws_iam_role.app_runner_document_ai.name
  policy_arn = aws_iam_policy.document_ai.arn
}
