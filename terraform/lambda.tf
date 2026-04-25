# Lambda function for the FastAPI backend

# S3 bucket for Lambda deployment packages
resource "aws_s3_bucket" "lambda_deployment" {
  bucket = "${local.name_prefix}-lambda-deploy-${local.name_suffix}"

  tags = {
    Name = "${local.name_prefix}-lambda-deploy"
  }
}

resource "aws_s3_bucket_versioning" "lambda_deployment" {
  bucket = aws_s3_bucket.lambda_deployment.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "lambda_deployment" {
  bucket = aws_s3_bucket.lambda_deployment.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM role for Lambda
resource "aws_iam_role" "lambda" {
  name = "${local.name_prefix}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Lambda basic execution policy
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Secrets Manager access policy
resource "aws_iam_role_policy" "lambda_secrets" {
  name = "${local.name_prefix}-lambda-secrets"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          aws_secretsmanager_secret.app_config.arn
        ]
      }
    ]
  })
}

# DynamoDB access policy
resource "aws_iam_role_policy" "lambda_dynamodb" {
  name = "${local.name_prefix}-lambda-dynamodb"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:BatchWriteItem"
        ]
        Resource = [
          aws_dynamodb_table.requests.arn
        ]
      }
    ]
  })
}

# S3 access policy for cache warmer to write trending data
resource "aws_iam_role_policy" "lambda_trending_s3" {
  name = "${local.name_prefix}-lambda-trending-s3"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = [
          "${aws_s3_bucket.trending.arn}/*"
        ]
      }
    ]
  })
}

# Lambda Layer for heavy dependencies (cryptography)
# Only loaded when push notifications are sent (webhook handler)
resource "aws_lambda_layer_version" "deps" {
  layer_name          = "${local.name_prefix}-deps"
  description         = "Heavy dependencies (cryptography) for push notifications"
  compatible_runtimes = ["python3.12"]
  compatible_architectures = ["arm64"]

  # Placeholder - updated by deploy script
  filename         = data.archive_file.layer_placeholder.output_path
  source_code_hash = data.archive_file.layer_placeholder.output_base64sha256

  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }
}

data "archive_file" "layer_placeholder" {
  type        = "zip"
  output_path = "${path.module}/.terraform/layer_placeholder.zip"

  source {
    content  = "# Placeholder"
    filename = "python/placeholder.txt"
  }
}

# Lambda function
resource "aws_lambda_function" "api" {
  function_name = "${local.name_prefix}-api"
  role          = aws_iam_role.lambda.arn
  handler       = "main.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]  # Graviton2 - faster and 20% cheaper
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory
  layers        = [aws_lambda_layer_version.deps.arn]

  # Placeholder - will be updated by CI/CD
  filename         = data.archive_file.lambda_placeholder.output_path
  source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256

  # No VPC - Lambda can access internet directly for TMDB API

  environment {
    variables = {
      DYNAMODB_TABLE            = aws_dynamodb_table.requests.name
      APP_SECRET_ARN            = aws_secretsmanager_secret.app_config.arn
      AWS_REGION_NAME           = var.aws_region
      BASE_URL                  = "https://${var.domain_name}"
      ALLOWED_ORIGIN            = "https://${var.domain_name}"
      RATE_LIMIT_ENABLED        = var.enable_rate_limiting ? "true" : "false"
      RATE_LIMIT_MAX_ATTEMPTS   = tostring(var.rate_limit_max_attempts)
      RATE_LIMIT_WINDOW_SECONDS = tostring(var.rate_limit_window_seconds)
      VAPID_PUBLIC_KEY          = terraform_data.vapid_keys.output.public_key
    }
  }

  tags = {
    Name = "${local.name_prefix}-api"
  }
}

# Placeholder for initial deployment
data "archive_file" "lambda_placeholder" {
  type        = "zip"
  output_path = "${path.module}/.terraform/lambda_placeholder.zip"

  source {
    content  = "# Placeholder - deploy actual code via CI/CD"
    filename = "placeholder.py"
  }
}

# Lambda function URL (alternative to API Gateway, simpler)
resource "aws_lambda_function_url" "api" {
  function_name      = aws_lambda_function.api.function_name
  authorization_type = "NONE"

  cors {
    allow_origins     = ["https://${var.domain_name}"]
    allow_methods     = ["*"]
    allow_headers     = ["*"]
    allow_credentials = true
    max_age           = 3600
  }
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${aws_lambda_function.api.function_name}"
  retention_in_days = 14
}


# =============================================================================
# EventBridge Rule for Trending Cache Warming
# Fetches trending data from TMDB and writes to S3 daily
# =============================================================================

resource "aws_cloudwatch_event_rule" "trending_cache_warmer" {
  name                = "${local.name_prefix}-trending-cache-warmer"
  description         = "Fetch trending data from TMDB and write to S3"
  schedule_expression = "rate(24 hours)"

  tags = {
    Name = "${local.name_prefix}-trending-cache-warmer"
  }
}

resource "aws_cloudwatch_event_target" "trending_cache_warmer" {
  rule      = aws_cloudwatch_event_rule.trending_cache_warmer.name
  target_id = "TrendingCacheWarmer"
  arn       = aws_lambda_function.cache_warmer.arn
}

# Separate lightweight Lambda for cache warming
# Fetches trending data from TMDB and writes to S3
resource "aws_lambda_function" "cache_warmer" {
  function_name = "${local.name_prefix}-cache-warmer"
  role          = aws_iam_role.lambda.arn
  handler       = "cache_warmer.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  timeout       = 60  # Needs time to fetch trending from TMDB
  memory_size   = 128

  # Placeholder - will be updated by CI/CD
  filename         = data.archive_file.lambda_placeholder.output_path
  source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256

  environment {
    variables = {
      APP_SECRET_ARN    = aws_secretsmanager_secret.app_config.arn
      AWS_REGION_NAME   = var.aws_region
      TRENDING_S3_BUCKET = aws_s3_bucket.trending.id
    }
  }

  tags = {
    Name = "${local.name_prefix}-cache-warmer"
  }
}

# CloudWatch Log Group for cache warmer
resource "aws_cloudwatch_log_group" "cache_warmer" {
  name              = "/aws/lambda/${aws_lambda_function.cache_warmer.function_name}"
  retention_in_days = 7  # Less retention needed for cache warmer logs
}

# Allow EventBridge to invoke the cache warmer Lambda
resource "aws_lambda_permission" "cache_warmer_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cache_warmer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.trending_cache_warmer.arn
}


# =============================================================================
# EventBridge Rule for Search Autocomplete Index
# Fetches popularity-ranked discover pages from TMDB and writes a static
# autocomplete index to S3. Refreshed weekly - the popular set changes slowly.
# =============================================================================

resource "aws_cloudwatch_event_rule" "autocomplete_warmer" {
  name                = "${local.name_prefix}-autocomplete-warmer"
  description         = "Build search autocomplete index from TMDB and write to S3"
  schedule_expression = "rate(7 days)"

  tags = {
    Name = "${local.name_prefix}-autocomplete-warmer"
  }
}

resource "aws_cloudwatch_event_target" "autocomplete_warmer" {
  rule      = aws_cloudwatch_event_rule.autocomplete_warmer.name
  target_id = "AutocompleteWarmer"
  arn       = aws_lambda_function.autocomplete_warmer.arn
}

# Separate lightweight Lambda for the autocomplete index
# Walks /discover/{movie,tv}?sort_by=popularity.desc and writes the result
# to the trending S3 bucket as autocomplete-<locale>.json
resource "aws_lambda_function" "autocomplete_warmer" {
  function_name = "${local.name_prefix}-autocomplete-warmer"
  role          = aws_iam_role.lambda.arn
  handler       = "autocomplete_warmer.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  timeout       = 300  # ~250 pages per media type per locale; sequential fetches
  memory_size   = 256

  # Placeholder - will be updated by CI/CD
  filename         = data.archive_file.lambda_placeholder.output_path
  source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256

  environment {
    variables = {
      APP_SECRET_ARN           = aws_secretsmanager_secret.app_config.arn
      AWS_REGION_NAME          = var.aws_region
      TRENDING_S3_BUCKET       = aws_s3_bucket.trending.id
      AUTOCOMPLETE_LOCALES     = "en"
      AUTOCOMPLETE_TARGET_SIZE = "5000"
    }
  }

  tags = {
    Name = "${local.name_prefix}-autocomplete-warmer"
  }
}

# CloudWatch Log Group for autocomplete warmer
resource "aws_cloudwatch_log_group" "autocomplete_warmer" {
  name              = "/aws/lambda/${aws_lambda_function.autocomplete_warmer.function_name}"
  retention_in_days = 7
}

# Allow EventBridge to invoke the autocomplete warmer Lambda
resource "aws_lambda_permission" "autocomplete_warmer_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.autocomplete_warmer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.autocomplete_warmer.arn
}
