# One Ubuntu client instance for the kernel ABI verification.
#
# The instance is reached only through AWS Systems Manager, so it needs no inbound rule,
# no key pair and no public address. It joins the security groups of the file system
# under test, which is what the self-referencing Lustre rules expect of a client.

data "aws_ssm_parameter" "ubuntu_ami" {
  name = var.ami_ssm_parameter
}

data "aws_subnet" "target" {
  id = var.subnet_id
}

resource "aws_iam_role" "instance" {
  name_prefix = "${var.name_prefix}-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = var.tags
}

# Systems Manager access is the only permission the verification needs.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name_prefix = "${var.name_prefix}-"
  role        = aws_iam_role.instance.name
  tags        = var.tags
}

resource "aws_security_group" "client" {
  name_prefix = "${var.name_prefix}-"
  description = "Egress for package downloads and Systems Manager"
  vpc_id      = data.aws_subnet.target.vpc_id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-client" })
}

resource "aws_instance" "client" {
  # An AMI id is not a secret, so unwrap the value the SSM data source marks as sensitive.
  ami                    = var.ami_id != "" ? var.ami_id : nonsensitive(data.aws_ssm_parameter.ubuntu_ami.value)
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  vpc_security_group_ids = concat([aws_security_group.client.id], var.file_system_security_group_ids)

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-client" })
}
