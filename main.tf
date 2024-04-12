# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

# From: https://developer.hashicorp.com/terraform/tutorials/aws/lambda-api-gateway

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      hashicorp-learn = "lambda-api-gateway"
    }
  }

}

resource "random_pet" "lambda_bucket_name" {
  prefix = "learn-terraform-functions"
  length = 4
}

resource "aws_s3_bucket" "lambda_bucket" {
  bucket = random_pet.lambda_bucket_name.id
}

resource "aws_s3_bucket_ownership_controls" "lambda_bucket" {
  bucket = aws_s3_bucket.lambda_bucket.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "lambda_bucket" {
  depends_on = [aws_s3_bucket_ownership_controls.lambda_bucket]

  bucket = aws_s3_bucket.lambda_bucket.id
  acl    = "private"
}

data "archive_file" "lambda_hello_world" {
  type = "zip"

  source_dir  = "${path.module}/hello-world"
  output_path = "${path.module}/hello-world.zip"
}

resource "aws_s3_object" "lambda_hello_world" {
  bucket = aws_s3_bucket.lambda_bucket.id

  key    = "hello-world.zip"
  source = data.archive_file.lambda_hello_world.output_path

  etag = filemd5(data.archive_file.lambda_hello_world.output_path)
}

resource "aws_lambda_function" "hello_world" {
  function_name = "HelloWorld"

  s3_bucket = aws_s3_bucket.lambda_bucket.id
  s3_key    = aws_s3_object.lambda_hello_world.key

  runtime = "nodejs20.x"
  handler = "hello.handler"

  source_code_hash = data.archive_file.lambda_hello_world.output_base64sha256

  role = aws_iam_role.lambda_exec.arn

  environment {
    variables = {
      QUEUE_URL     = "${aws_sqs_queue.terraform_queue.url}",
      SNS_TOPIC_ARN = "${aws_sns_topic.terraform_sns_topic.arn}"
    }
  }
}

resource "aws_cloudwatch_log_group" "hello_world" {
  name              = "/aws/lambda/${aws_lambda_function.hello_world.function_name}"
  retention_in_days = 60
}

resource "aws_iam_role" "lambda_exec" {
  name = "serverless_lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Sid    = ""
      Principal = {
        Service = ["lambda.amazonaws.com", "sns.amazonaws.com"]
      }
      }
    ]
  })
}

resource "aws_iam_policy" "sqs_policy" {
  name        = "sqs_message_policy"
  path        = "/"
  description = "SQS Message Policy"

  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "sqs:sendmessage",
          "sqs:receivemessage",
          "sqs:deletemessage",
          "sqs:getqueueattributes"
        ]
        Effect   = "Allow"
        Resource = "${aws_sqs_queue.terraform_queue.arn}"
      },
    ]
  })
}

resource "aws_iam_policy" "sns_policy" {
  name        = "sns_message_policy"
  path        = "/"
  description = "SNS Message Policy"

  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "sns:publish",
          "sns:subscribe"
        ]
        Effect   = "Allow"
        Resource = "${aws_sns_topic.terraform_sns_topic.arn}"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "sqs_lambda_policy" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.sqs_policy.arn
}

resource "aws_iam_role_policy_attachment" "sns_lambda_policy" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.sns_policy.arn
}

resource "aws_apigatewayv2_api" "lambda" {
  name          = "serverless_lambda_gw"
  protocol_type = "HTTP"
}

##################
# resource "aws_api_gateway_rest_api_policy" "lambda" {
#   rest_api_id = aws_apigatewayv2_api.lambda.id

#   policy = <<EOF
# {
#   "Version": "2012-10-17",
#   "Statement": [
#     {
#       "Effect": "Allow",
#       "Principal": {
#         "AWS": "*"
#       },
#       "Action": "execute-api:Invoke",
#       "Resource": "${aws_apigatewayv2_api.lambda.execution_arn}",
#       "Condition": {
#         "IpAddress": {
#           "aws:SourceIp": "123.123.123.123/32"
#         }
#       }
#     }
#   ]
# }
# EOF
# }
###################

resource "aws_apigatewayv2_stage" "lambda" {
  api_id = aws_apigatewayv2_api.lambda.id

  name        = "serverless_lambda_stage"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn

    format = jsonencode({
      requestId               = "$context.requestId"
      sourceIp                = "$context.identity.sourceIp"
      requestTime             = "$context.requestTime"
      protocol                = "$context.protocol"
      httpMethod              = "$context.httpMethod"
      resourcePath            = "$context.resourcePath"
      routeKey                = "$context.routeKey"
      status                  = "$context.status"
      responseLength          = "$context.responseLength"
      integrationErrorMessage = "$context.integrationErrorMessage"
      }
    )
  }
}

resource "aws_apigatewayv2_integration" "hello_world" {
  api_id = aws_apigatewayv2_api.lambda.id

  integration_uri    = aws_lambda_function.hello_world.invoke_arn
  integration_type   = "AWS_PROXY"
  integration_method = "POST"
}

resource "aws_apigatewayv2_route" "hello_world" {
  api_id = aws_apigatewayv2_api.lambda.id

  route_key = "GET /hello"
  target    = "integrations/${aws_apigatewayv2_integration.hello_world.id}"
}

resource "aws_cloudwatch_log_group" "api_gw" {
  name = "/aws/api_gw/${aws_apigatewayv2_api.lambda.name}"

  retention_in_days = 30
}

resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.hello_world.function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_apigatewayv2_api.lambda.execution_arn}/*/*"
}

resource "aws_sqs_queue" "terraform_queue" {
  name                        = "terraform-example-queue"
  fifo_queue                  = false
  content_based_deduplication = false
}

resource "aws_lambda_event_source_mapping" "example" {
  event_source_arn = aws_sqs_queue.terraform_queue.arn
  function_name    = aws_lambda_function.hello_world.arn
}

resource "aws_lambda_permission" "allow_sqs" {
  statement_id  = "AllowExecutionFromSQS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.hello_world.function_name
  principal     = "sqs.amazonaws.com"
  source_arn    = aws_sqs_queue.terraform_queue.arn
}

resource "aws_sns_topic" "terraform_sns_topic" {
  name = "user-updates-topic"
}

resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.hello_world.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.terraform_sns_topic.arn
}

resource "aws_sns_topic_subscription" "user_updates_sqs_target" {
  topic_arn = aws_sns_topic.terraform_sns_topic.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.terraform_queue.arn
}

# resource "aws_sns_topic_policy" "terraform_sns_topic_policy" {
#   arn = aws_sns_topic.terraform_sns_topic.arn

#   policy = data.aws_iam_policy_document.sns_topic_policy.json
# }

# data "aws_iam_policy_document" "sns_topic_policy" {
#   policy_id = "__default_policy_ID"

#   statement {
#     actions = [
#       "sqs:sendmessage",
#       "sqs:receivemessage",
#       "sqs:deletemessage",
#       "sqs:getqueueattributes"
#     ]

#     effect = "Allow"

#     principals {
#       type        = "AWS"
#       identifiers = ["*"]
#     }

#     resources = [
#       # aws_sns_topic.terraform_sns_topic.arn,
#       aws_sqs_queue.terraform_queue.arn
#     ]

#     sid = "__default_statement_ID"
#   }
# }
