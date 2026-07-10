output "instance_id" {
  value = aws_instance.build_host.id
}

output "public_ip" {
  value = aws_instance.build_host.public_ip
}

output "ssm_session_command" {
  description = "Preferred way to connect - no SSH key, no open inbound port, works even with associate_public_ip = false as long as SSM endpoints are reachable."
  value       = "aws ssm start-session --target ${aws_instance.build_host.id} --region ${var.aws_region}"
}

output "ssh_command" {
  description = "Only works if ssh_allowed_cidrs and key_name were both set."
  value       = "ssh ec2-user@${aws_instance.build_host.public_ip}"
}
