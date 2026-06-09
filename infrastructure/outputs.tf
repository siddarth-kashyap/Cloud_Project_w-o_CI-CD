output "cloudfront_url" {
  description = "The domain name of the CloudFront distribution"
  value       = aws_cloudfront_distribution.cdn.domain_name
}

output "s3_bucket_name" {
  description = "The name of the S3 bucket holding the frontend files"
  value       = aws_s3_bucket.frontend_bucket.id
}

output "api_gateway_url" {
  description = "The URL of the API Gateway invoking the Lambda function"
  value       = aws_apigatewayv2_api.http_api.api_endpoint
}