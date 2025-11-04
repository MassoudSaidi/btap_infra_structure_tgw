output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

# This output block will collect all the necessary names for the Python script.
output "nuke_script_config" {
  value = {
    AWS_REGION               = "ca-central-1" # As defined in your provider block
    CLUSTER_NAME             = aws_ecs_cluster.main.name
    SERVICE_NAME             = aws_ecs_service.app_service.name
    ASG_NAME_PREFIX          = aws_autoscaling_group.ecs_asg.name_prefix
    LAUNCH_TEMPLATE_PREFIX   = aws_launch_template.ecs_launch_template.name_prefix
    ALB_NAME                 = aws_lb.main.name
    TARGET_GROUP_NAME        = aws_lb_target_group.app.name
    ALB_SG_NAME              = aws_security_group.alb_sg.name
    ECS_SG_NAME              = aws_security_group.ecs_sg.name
    VPC_ID                   = data.aws_vpc.main.id # UPDATED: We now use the VPC ID directly.
    # --- NEW OUTPUTS FOR API GATEWAY ---
    API_ID                   = aws_apigatewayv2_api.test_api.id
    VPC_LINK_ID              = aws_apigatewayv2_vpc_link.test_link.id
  }
  # This sensitive flag prevents the output from being shown in the main 'apply' log,
  # but it will still be available for the 'output' command.
  sensitive = true
}