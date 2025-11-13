variable "region" {
  description = "Región AWS de Despliegue"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Entorno de Trabajo"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Nombre base del proyecto"
  type        = string
  default     = "lakehouse-challenge"
}
