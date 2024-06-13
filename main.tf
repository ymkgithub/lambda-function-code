locals {
  layer_zip_paths    = { for name, _ in var.lambda_layers : name => "${path.module}/lambda/layers/${name}.zip" }
  function_zip_paths = { for name, _ in var.lambda_functions : name => "${path.module}/lambda/${name}.zip" }
}
 
resource "aws_s3_bucket" "lambda_bucket" {
  bucket = "my-multi-lambda-functions-bucket"
}
 
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
  layers = [for name, _ in aws_lambda_layer_version.my_layer : aws_lambda_layer_version.my_layer[name].arn]
  publish          = true
 
  lifecycle {
    ignore_changes = [layers]
  }
 
  depends_on = [aws_s3_object.lambda_function_zip]
}
 
resource "aws_lambda_alias" "live" {
  for_each         = var.lambda_functions
  name             = "live"
  description      = "The live alias."
  function_name    = aws_lambda_function.my_lambda[each.key].function_name
  function_version = aws_lambda_function.my_lambda[each.key].version
}
 
# Reference existing Lambda functions
data "aws_lambda_function" "existing_lambda" {
  for_each = var.lambda_functions
  function_name = each.key
  depends_on = [ aws_lambda_function.my_lambda ]
}
 
# Update Lambda Layers for Each Function
resource "null_resource" "update_layers" {
  for_each = data.aws_lambda_function.existing_lambda
 
  provisioner "local-exec" {
    command = <<EOT
      aws lambda update-function-configuration --function-name ${each.key} --layers ${join(" ", [for layer_name in keys(var.lambda_layers) : aws_lambda_layer_version.my_layer[layer_name].arn])}
    EOT
  }
 
  triggers = {
    function_name  = each.key
    layer_versions = join(",", [for layer_name in keys(var.lambda_layers) : aws_lambda_layer_version.my_layer[layer_name].version])
  }
 
  depends_on = [aws_lambda_layer_version.my_layer]
}