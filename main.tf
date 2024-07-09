locals {
  layer_zip_paths    = { for name, _ in var.lambda_layers : name => "${path.module}/lambda/layers/${name}.zip" }
  function_zip_paths = { for name, _ in var.lambda_functions : name => "${path.module}/lambda/${name}.zip" }
}

locals {
  layer_versions = {
    function1 = [
      aws_lambda_layer_version.my_layer["layer1"].arn,
      aws_lambda_layer_version.my_layer["layer2"].arn
    ]
    function2 = [
      aws_lambda_layer_version.my_layer["layer3"].arn,
      aws_lambda_layer_version.my_layer["layer1"].arn
    ]
    function3 = [
      aws_lambda_layer_version.my_layer["layer2"].arn,
      aws_lambda_layer_version.my_layer["layer3"].arn
    ]
  }
}

# S3 Bucket for Lambda Function Zips
resource "aws_s3_bucket" "lambda_bucket" {
  bucket = "ymk-lambda-bucket"
}

# IAM Role for Lambda
resource "aws_iam_role" "iam_for_lambda" {
  name = "iam_for_lambda"
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

# Attach IAM policy to the IAM role
resource "aws_iam_role_policy_attachment" "attach_lambda_policy" {
  role       = aws_iam_role.iam_for_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Create Lambda Layers
data "archive_file" "lambda_layer" {
  for_each    = var.lambda_layers
  type        = "zip"
  source_dir  = "${path.module}/lambda/layers/${each.key}/nodejs"
  output_path = local.layer_zip_paths[each.key]
}

resource "aws_lambda_layer_version" "my_layer" {
  for_each            = var.lambda_layers
  # skip_destroy        = true
  filename            = local.layer_zip_paths[each.key]
  layer_name          = each.key
  compatible_runtimes = each.value.runtime
  source_code_hash    = filebase64sha256(local.layer_zip_paths[each.key])

  lifecycle {
    create_before_destroy = true
  }
}

# Create Lambda Functions
data "archive_file" "lambda_function" {
  for_each    = var.lambda_functions
  type        = "zip"
  source_dir  = "${path.module}/lambda/${each.key}"
  output_path = local.function_zip_paths[each.key]
}

resource "aws_s3_object" "lambda_function_zip" {
  for_each = var.lambda_functions
  bucket   = aws_s3_bucket.lambda_bucket.bucket
  key      = basename(local.function_zip_paths[each.key])
  source   = local.function_zip_paths[each.key]
  etag     = filemd5(local.function_zip_paths[each.key])
}

resource "aws_lambda_function" "my_lambda" {
  for_each         = var.lambda_functions
  function_name    = each.key
  s3_bucket        = aws_s3_bucket.lambda_bucket.bucket
  s3_key           = basename(local.function_zip_paths[each.key])
  handler          = each.value.handler
  runtime          = each.value.runtime
  role             = aws_iam_role.iam_for_lambda.arn
  source_code_hash = filebase64sha256(local.function_zip_paths[each.key])

  layers = local.layer_versions[each.key]

  publish = true

  lifecycle {
    ignore_changes        = [layers]
    create_before_destroy = true
  }

  depends_on = [aws_s3_object.lambda_function_zip]
}

resource "aws_lambda_alias" "live" {
  for_each         = var.lambda_functions
  name             = "live"
  description      = "The live alias."
  function_name    = aws_lambda_function.my_lambda[each.key].function_name
  function_version = aws_lambda_function.my_lambda[each.key].version

  depends_on = [aws_lambda_function.my_lambda]
}

resource "aws_lambda_alias" "provisioned" {
  for_each         = var.lambda_functions
  name             = "provisioned"
  description      = "Alias for provisioned concurrency."
  function_name    = aws_lambda_function.my_lambda[each.key].function_name
  function_version = aws_lambda_function.my_lambda[each.key].version

  depends_on = [aws_lambda_function.my_lambda]
}

# Reference existing Lambda functions
data "aws_lambda_function" "existing_lambda" {
  for_each      = var.lambda_functions
  function_name = each.key
  depends_on    = [aws_lambda_function.my_lambda]
}

# Ensure function configuration updates with latest layer versions
resource "null_resource" "update_layers" {
  for_each = data.aws_lambda_function.existing_lambda

  provisioner "local-exec" {
    command = <<EOT
      aws lambda update-function-configuration --function-name ${each.key} --layers ${join(" ", local.layer_versions[each.key])}
    EOT
  }

  triggers = {
    function_name  = each.key
    layer_versions = join(",", local.layer_versions[each.key])
  }

  depends_on = [aws_lambda_layer_version.my_layer]
}

# Provisioned Concurrency Configuration
resource "aws_lambda_provisioned_concurrency_config" "function_concurrency" {
  for_each = var.lambda_functions

  function_name                     = aws_lambda_function.my_lambda[each.key].function_name
  qualifier                         = aws_lambda_alias.provisioned[each.key].name
  provisioned_concurrent_executions = 2

  depends_on = [
    aws_lambda_alias.provisioned
  ]
}

# Application Auto Scaling for Lambda Provisioned Concurrency
resource "aws_appautoscaling_target" "lambda_scaling_target" {
  for_each          = var.lambda_functions

  max_capacity      = 5
  min_capacity      = 2
  resource_id       = "function:${aws_lambda_function.my_lambda[each.key].function_name}:${aws_lambda_alias.provisioned[each.key].name}"
  scalable_dimension = "lambda:function:ProvisionedConcurrency"
  service_namespace  = "lambda"

  depends_on = [
    aws_lambda_provisioned_concurrency_config.function_concurrency
  ]
}

resource "aws_appautoscaling_policy" "lambda_scaling_policy" {
  for_each               = var.lambda_functions
  name                   = "lambda-scaling-policy"
  policy_type            = "TargetTrackingScaling"
  resource_id            = aws_appautoscaling_target.lambda_scaling_target[each.key].resource_id
  scalable_dimension     = aws_appautoscaling_target.lambda_scaling_target[each.key].scalable_dimension
  service_namespace      = aws_appautoscaling_target.lambda_scaling_target[each.key].service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 0.75

    predefined_metric_specification {
      predefined_metric_type = "LambdaProvisionedConcurrencyUtilization"
    }

    scale_in_cooldown  = 60
    scale_out_cooldown = 60
  }

  depends_on = [
    aws_appautoscaling_target.lambda_scaling_target
  ]
}









# locals {
#   layer_zip_paths    = { for name, _ in var.lambda_layers : name => "${path.module}/lambda/layers/${name}.zip" }
#   function_zip_paths = { for name, _ in var.lambda_functions : name => "${path.module}/lambda/${name}.zip" }
# }

# locals {
#   layer_versions = {
#     function1 = [
#       aws_lambda_layer_version.my_layer["layer1"].arn,
#       aws_lambda_layer_version.my_layer["layer2"].arn
#     ]
#     function2 = [
#       aws_lambda_layer_version.my_layer["layer3"].arn,
#       aws_lambda_layer_version.my_layer["layer1"].arn
#     ]
#     function3 = [
#       aws_lambda_layer_version.my_layer["layer2"].arn,
#       aws_lambda_layer_version.my_layer["layer3"].arn
#     ]
#   }
# }

# # S3 Bucket for Lambda Function Zips
# resource "aws_s3_bucket" "lambda_bucket" {
#   bucket = "ymk-lambda-bucket"
# }

# # IAM Role for Lambda
# resource "aws_iam_role" "iam_for_lambda" {
#   name = "iam_for_lambda"
#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Action = "sts:AssumeRole"
#         Effect = "Allow"
#         Principal = {
#           Service = "lambda.amazonaws.com"
#         }
#       }
#     ]
#   })
# }

# # Attach IAM policy to the IAM role
# resource "aws_iam_role_policy_attachment" "attach_lambda_policy" {
#   role       = aws_iam_role.iam_for_lambda.name
#   policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
# }

# # Create Lambda Layers
# data "archive_file" "lambda_layer" {
#   for_each    = var.lambda_layers
#   type        = "zip"
#   source_dir  = "${path.module}/lambda/layers/${each.key}/nodejs"
#   output_path = local.layer_zip_paths[each.key]
# }

# resource "aws_lambda_layer_version" "my_layer" {
#   for_each            = var.lambda_layers
#   # skip_destroy        = true
#   filename            = local.layer_zip_paths[each.key]
#   layer_name          = each.key
#   compatible_runtimes = each.value.runtime
#   source_code_hash    = filebase64sha256(local.layer_zip_paths[each.key])

#   lifecycle {
#     create_before_destroy = true
#   }
# }

# # Create Lambda Functions
# data "archive_file" "lambda_function" {
#   for_each    = var.lambda_functions
#   type        = "zip"
#   source_dir  = "${path.module}/lambda/${each.key}"
#   output_path = local.function_zip_paths[each.key]
# }

# resource "aws_s3_object" "lambda_function_zip" {
#   for_each = var.lambda_functions
#   bucket   = aws_s3_bucket.lambda_bucket.bucket
#   key      = basename(local.function_zip_paths[each.key])
#   source   = local.function_zip_paths[each.key]
#   etag     = filemd5(local.function_zip_paths[each.key])
# }

# resource "aws_lambda_function" "my_lambda" {
#   for_each         = var.lambda_functions
#   function_name    = each.key
#   s3_bucket        = aws_s3_bucket.lambda_bucket.bucket
#   s3_key           = basename(local.function_zip_paths[each.key])
#   handler          = each.value.handler
#   runtime          = each.value.runtime
#   role             = aws_iam_role.iam_for_lambda.arn
#   source_code_hash = filebase64sha256(local.function_zip_paths[each.key])

#   layers = local.layer_versions[each.key]

#   publish = true

#   lifecycle {
#     ignore_changes        = [layers]
#     create_before_destroy = true
#   }

#   depends_on = [aws_s3_object.lambda_function_zip]
# }

# resource "aws_lambda_alias" "live" {
#   for_each         = var.lambda_functions
#   name             = "live"
#   description      = "The live alias."
#   function_name    = aws_lambda_function.my_lambda[each.key].function_name
#   function_version = aws_lambda_function.my_lambda[each.key].version

#   depends_on = [aws_lambda_function.my_lambda]
# }

# # Reference existing Lambda functions
# data "aws_lambda_function" "existing_lambda" {
#   for_each      = var.lambda_functions
#   function_name = each.key
#   depends_on    = [aws_lambda_function.my_lambda]
# }

# # Ensure function configuration updates with latest layer versions

# resource "null_resource" "update_layers" {
#   for_each = data.aws_lambda_function.existing_lambda

#   provisioner "local-exec" {
#     command = <<EOT
#       aws lambda update-function-configuration --function-name ${each.key} --layers ${join(" ", local.layer_versions[each.key])}
#     EOT
#   }

#   triggers = {
#     function_name  = each.key
#     layer_versions = join(",", local.layer_versions[each.key])
#   }

#   depends_on = [aws_lambda_layer_version.my_layer]
# }

# # Provisioned Concurrency Configuration
# resource "aws_lambda_provisioned_concurrency_config" "function_concurrency" {
#   for_each = var.lambda_functions

#   function_name          = aws_lambda_function.my_lambda[each.key].function_name
#   qualifier              = aws_lambda_alias.live[each.key].name
#   provisioned_concurrent_executions = 2

#   depends_on = [
#     aws_lambda_alias.live
#   ]
# }

# # Application Auto Scaling for Lambda Provisioned Concurrency
# resource "aws_appautoscaling_target" "lambda_scaling_target" {
#   for_each               = var.lambda_functions

#   max_capacity           = 5
#   min_capacity           = 2
#   resource_id            = "function:${aws_lambda_function.my_lambda[each.key].function_name}:${aws_lambda_alias.live[each.key].name}"
#   scalable_dimension     = "lambda:function:ProvisionedConcurrency"
#   service_namespace      = "lambda"

#   depends_on = [
#     aws_lambda_provisioned_concurrency_config.function_concurrency
#   ]
# }

# resource "aws_appautoscaling_policy" "lambda_scaling_policy" {
#   for_each               = var.lambda_functions
#   name               = "lambda-scaling-policy"
#   policy_type        = "TargetTrackingScaling"
#   resource_id        = aws_appautoscaling_target.lambda_scaling_target[each.key].resource_id
#   scalable_dimension = aws_appautoscaling_target.lambda_scaling_target[each.key].scalable_dimension
#   service_namespace  = aws_appautoscaling_target.lambda_scaling_target[each.key].service_namespace

#   target_tracking_scaling_policy_configuration {
#     target_value = 0.75

#     predefined_metric_specification {
#       predefined_metric_type = "LambdaProvisionedConcurrencyUtilization"
#     }

#     scale_in_cooldown  = 60
#     scale_out_cooldown = 60
#   }

#   depends_on = [
#     aws_appautoscaling_target.lambda_scaling_target
#   ]
# }