# 1. Create an EC2 instance and install the application on it using a bootstrap script.
resource "aws_instance" "main" {
  ami = local.ami_id
  instance_type = "t3.micro"
  subnet_id = local.private_subnet_id
  vpc_security_group_ids = [local.sg_id]
  tags = merge(
    local.common_tags,
    {
      Name = "${var.project}-${var.environment}-${var.component}"
    }
  )
}

# 2. Create an AMI from the EC2 instance created above.
resource "terraform_data" "main" {
  triggers_replace = [
    aws_instance.main.id
  ]

  connection {
    type     = "ssh"
    user     = "ec2-user"
    password = "DevOps321"
    host     = aws_instance.main.private_ip
  }

  provisioner "file" {
    source = "./bootstrap.sh"
    destination = "/tmp/bootstrap.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/bootstrap.sh",
      "sudo sh /tmp/bootstrap.sh ${var.component} ${var.environment} ${var.app_version}"
    ]
  }
}

# 3. Stop the EC2 instance before creating an AMI from it.
resource "aws_ec2_instance_state" "main" {
  instance_id = aws_instance.main.id
  state       = "stopped"
  depends_on = [ terraform_data.main ]
}

# 4. Create an AMI from the stopped EC2 instance. 
resource "aws_ami_from_instance" "main" {
  name = "${var.project}-${var.environment}-${var.component}-${var.app_version}-${aws_instance.main.id}"
  source_instance_id = aws_instance.main.id
  depends_on = [ aws_ec2_instance_state.main ]
  tags = merge(
    {
        Name = "${var.project}-${var.environment}-${var.component}"
    },
    local.common_tags
  )
}

# 5. Create a launch template using the AMI created above. This launch template will be used by the autoscaling group to create instances.
resource "aws_launch_template" "main" {
  name        = "${var.project}-${var.environment}-${var.component}"
  image_id = aws_ami_from_instance.main.id

  vpc_security_group_ids = [local.sg_id]

  # each time we apply terraform this version will be updated as default
  update_default_version = true

  # once autoscaling sees less traffic, it will terminate the instance
  instance_initiated_shutdown_behavior = "terminate"
  instance_type = "t3.micro"

# tags for instances created by launch template through autoscaling
  tag_specifications {
    resource_type = "instance"

  tags = merge(
        {
            Name = "${var.project}-${var.environment}-${var.component}"
        },
        local.common_tags
    )
  }

  # tags for instances created by launch template through autoscaling
  tag_specifications {
    resource_type = "volume"

  tags = merge(
        {
            Name = "${var.project}-${var.environment}-${var.component}"
        },
        local.common_tags
    )
  }
}

# 6. Create a target group for the application. This target group will be used by the load balancer to route traffic to the instances created by the autoscaling group.
resource "aws_lb_target_group" "main" {
  name        = "${var.project}-${var.environment}-${var.component}"
  port        = local.port_number
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  deregistration_delay = 60

  health_check {
    enabled = true
    healthy_threshold = 2
    unhealthy_threshold = 3
    interval = 10
    timeout = 2
    protocol = "HTTP"
    path = local.health_check_path
    port = local.port_number
    matcher = "200-299"
  }
}

# 7. Create an autoscaling group that uses the launch template created above to create instances.
resource "aws_autoscaling_group" "main" {
  name                      = "${var.project}-${var.environment}-${var.component}"
  max_size                  = 5
  min_size                  = 1
  desired_capacity          = 2
  health_check_grace_period = 120
  health_check_type         = "ELB"
  force_delete              = false

  # launch template block to refer the launch template created above
  launch_template {
    id      = aws_launch_template.main.id
    version = "$Latest"
  }
  vpc_zone_identifier       = [local.private_subnet_id]
  target_group_arns = [aws_lb_target_group.main.arn]

  # with in 15min autoscaling should be successful
  timeouts {
    delete = "15m"
  }

  # when we update the launch template, we want to replace the instances with new ones
  instance_refresh {
      strategy = "Rolling"
      preferences {
        min_healthy_percentage = 50
      }
      triggers = ["launch_template"]
    }

  dynamic "tag" {
    for_each = merge(
        {
            Name = "${var.project}-${var.environment}-${var.component}"
        },
        local.common_tags
    )

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

# 8. Create an Auto Scaling policy to scale the application based on average CPU utilization.
# Auto Scaling policy to scale based on average CPU utilization
resource "aws_autoscaling_policy" "main" {
  autoscaling_group_name = aws_autoscaling_group.main.name
  name                   = "${var.project}-${var.environment}-${var.component}"
  policy_type            = "TargetTrackingScaling"
  estimated_instance_warmup = 120
  
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 70.0
  }
}

# 9. Create a listener rule for the application. This listener rule will be used by the load balancer to route traffic to the target group created above.
# This depends on target group
# if frontend frontend-dev.rajudevops.online
resource "aws_lb_listener_rule" "main" {
  listener_arn = local.alb_listener_arn
  priority     = var.rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }

  condition {
    host_header {
      values = [local.host_header]
    }
  }
}

# 10. Delete the instance
resource "terraform_data" "main-delete" {
  triggers_replace = [aws_instance.main.id]

  depends_on = [ aws_autoscaling_policy.main ]

  provisioner "local-exec" {
  command = "aws ec2 terminate-instances --instance-ids ${aws_instance.main.id}"
  }

}