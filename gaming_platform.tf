provider "aws" {
  region = "us-west-2"
}

# VPC
resource "aws_vpc" "game_vpc" {
  cidr_block = "10.0.0.0/16"
}

# Subnets
resource "aws_subnet" "public_subnet_1" {
  vpc_id     = aws_vpc.game_vpc.id
  cidr_block = "10.0.1.0/24"
  availability_zone = "us-west-2a"
}

resource "aws_subnet" "public_subnet_2" {
  vpc_id     = aws_vpc.game_vpc.id
  cidr_block = "10.0.3.0/24"
  availability_zone = "us-west-2b"
}

resource "aws_subnet" "private_subnet_1" {
  vpc_id     = aws_vpc.game_vpc.id
  cidr_block = "10.0.2.0/24"
  availability_zone = "us-west-2a"
}

resource "aws_subnet" "private_subnet_2" {
  vpc_id     = aws_vpc.game_vpc.id
  cidr_block = "10.0.4.0/24"
  availability_zone = "us-west-2b"
}

# Internet Gateway
resource "aws_internet_gateway" "game_gw" {
  vpc_id = aws_vpc.game_vpc.id
}

# Route Table
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.game_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.game_gw.id
  }
}

# Associate Route Tables with Subnets
resource "aws_route_table_association" "public_rt_association_1" {
  subnet_id      = aws_subnet.public_subnet_1.id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_route_table_association" "public_rt_association_2" {
  subnet_id      = aws_subnet.public_subnet_2.id
  route_table_id = aws_route_table.public_route_table.id
}

# Security Groups
resource "aws_security_group" "game_sg" {
  vpc_id = aws_vpc.game_vpc.id

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

# Load Balancer
resource "aws_lb" "game_elb" {
  name               = "game-elb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.game_sg.id]
  subnets            = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]
}

resource "aws_lb_listener" "game_listener" {
  load_balancer_arn = aws_lb.game_elb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.game_tg.arn
  }
}

resource "aws_lb_target_group" "game_tg" {
  name     = "game-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.game_vpc.id
}

# Auto Scaling for EC2 Instances
resource "aws_launch_configuration" "game_ec2_launch_config" {
  name          = "game-ec2-launch-config"
  image_id      = "ami-12345678"  # Replace with the correct AMI ID
  instance_type = "t2.micro"
  security_groups = [aws_security_group.game_sg.id]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "game_ec2_asg" {
  vpc_zone_identifier = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]
  launch_configuration = aws_launch_configuration.game_ec2_launch_config.id
  min_size             = 2
  max_size             = 4
  desired_capacity     = 2

  tag {
    key                 = "Name"
    value               = "game-ec2-instance"
    propagate_at_launch = true
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "game_cluster" {
  name = "game-cluster"
}

# ECS Task Definition
resource "aws_ecs_task_definition" "game_task" {
  family                   = "game-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  container_definitions = <<DEFINITION
  [
    {
      "name": "game-container",
      "image": "nginx",
      "portMappings": [
        {
          "containerPort": 80,
          "hostPort": 80
        }
      ]
    }
  ]
  DEFINITION
}

# ECS Fargate Service with Auto Scaling
resource "aws_ecs_service" "game_fargate_service" {
  name            = "game-service"
  cluster         = aws_ecs_cluster.game_cluster.id
  task_definition = aws_ecs_task_definition.game_task.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = [aws_subnet.private_subnet_1.id, aws_subnet.private_subnet_2.id]
    security_groups = [aws_security_group.game_sg.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.game_tg.arn
    container_name   = "game-container"
    container_port   = 80
  }
}

# Auto Scaling for ECS Fargate Tasks
resource "aws_appautoscaling_target" "ecs_fargate_target" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.game_cluster.name}/${aws_ecs_service.game_fargate_service.name}"
  min_capacity       = 2
  max_capacity       = 4
}

# DynamoDB Table
resource "aws_dynamodb_table" "game_dynamo_table" {
  name           = "game-data"
  hash_key       = "game_id"
  billing_mode   = "PAY_PER_REQUEST"

  attribute {
    name = "game_id"
    type = "S"
  }

  attribute {
    name = "player_id"
    type = "S"
  }
}

# ElastiCache for Redis
resource "aws_elasticache_subnet_group" "game_cache_subnet_group" {
  name       = "game-cache-subnet-group"
  subnet_ids = [aws_subnet.private_subnet_1.id, aws_subnet.private_subnet_2.id]
}

resource "aws_elasticache_cluster" "game_cache" {
  cluster_id           = "game-cache"
  engine               = "redis"
  node_type            = "cache.t2.micro"
  num_cache_nodes      = 1
  subnet_group_name    = aws_elasticache_subnet_group.game_cache_subnet_group.name
  security_group_ids   = [aws_security_group.game_sg.id]
}

# S3 Bucket for assets
resource "aws_s3_bucket" "game_assets" {
  bucket = "game-assets-bucket"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    id      = "archive-assets"
    enabled = true

    transition {
      days          = 30
      storage_class = "GLACIER"
    }
  }
}

# CloudWatch Logs
resource "aws_cloudwatch_log_group" "game_logs" {
  name              = "/ecs/game-logs"
  retention_in_days = 30
}

# CloudTrail
resource "aws_cloudtrail" "game_trail" {
  name                       = "game-trail"
  s3_bucket_name             = aws_s3_bucket.game_assets.bucket
  include_global_service_events = true
  is_multi_region_trail       = true
  enable_log_file_validation  = true
  cloud_watch_logs_group_arn  = aws_cloudwatch_log_group.game_logs.arn
}

# WAF Web ACL
resource "aws_waf_web_acl" "game_waf" {
  name        = "game-waf"
  metric_name = "GameWAF"
  default_action {
    type = "ALLOW"
  }
}

resource "aws_waf_web_acl_association" "game_waf_association" {
  resource_arn = aws_lb.game_elb.arn
  web_acl_id   = aws_waf_web_acl.game_waf.id
}

# IAM Role for ECS Tasks
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  ]
}

# Terraform Backend
terraform {
  backend "s3" {
    bucket = "terraform-state-storage"
    key    = "game-infrastructure/terraform.tfstate"
    region = "us-west-2"
  }
}
