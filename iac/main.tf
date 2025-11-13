# -----------------------------------------------------------------------------------------------------
# Proyecto: Lakehouse Challenge
# -----------------------------------------------------------------------------------------------------
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# -----------------------------------------------------------------------------------------------------
# S3 Bucket Configuration
# -----------------------------------------------------------------------------------------------------
resource "aws_s3_bucket" "raw_data" {
  bucket = "${var.project_name}-${var.environment}-raw"
  force_destroy = true
}

resource "aws_s3_bucket_policy" "raw_policy" {
  bucket     = aws_s3_bucket.raw_data.id
  depends_on = [aws_s3_bucket.raw_data]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowGlueAccess"
        Effect    = "Allow"
        Principal = { Service = "glue.amazonaws.com" }
        Action    = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [
          "${aws_s3_bucket.raw_data.arn}",
          "${aws_s3_bucket.raw_data.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_s3_bucket" "processed_data" {
  bucket = "${var.project_name}-${var.environment}-processed"
  force_destroy = true
}

resource "aws_s3_bucket_policy" "processed_policy" {
  bucket     = aws_s3_bucket.processed_data.id
  depends_on = [aws_s3_bucket.processed_data]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowGlueAccessProcessed"
        Effect    = "Allow"
        Principal = { Service = "glue.amazonaws.com" }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          "${aws_s3_bucket.processed_data.arn}",
          "${aws_s3_bucket.processed_data.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_s3_bucket" "scripts" {
  bucket = "${var.project_name}-${var.environment}-scripts"
  force_destroy = true
}

resource "aws_s3_bucket_policy" "scripts_policy" {
  bucket = aws_s3_bucket.scripts.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowGlueReadScripts"
        Effect    = "Allow"
        Principal = { Service = "glue.amazonaws.com" }
        Action    = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "${aws_s3_bucket.scripts.arn}",
          "${aws_s3_bucket.scripts.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_s3_bucket" "athena_results" {
  bucket        = "${var.project_name}-${var.environment}-athena-results"
  force_destroy = true
}

resource "aws_s3_bucket_policy" "athena_results_policy" {
  bucket = aws_s3_bucket.athena_results.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAthenaAccess"
        Effect    = "Allow"
        Principal = { Service = "athena.amazonaws.com" }
        Action    = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [
          "${aws_s3_bucket.athena_results.arn}",
          "${aws_s3_bucket.athena_results.arn}/*"
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------------------------------
# IAM Roles y Policies for Glue
# -----------------------------------------------------------------------------------------------------
resource "aws_iam_role" "glue_role" {
  name = "${var.project_name}-${var.environment}-glue-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "glue.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "glue_service_policy" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_policy" "glue_s3_access" {
  name = "${var.project_name}-${var.environment}-glue-s3-access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBucketAccess",
        Effect = "Allow",
        Action = [
          "s3:ListBucket"
        ],
        Resource = [
          "${aws_s3_bucket.raw_data.arn}",
          "${aws_s3_bucket.processed_data.arn}",
          "${aws_s3_bucket.scripts.arn}"
        ]
      },
      {
        Sid    = "AllowObjectAccess",
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ],
        Resource = [
          "${aws_s3_bucket.raw_data.arn}/*",
          "${aws_s3_bucket.processed_data.arn}/*",
          "${aws_s3_bucket.scripts.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "glue_s3_access_attach" {
  role       = aws_iam_role.glue_role.name
  policy_arn = aws_iam_policy.glue_s3_access.arn
}

# -----------------------------------------------------------------------------------------------------
# Glue Database
# -----------------------------------------------------------------------------------------------------
resource "aws_glue_catalog_database" "catalog_db" {
  name = replace("${var.project_name}_${var.environment}_db", "-", "_")
}

# -----------------------------------------------------------------------------------------------------
# Glue Crawler for RAW data
# -----------------------------------------------------------------------------------------------------
resource "aws_glue_crawler" "raw_crawler" {
  name          = "${var.project_name}-${var.environment}-raw-crawler"
  role          = aws_iam_role.glue_role.arn
  database_name = aws_glue_catalog_database.catalog_db.name

  s3_target {
    path = "s3://${aws_s3_bucket.raw_data.bucket}/"
  }

  table_prefix = "csv_"
}

# -----------------------------------------------------------------------------------------------------
# Upload source script for Glue Job
# -----------------------------------------------------------------------------------------------------
resource "aws_s3_object" "glue_script" {
  bucket = aws_s3_bucket.scripts.bucket
  key    = "scripts/transform_csv_to_parquet.py"
  source = "${path.module}/../src/jobs/transform_csv_to_parquet.py"
  etag   = filemd5("${path.module}/../src/jobs/transform_csv_to_parquet.py")
}

# -----------------------------------------------------------------------------------------------------
# Glue Job
# -----------------------------------------------------------------------------------------------------
resource "aws_glue_job" "csv_to_parquet" {
  name     = "${var.project_name}-${var.environment}-job"
  role_arn = aws_iam_role.glue_role.arn
  depends_on = [aws_s3_object.glue_script]

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.scripts.bucket}/scripts/transform_csv_to_parquet.py"
    python_version  = "3"
  }

  glue_version       = "4.0"
  worker_type        = "G.1X"
  number_of_workers  = 2
  max_retries        = 0
  timeout            = 5

  default_arguments = {
    "--TempDir"                 = "s3://${aws_s3_bucket.processed_data.bucket}/temp/"
    "--source_bucket"           = "${aws_s3_bucket.raw_data.bucket}"
    "--destination_bucket"      = "${aws_s3_bucket.processed_data.bucket}"
    "--input_path"              = "s3://${aws_s3_bucket.raw_data.bucket}/data/"
    "--output_path"             = "s3://${aws_s3_bucket.processed_data.bucket}/hudi"
    "--database_name"           = "${aws_glue_catalog_database.catalog_db.name}"    
    "--conf"                    = "spark.serializer=org.apache.spark.serializer.KryoSerializer"
    "--datalake-formats"        = "hudi"
    "--enable-glue-datacatalog" = "true"
  }
}

# -----------------------------------------------------------------------------------------------------
# Athena workGroup for query results
# -----------------------------------------------------------------------------------------------------
resource "aws_athena_workgroup" "lakehouse_wg" {
  name = "${var.project_name}-${var.environment}-wg"

  configuration {
    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/query-results/"
    }
  }
  state       = "ENABLED"
  force_destroy = true
}

# -----------------------------------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------------------------------
output "buckets" {
  description = "Buckets creados"
  value = {
    raw_data       = aws_s3_bucket.raw_data.bucket
    processed_data = aws_s3_bucket.processed_data.bucket
    job_scripts    = aws_s3_bucket.scripts.bucket
    athena_results = aws_s3_bucket.athena_results.bucket
  }
}

output "glue_catalog_db" {
  description = "Base de datos del Data Catalog"
  value       = aws_glue_catalog_database.catalog_db.name
}

output "aws_glue_job" {
  description = "Job de Glue de Procesamiento de Datos"
  value       = aws_glue_job.csv_to_parquet.name
}

output "athena_workgroup" {
  description = "WorkGroup configurado para resultados de Athena"
  value       = aws_athena_workgroup.lakehouse_wg.name
}

output "project_info" {
  description = "Información general del despliegue"
  value = {
    region       = var.region
    environment  = var.environment
    project_name = var.project_name
  }
}
