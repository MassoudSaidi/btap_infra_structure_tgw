# The AWS Provider is created in hcl file
# provider "aws" {
#   region = "ca-central-1"
# }

# Data sources for existing VPC and private subnets
data "aws_vpc" "main" {
  # id = "vpc-0809102c90503ef2d"  # From client's info; confirm if needed
  id = var.surrogate_workload_vpc_id
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  # Optional: Add tags filter if subnets have specific tags, e.g., tags = { Type = "private" }
}

data "aws_subnet" "single_private_subnet" {
  id = data.aws_subnets.private.ids[0]
}

# 2. Security Groups

# 2.1 Security Group for the Application Load Balancer (ALB)
# Allows traffic from within the VPC (for API Gateway VPC Link)
resource "aws_security_group" "alb_sg" {
  name        = local.names.alb_sg_name
  description = "Allow HTTP inbound traffic for ALB"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = [data.aws_vpc.main.cidr_block]  # Restrict to VPC CIDR for internal traffic
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 2.2 Security Group for the ECS instances
# Allows traffic ONLY from the Load Balancer's Security Group.
resource "aws_security_group" "ecs_sg" {
  name        = local.names.ecs_sg_name
  description = "Allow traffic from the ALB to the ECS instances"
  vpc_id      = data.aws_vpc.main.id

  # Ingress from the ALB Security Group to app port
  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 2.3 NEW: Security Group for ElastiCache (Redis)
# Allows traffic ONLY from the ECS Security Group on the Redis port.
resource "aws_security_group" "redis_sg" {
  name        = "${local.base_name}-redis-sg"
  description = "Allow inbound traffic from ECS to Redis"
  vpc_id      = data.aws_vpc.main.id

  # Ingress from the ECS Security Group to Redis port
  ingress {
    from_port       = 6379 # Default Redis port
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.base_name}-redis-sg"
  }
}

# --- ELASTICACHE RESOURCES ---

# A. ElastiCache Subnet Group
# This tells ElastiCache which private subnets it can live in.
resource "aws_elasticache_subnet_group" "redis_subnet_group" {
  name       = "${local.base_name}-redis-subnet-group"
  subnet_ids = data.aws_subnets.private.ids
}

# B. ElastiCache Parameter Group
resource "aws_elasticache_parameter_group" "redis7" {
  name   = "${local.base_name}-redis7-param-group"
  family = "redis7"
}

# C. The ElastiCache Redis Cluster Itself
resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "${local.base_name}-redis-cluster"
  engine               = "redis"
  engine_version       = "7.0"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  parameter_group_name = aws_elasticache_parameter_group.redis7.name
  subnet_group_name    = aws_elasticache_subnet_group.redis_subnet_group.name
  security_group_ids   = [aws_security_group.redis_sg.id]
}

# 3. ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = local.names.cluster_name
}

# 4. ECS Instance IAM Role
resource "aws_iam_role" "ecs_instance_role" {
  name = local.names.iam_role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_instance_role_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# This policy allows SSM to manage the instance
resource "aws_iam_role_policy_attachment" "ecs_ssm_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ecs_instance_profile" {
  name = local.names.iam_profile_name
  role = aws_iam_role.ecs_instance_role.name
}

# 5. ECS Optimized AMI (Using the stable Amazon Linux 2 SSM Parameter)
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended/image_id"
}

# 6. Launch Template and Auto Scaling Group
resource "aws_launch_template" "ecs_launch_template" {
  name_prefix   = local.names.launch_template_prefix
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance_profile.name
  }
  network_interfaces {
    associate_public_ip_address = false  # Private only
    security_groups             = [aws_security_group.ecs_sg.id]
  }
  user_data = base64encode(<<-EOF
              #!/bin/bash
              echo ECS_CLUSTER=${aws_ecs_cluster.main.name} >> /etc/ecs/ecs.config
              EOF
  )
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "ecs_asg" {
  name_prefix         = local.names.asg_name_prefix
  desired_capacity    = 1
  max_size            = 2
  min_size            = 1
  vpc_zone_identifier = data.aws_subnets.private.ids  # Private subnets
  # vpc_zone_identifier = [data.aws_subnet.single_private_subnet.id]  # limit to one AZ

  protect_from_scale_in = true       # prevents ECS from terminating the last healthy one
  default_cooldown      = 300  

  launch_template {
    id      = aws_launch_template.ecs_launch_template.id
    version = "$Latest"
  }
  health_check_type         = "EC2"
  health_check_grace_period = 300

  lifecycle {
    create_before_destroy = true
  }
}

# 7. ECS Capacity Provider
resource "aws_ecs_capacity_provider" "ecs_capacity_provider" {
  name = local.names.capacity_provider_name
  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.ecs_asg.arn
  }
}

resource "aws_ecs_cluster_capacity_providers" "cluster_association" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.ecs_capacity_provider.name]
  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = aws_ecs_capacity_provider.ecs_capacity_provider.name
  }
}

# 8. Load Balancer, Target Group, and Listener
resource "aws_lb" "main" {
  name               = local.names.alb_name
  internal           = true  # Internal ALB
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.private.ids  # Private subnets
  idle_timeout       = 300
}

resource "aws_lb_target_group" "app" {
  name        = local.names.target_group_name
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.main.id
  target_type = "instance"

  lifecycle {
    create_before_destroy = true
  }

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# # 9. CLOUDWATCH LOG GROUP   # NRCan prevents destroy
# resource "aws_cloudwatch_log_group" "app_logs" {
#   name              = "/ecs/${local.names.service_name}"
#   # retention_in_days = 30

#   tags = {
#     Name = "${local.names.service_name}-logs"
#   }
#   lifecycle {
#     prevent_destroy = true
#   }
# }

# 10. ECS Task Definition
resource "aws_ecs_task_definition" "app" {
  family                   = local.names.task_family
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory)

  container_definitions = jsonencode([
    {
      name      = "app"
      # image     = "docker.io/massoudsaidi/massoud_btap_1:4.0.5"
      # image     = "mendhak/http-helloworld:latest"
      image       = "mendhak/http-https-echo:31"
      essential = true
      portMappings = [{
        containerPort = 8000
        hostPort      = 8000
        protocol      = "tcp"
      }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/${local.names.service_name}"   # hard-coded name (AWS didn't auto-create) originally was: aws_cloudwatch_log_group.app_logs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
      environment = [
        { name = "APP_BASE_URL", value = aws_apigatewayv2_stage.default.invoke_url },
        { name = "COGNITO_APP_CLIENT_ID", value = "-" },
        { name = "COGNITO_APP_PUBLIC_CLIENT_ID", value = "-" },
        { name = "COGNITO_DOMAIN", value = "-" },
        { name = "COGNITO_REGION", value = var.aws_region },
        { name = "COGNITO_USER_POOL_ID", value = "-" },
        { name = "COGNITO_APP_CLIENT_SECRET", value = "-" },

        { name = "REDIS_ENDPOINT", value = aws_elasticache_cluster.redis.cache_nodes[0].address },
        { name = "REDIS_PORT", value = tostring(aws_elasticache_cluster.redis.cache_nodes[0].port) },        
        { name = "VERSION_STRING", value = "v8.1.2" },
        { name = "BUCKET_NAME", value = aws_s3_bucket.uploads.bucket },
        { name = "HTTP_PORT", value = "8000" }
      ]
    }
  ])

  # lifecycle {
  #   ignore_changes = [container_definitions]
  # }
}

# 11. ECS Service
resource "aws_ecs_service" "app_service" {
  name            = local.names.service_name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1

  # Add deployment configuration
  deployment_minimum_healthy_percent = 0  # Allow old task to stop before new one starts
  deployment_maximum_percent         = 100 # If 200, (provided enough memory) Allow both old and new tasks temporarily


  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ecs_capacity_provider.name
    base              = 1
    weight            = 100
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 8000
  }

  depends_on = [
    aws_ecs_task_definition.app,
    aws_lb_listener.http,
    aws_ecs_cluster_capacity_providers.cluster_association
  ]

  # lifecycle {
  #   ignore_changes = [task_definition]
  # }
}

# 12. CLOUDWATCH ALARMS

# resource "aws_cloudwatch_metric_alarm" "ecs_high_cpu" {
#   alarm_name          = "${local.names.service_name}-high-cpu"
#   alarm_description   = "This alarm triggers if the ECS service CPU utilization is above 80% for 5 minutes."
#   comparison_operator = "GreaterThanOrEqualToThreshold"
#   evaluation_periods  = "1"
#   metric_name         = "CPUUtilization"
#   namespace           = "AWS/ECS"
#   period              = "300"
#   statistic           = "Average"
#   threshold           = "80"

#   dimensions = {
#     ClusterName = aws_ecs_cluster.main.name
#     ServiceName = aws_ecs_service.app_service.name
#   }
# }

# resource "aws_cloudwatch_metric_alarm" "alb_5xx_errors" {
#   alarm_name          = "${local.names.alb_name}-5xx-errors"
#   alarm_description   = "This alarm triggers if there are more than 10 5xx errors in a 5 minute period."
#   comparison_operator = "GreaterThanOrEqualToThreshold"
#   evaluation_periods  = "1"
#   metric_name         = "HTTPCode_Target_5XX_Count"
#   namespace           = "AWS/ApplicationELB"
#   period              = "300"
#   statistic           = "Sum"
#   threshold           = "10"

#   dimensions = {
#     LoadBalancer = aws_lb.main.arn_suffix
#   }
# }

# resource "aws_cloudwatch_metric_alarm" "ecs_high_memory" {
#   alarm_name          = "${local.names.service_name}-high-memory"
#   alarm_description   = "This alarm triggers if the ECS service memory utilization is above 85% for 5 minutes."
#   comparison_operator = "GreaterThanOrEqualToThreshold"
#   evaluation_periods  = "1"
#   metric_name         = "MemoryUtilization"
#   namespace           = "AWS/ECS"
#   period              = "300"
#   statistic           = "Average"
#   threshold           = "85"

#   dimensions = {
#     ClusterName = aws_ecs_cluster.main.name
#     ServiceName = aws_ecs_service.app_service.name
#   }
# }

# # 15. CLOUDWATCH DASHBOARD
# resource "aws_cloudwatch_dashboard" "main_dashboard" {
#   dashboard_name = "${local.base_name}-dashboard"

#   dashboard_body = jsonencode({
#     widgets = [
#       {
#         type   = "metric",
#         x      = 0,
#         y      = 0,
#         width  = 12,
#         height = 6,
#         properties = {
#           metrics = [
#             ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.app_service.name],
#             [".", "MemoryUtilization", ".", ".", ".", "."]
#           ],
#           period = 300,
#           stat   = "Average",
#           region = var.aws_region,
#           title  = "ECS Service CPU & Memory Utilization"
#         }
#       },
#       {
#         type   = "metric",
#         x      = 12,
#         y      = 0,
#         width  = 12,
#         height = 6,
#         properties = {
#           metrics = [
#             ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main.arn_suffix],
#             [".", "HTTPCode_Target_5XX_Count", ".", ".", { "stat": "Sum" }]
#           ],
#           period = 300,
#           stat   = "Sum",
#           region = var.aws_region,
#           title  = "ALB Requests & 5xx Errors"
#         }
#       },
#       {
#         type   = "log",
#         x      = 0,
#         y      = 7,
#         width  = 24,
#         height = 6,
#         properties = {
#           region = var.aws_region,
#           title  = "ECS Container Logs",
#           query = "SOURCE '${aws_cloudwatch_log_group.app_logs.name}' | fields @timestamp, @message | filter @message not like /GET \\/health/ and @message not like /ELB-HealthChecker/ | sort @timestamp desc | limit 200"
#         }
#       }
#     ]
#   })
# }

# 16. ECS SERVICE AUTO SCALING (Conditionally Created)
resource "aws_appautoscaling_target" "ecs_service_scaling_target" {
  count = var.service_autoscaling_enabled ? 1 : 0

  max_capacity       = 2
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [aws_ecs_service.app_service]
}

resource "aws_appautoscaling_policy" "ecs_cpu_scaling_policy" {
  count = var.service_autoscaling_enabled ? 1 : 0

  name               = "${local.names.service_name}-cpu-scaling-policy"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service_scaling_target[0].resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service_scaling_target[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service_scaling_target[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 75
    scale_in_cooldown  = 300
    scale_out_cooldown = 300
  }
}

resource "aws_appautoscaling_policy" "ecs_memory_scaling_policy" {
  count = var.service_autoscaling_enabled ? 1 : 0

  name               = "${local.names.service_name}-memory-scaling-policy"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service_scaling_target[0].resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service_scaling_target[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service_scaling_target[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = 80
    scale_in_cooldown  = 300
    scale_out_cooldown = 300
  }
}

# IAM policy for CloudWatch Logs
resource "aws_iam_policy" "ecs_cloudwatch_logs_policy" {
  name        = "${local.base_name}-ecs-logs-policy"
  description = "Allows ECS instances to write to CloudWatch Logs"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_logs_policy_attachment" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = aws_iam_policy.ecs_cloudwatch_logs_policy.arn
}

# API Gateway Resources

# VPC Link
resource "aws_apigatewayv2_vpc_link" "test_link" {
  name               = "app-vpc-link"
  subnet_ids         = data.aws_subnets.private.ids
  security_group_ids = [aws_security_group.alb_sg.id]
}

# API Gateway
resource "aws_apigatewayv2_api" "test_api" {
  name          = "ml-app-api"
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
  integration_uri    = aws_lb_listener.http.arn
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

# S3 bucket to store uploaded files
resource "aws_s3_bucket" "uploads" {
  bucket = "${local.base_name}-bsup-v2-uploads"
  force_destroy = true  # auto-empty on destroy/replace
}


resource "aws_s3_bucket_lifecycle_configuration" "uploads_lifecycle" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    id     = "cleanup-old-files"
    status = "Enabled"

    expiration {
      days = 1   # days = 7
    }

    filter {
      prefix = "uploads/"
    }
  }
}


resource "aws_s3_bucket_public_access_block" "uploads_public_access" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true  # ← change this to true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "uploads_policy" {
  bucket = aws_s3_bucket.uploads.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid = "AllowAccessThroughVPCe"
        Effect = "Allow"
        Principal = "*"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.uploads.arn,
          "${aws_s3_bucket.uploads.arn}/*"
        ]
        Condition = { #  uncomment this
          StringEquals = {
            "aws:sourceVpce" = "vpce-02d247e1c0e8ebdaf"       # "vpce-066ce0c2c7f5d4a55"  # ← NRCan's S3 VPC endpoint ID
          }
        }
      }
    ]
  })
}

# IAM policy for S3
resource "aws_iam_policy" "ecs_s3_policy" {
  name = "${local.base_name}-ecs-s3-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.uploads.arn,
          "${aws_s3_bucket.uploads.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_s3_policy_attach" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = aws_iam_policy.ecs_s3_policy.arn
}



# Outputs
output "application_url" {
  description = "The URL of the deployed application"
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "ecs_cluster_name" {
  description = "The name of the ECS cluster"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "The name of the ECS service"
  value       = aws_ecs_service.app_service.name
}

output "ecs_task_definition_family" {
  description = "The family of the ECS task definition"
  value       = aws_ecs_task_definition.app.family
}

output "redis_endpoint" {
  description = "The endpoint of the ElastiCache Redis cluster"
  value       = aws_elasticache_cluster.redis.cache_nodes[0].address
}

output "redis_port" {
  description = "The port of the ElastiCache Redis cluster"
  value       = aws_elasticache_cluster.redis.cache_nodes[0].port
}

output "s3_bucket_name" {
  description = "The name of the created S3 uploads bucket"
  value       = aws_s3_bucket.uploads.bucket
}