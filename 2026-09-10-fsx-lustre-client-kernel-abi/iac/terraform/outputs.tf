output "instance_id" {
  description = "Instance to pass to setup/runner.sh as INSTANCE_ID"
  value       = aws_instance.client.id
}

output "availability_zone" {
  description = "Availability Zone of the client, which must match the file system"
  value       = aws_instance.client.availability_zone
}

output "ami_id" {
  description = "AMI the client booted from"
  value       = aws_instance.client.ami
}
