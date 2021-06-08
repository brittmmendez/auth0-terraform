terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.27"
    }
    auth0 = {
      source = "alexkappa/auth0"
    }
  }

  required_version = ">= 0.13.4"
}

provider "aws" {
  profile = "default"
  region  = "us-east-1"
}

# Configure the Auth0 Provider
# For Terraform to be able to create Clients and APIs in Auth0, you'll need to manually create an Auth0 
# Machine-to-Machine Application that allows Terraform to communicate with Auth0.
# https://auth0.com/blog/use-terraform-to-manage-your-auth0-configuration/#Create-an-Auth0-client-using-HashiCorp-Terraform
provider "auth0" {}

resource "auth0_client" "spa-appsync-client" {
  name        = "SPA Auth0 Client"
  description = "Terraform generated - spa app for vue frontend to connect to and make appsync api calls"
  app_type    = "spa"
  callbacks   = ["http://localhost:3000"]
  allowed_origins = [ "http://localhost:3000" ]
  allowed_logout_urls = [ "http://localhost:3000" ]
  web_origins = [ "http://localhost:3000" ]

  jwt_configuration {
    lifetime_in_seconds = 36000
    alg = "RS256"
  }
}

resource "aws_appsync_graphql_api" "auth0-example-api" {
  name                = "auth0-example"
  authentication_type = "OPENID_CONNECT"


  openid_connect_config {
    issuer = "https://pg-poc.us.auth0.com"
    # comment out client_id if you want to open appsync api to all 
    # applications in issuer andnot just a single one
    client_id = auth0_client.spa-appsync-client.client_id
  }

  schema = file("${path.module}/templates/auth0_appsync_terraform.graphql")
}

resource "aws_appsync_datasource" "auth0-example-datasource" {
  api_id           = aws_appsync_graphql_api.auth0-example-api.id
  name             = "tf_appsync_example"
  service_role_arn = aws_iam_role.auth0-example-role.arn
  type             = "AMAZON_DYNAMODB"

  dynamodb_config {
    table_name = aws_dynamodb_table.auth0-example-table.name
  }
}

resource "aws_appsync_resolver" "createPost_resolver" {
  api_id      = aws_appsync_graphql_api.auth0-example-api.id
  field       = "createPost"
  type        = "Mutation"
  data_source = aws_appsync_datasource.auth0-example-datasource.name

  request_template = <<EOF
{
    "version": "2018-05-29",
    "operation": "PutItem",
    "key" : {
        "id": $util.dynamodb.toDynamoDBJson($util.autoId()),
        "consumerId": $util.dynamodb.toDynamoDBJson($ctx.identity.sub),
    },
    "attributeValues" : $util.dynamodb.toMapValuesJson($ctx.args)
}
EOF

  response_template = <<EOF
$util.toJson($ctx.result)
EOF
}

resource "aws_appsync_resolver" "listPosts_resolver" {
  api_id      = aws_appsync_graphql_api.auth0-example-api.id
  field       = "listPosts"
  type        = "Query"
  data_source = aws_appsync_datasource.auth0-example-datasource.name

  request_template = <<EOF
{
    "version": "2018-05-29",
    "operation": "Scan",
    "filter": #if($context.args.filter) $util.transform.toDynamoDBFilterExpression($ctx.args.filter) #else null #end,
    "limit": $util.defaultIfNull($ctx.args.limit, 20),
    "nextToken": $util.toJson($util.defaultIfNullOrEmpty($ctx.args.nextToken, null)),
}
EOF

  response_template = <<EOF
$util.toJson($context.result.items)
EOF
}

resource "aws_dynamodb_table" "auth0-example-table" {
  name           = "auth0-example"
  read_capacity  = 1
  write_capacity = 1
  hash_key       = "id"

    attribute  {
      name = "id"
      type = "S"
    }
}

resource "aws_iam_role" "auth0-example-role" {
  name = "auth0-example-role"

  assume_role_policy = file("${path.module}/templates/appsyncRole.json")
}

resource "aws_iam_role_policy" "auth0-example-policy" {
  name = "octa-example-policy"
  role = aws_iam_role.auth0-example-role.id

  policy = templatefile("${path.module}/templates/appsyncPolicy.json", {
    aws_dynamodb_table = "${aws_dynamodb_table.auth0-example-table.arn}",
  })
}