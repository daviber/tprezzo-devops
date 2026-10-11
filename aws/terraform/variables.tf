variable "aws_region" {
  description = "Regione AWS per Textract/Bedrock."
  type        = string
  default     = "eu-central-1"
}

variable "aws_profile" {
  description = "Profilo AWS CLI locale usato da Terraform. Metti null se usi env vars o credenziali gia esportate."
  type        = string
  default     = null
}

variable "project_name" {
  description = "Prefisso progetto per naming e tagging."
  type        = string
  default     = "tprezzo"
}

variable "environment" {
  description = "Ambiente logico, ad esempio staging o prod."
  type        = string
  default     = "prod"
}

variable "textract_bucket_name_override" {
  description = "Nome bucket S3 custom. Se null, il nome viene calcolato automaticamente."
  type        = string
  default     = null
}

variable "textract_bucket_force_destroy" {
  description = "Se true consente a Terraform di eliminare il bucket Textract anche se contiene oggetti/versioni."
  type        = bool
  default     = false
}

variable "textract_documents_expiration_days" {
  description = "Quanti giorni tenere i documenti temporanei per Textract."
  type        = number
  default     = 7
}

variable "price_centric_bucket_name_override" {
  description = "Nome bucket S3 custom per upload price-centric temporanei. Se null, il nome viene calcolato automaticamente."
  type        = string
  default     = null
}

variable "price_centric_bucket_force_destroy" {
  description = "Se true consente a Terraform di eliminare il bucket price-centric anche se contiene oggetti/versioni."
  type        = bool
  default     = false
}

variable "price_centric_documents_expiration_days" {
  description = "Quanti giorni tenere gli upload price-centric temporanei."
  type        = number
  default     = 7

  validation {
    condition     = var.price_centric_documents_expiration_days >= 1
    error_message = "price_centric_documents_expiration_days deve essere almeno 1."
  }
}

variable "create_vps_app_user" {
  description = "Se true crea un utente IAM dedicato alla VPS."
  type        = bool
  default     = true
}

variable "vps_app_user_name_override" {
  description = "Nome custom per l'utente IAM della VPS."
  type        = string
  default     = null
}

variable "app_runner_role_name_override" {
  description = "Nome custom per il ruolo IAM futuro di App Runner."
  type        = string
  default     = null
}
