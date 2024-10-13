provider "aws" {
  region = "eu-north-1"  
}


resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "main-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "main-igw"
  }
}

resource "aws_subnet" "public" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet-${count.index + 1}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "public-route-table"
  }
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_key_pair" "main" {
  key_name   = "my-ec2-key_main"
  public_key = file("${path.module}/my-ec2-key_main.pub")
}

resource "aws_security_group" "app" {
  name        = "app-sg"
  description = "Security group for the application instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

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


resource "aws_instance" "app" {
  ami           = "ami-08eb150f611ca277f"  
  instance_type = "t3.micro"
  key_name      = aws_key_pair.main.key_name
  subnet_id     = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.app.id]
  user_data = <<-EOF
    #!/bin/bash
    sudo apt-get update
    sudo apt-get upgrade -y
    sudo apt-get install -y nginx postgresql-client git golang-go

    cd /home/ubuntu
    git clone https://github.com/Omal1k/golang-demo.git
    cd golang-demo

    GOOS=linux GOARCH=amd64 go build -o golang-demo
    chmod +x golang-demo

    DB_ENDPOINT="${aws_db_instance.db.address}" DB_PORT=5432 DB_USER="root" DB_PASS="12345678" DB_NAME="mydatabase" nohup ./golang-demo &

    INSTANCE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
    sudo bash -c 'cat > /etc/nginx/sites-available/default <<EOF
    server {
        listen 80;
        server_name $INSTANCE_IP;
        location / {
            proxy_pass http://localhost:8080;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
    EOF'

    sudo systemctl restart nginx
  EOF


  tags = {
    Name = "app-instance"
  }
}


resource "aws_db_instance" "db" {
  identifier           = "app-db"
  engine               = "postgres"
  engine_version       = "16.3"
  instance_class       = "db.t4g.micro"
  allocated_storage    = 20
  storage_type         = "gp2"
  username             = "root"
  password             = "12345678"
  db_subnet_group_name = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name = aws_db_parameter_group.db.name
  skip_final_snapshot  = true
}

resource "aws_db_subnet_group" "db" {
  name       = "app-db-subnet-group"
  subnet_ids = aws_subnet.public[*].id
}

resource "aws_security_group" "db" {
  name        = "db-sg"
  description = "Security group for the database instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id] 
  }
}

resource "aws_db_parameter_group" "db" {
  family = "postgres16"
  name   = "app-db-params"

  parameter {
    name  = "log_connections"
    value = "1"
  }
}

output "app_public_ip" {
  value = aws_instance.app.public_ip
}

output "db_endpoint" {
  value = aws_db_instance.db.endpoint
}

data "aws_availability_zones" "available" {
  state = "available"
}
