# 1. Terraform Settings and Remote Backend
terraform {
  backend "s3" {
    # REPLACE with the exact bucket name you created in Step 1
    bucket         = "resume-tf-state-sid-bucket-2026"
    key            = "infrastructure/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# 2. Configure the AWS Provider
provider "aws" {
  region = "ap-south-1"
}

# 3. Create the S3 Bucket for your Frontend Resume
resource "aws_s3_bucket" "frontend_bucket" {
  # S3 bucket names must be globally unique. Add some random numbers here.
  bucket = "siddarth-resume-frontend-998877"
}

# 4. Enforce Security: Block all public access to the bucket
# We do this because users will access the site via CloudFront (CDN), not directly via S3.
resource "aws_s3_bucket_public_access_block" "frontend_public_access_block" {
  bucket = aws_s3_bucket.frontend_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 5. CloudFront Origin Access Control (OAC)
# This acts as the secure "badge" allowing CloudFront to read the private bucket
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "resume-frontend-oac"
  description                       = "OAC for Resume Frontend"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# 6. The CloudFront Distribution (CDN)
resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  origin {
    # Points to your S3 bucket
    domain_name              = aws_s3_bucket.frontend_bucket.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
    origin_id                = "S3-${aws_s3_bucket.frontend_bucket.bucket}"
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${aws_s3_bucket.frontend_bucket.bucket}"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
    # Forces all HTTP traffic to HTTPS
    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# 7. S3 Bucket Policy
# This explicitly tells the S3 bucket to allow read access ONLY from the specific CloudFront distribution above
resource "aws_s3_bucket_policy" "frontend_policy" {
  bucket = aws_s3_bucket.frontend_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontServicePrincipal"
        Effect    = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.frontend_bucket.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
          }
        }
      }
    ]
  })
}

# 8. DynamoDB Table for Visitor Counter
resource "aws_dynamodb_table" "visitor_count" {
  name         = "resume-visitor-count"
  billing_mode = "PAY_PER_REQUEST" # Serverless billing (you only pay for exact reads/writes)
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S" # String type
  }
}

# 9. Initialize the counter at 0
resource "aws_dynamodb_table_item" "init_count" {
  table_name = aws_dynamodb_table.visitor_count.name
  hash_key   = aws_dynamodb_table.visitor_count.hash_key

  item = <<ITEM
{
  "id": {"S": "counter"},
  "visits": {"N": "0"}
}
ITEM
}

# 10. Automatically Zip the Python Code
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "../backend/lambda_function.py"
  output_path = "../backend/lambda_function.zip"
}

# 11. IAM Role for Lambda
resource "aws_iam_role" "lambda_exec_role" {
  name = "resume_lambda_exec_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# 12. IAM Policy: Allow Lambda to Update DynamoDB
resource "aws_iam_role_policy" "lambda_dynamodb_policy" {
  name = "lambda_dynamodb_policy"
  role = aws_iam_role.lambda_exec_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = ["dynamodb:UpdateItem", "dynamodb:GetItem"]
      Effect   = "Allow"
      Resource = aws_dynamodb_table.visitor_count.arn
    }]
  })
}

# 13. The Lambda Function
resource "aws_lambda_function" "api_lambda" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "ResumeCounterFunction"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.10"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.visitor_count.name
    }
  }
}

# 14. API Gateway (HTTP API)
resource "aws_apigatewayv2_api" "http_api" {
  name          = "resume-counter-api"
  protocol_type = "HTTP"
  
  # CORS: Only allow requests from your specific CloudFront URL
  cors_configuration {
    allow_origins = ["https://${aws_cloudfront_distribution.cdn.domain_name}"]
    allow_methods = ["POST", "GET", "OPTIONS"]
    allow_headers = ["content-type"]
    max_age       = 300
  }
}

# 15. API Gateway Stage and Integration
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id           = aws_apigatewayv2_api.http_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.api_lambda.invoke_arn
}

resource "aws_apigatewayv2_route" "post_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /count"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# 16. Permission for API Gateway to trigger Lambda
resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}