variable "lambda_functions" {
  type = map(object({
    handler = string
    runtime = string
  }))
  default = {
    function1 = {
      handler = "handler.handler"
      runtime = "nodejs20.x"
    }
    function2 = {
      handler = "handler.handler"
      runtime = "nodejs20.x"
    }
  }
}

variable "lambda_layers" {
  type = map(object({
    runtime = list(string)
  }))
  default = {
    layer1 = {
      runtime = ["nodejs20.x"]
    }
    layer2 = {
      runtime = ["nodejs20.x"]
    }
  }
}
