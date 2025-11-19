
data "aws_vpc" "main" {
  id = var.surrogate_workload_vpc_id        # "vpc-0809102c90503ef2d" 
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
}

# ALB SG (open for test)
resource "aws_security_group" "alb_sg" {
  name        = "test-alb-sg"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 SG (allow from ALB only)
resource "aws_security_group" "ec2_sg" {
  name        = "test-ec2-sg"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]  # Fix: Explicitly allow from ALB SG
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# IAM Role for EC2 (SSM access)
resource "aws_iam_role" "ec2_role" {
  name = "test-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}


resource "aws_s3_bucket" "test_bucket" {
  bucket = "bsup-20251115" # CHANGE THIS to a unique name (only lowercase alphanumeric characters and hyphens allowed)
  force_destroy = true  # Allows Terraform to delete non-empty buckets
}

resource "aws_iam_policy" "s3_access_policy" {
  name        = "test-s3-access-policy"
  description = "A policy that allows access to a specific S3 bucket."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.test_bucket.arn
      },
      {
        Effect   = "Allow"
        Action   = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.test_bucket.arn}/*"
      }
    ]
  })
}


resource "aws_iam_role_policy_attachment" "s3_access" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_access_policy.arn
}


resource "aws_iam_instance_profile" "ec2_profile" {
  name = "test-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# Dummy EC2 with NGINX
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_instance" "test_ec2" {
  ami                  = data.aws_ami.amazon_linux.id
  instance_type        = "t3.micro"
  subnet_id            = data.aws_subnets.private.ids[0]
  security_groups      = [aws_security_group.ec2_sg.id]
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    amazon-linux-extras install nginx1 -y
    echo "Healthy" > /usr/share/nginx/html/health
    systemctl start nginx
    systemctl enable nginx

    # Create a test file and upload to S3
    echo "This is a test file from EC2." > /tmp/test.txt
    aws s3 cp /tmp/test.txt s3://${aws_s3_bucket.test_bucket.bucket}/test.txt    # add $ to {aws_s3_bucket.test_bucket.bucket}/test.txt 
  EOF

  tags = { Name = "test-ec2" }
}

# Internal ALB
resource "aws_lb" "test_alb" {
  name               = "test-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.private.ids
}

# Target Group with /health check
resource "aws_lb_target_group" "test_tg" {
  name     = "test-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.main.id

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 10
  }
}

# Listener
resource "aws_lb_listener" "test_listener" {
  load_balancer_arn = aws_lb.test_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.test_tg.arn
  }
}

# Attach EC2 to TG
resource "aws_lb_target_group_attachment" "test" {
  target_group_arn = aws_lb_target_group.test_tg.arn
  target_id        = aws_instance.test_ec2.id
  port             = 80
}

# VPC Link
resource "aws_apigatewayv2_vpc_link" "test_link" {
  name               = "test-vpc-link"
  subnet_ids         = data.aws_subnets.private.ids
  security_group_ids = [aws_security_group.alb_sg.id]
}

# API Gateway
resource "aws_apigatewayv2_api" "test_api" {
  name          = "test-ml-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["*"]
    allow_headers = ["*"]
  }
}

# Integration
resource "aws_apigatewayv2_integration" "alb" {
  api_id             = aws_apigatewayv2_api.test_api.id
  integration_type   = "HTTP_PROXY"
  integration_uri    = aws_lb_listener.test_listener.arn
  integration_method = "ANY"
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.test_link.id
}

# Route
resource "aws_apigatewayv2_route" "proxy" {
  api_id    = aws_apigatewayv2_api.test_api.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.alb.id}"
}

# Stage
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.test_api.id
  name        = "$default"
  auto_deploy = true
}

output "test_api_url" {
  value = aws_apigatewayv2_stage.default.invoke_url
}