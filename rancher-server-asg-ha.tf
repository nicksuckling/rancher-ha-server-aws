variable "name" { default = "rancher-ha" }
variable "ami_id"            {}
variable "instance_size"     {}
variable "key_name"          {}
variable "rancher_ssl_cert"  {}
variable "rancher_ssl_key"   {}
variable "database_address"  {}
variable "database_port"     {}
variable "database_name"     {}
variable "database_username" {}
variable "database_password" {}
variable "database_name"     {}
variable "ha_encryption_key" {}
variable "scale_min_size" {}
variable "scale_max_size" {}
variable "scale_desired_size" {}

resource "aws_iam_server_certificate" "rancher_ha"
 {
  name             = "${var.region}-${var.name}"
  certificate_body = "${file("${var.rancher_ssl_cert}")}"
  private_key      = "${file("${var.rancher_ssl_key}")}"

  provisioner "local-exec" {
    command = <<EOF
      echo "Sleep 10 secends so that the cert is propagated by aws iam service"
      echo "See https://github.com/hashicorp/terraform/issues/2499 (terraform ~v0.6.1)"
      sleep 10
EOF
  }
}

# Into ELB from upstream
resource "aws_security_group" "rancher_ha_web_elb" {
  name = "rancher_ha_web_elb"
  description = "Allow ports rancher "
  vpc_id = "${var.vpc_id}"
   egress {
     from_port = 0
     to_port = 0
     protocol = "-1"
     cidr_blocks = ["0.0.0.0/0"]
   }
   ingress {
      from_port = 443
      to_port = 443
      protocol = "tcp"
     cidr_blocks = ["0.0.0.0/0"]
   }
}

#Into servers
resource "aws_security_group" "rancher_ha_allow_elb" {
  name = "rancher_ha_allow_elb"
  description = "Allow Connection from elb"
  vpc_id = "${terraform_remote_state.tlg1.output.vpc_id}"
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

ingress {
      from_port = 81 
      to_port = 81 
      protocol = "tcp"
      security_groups = ["${aws_security_group.rancher_ha_web_elb.id}"]
  }
ingress {
      from_port = 444 
      to_port = 444 
      protocol = "tcp"
      security_groups = ["${aws_security_group.rancher_ha_web_elb.id}"]
  }
}

#Direct into Rancher HA instances
resource "aws_security_group" "rancher_ha_allow_internal" {
  name = "rancher_ha_allow_internal"
  description = "Allow Connection from internal"
  vpc_id = "${var.vpc_id}"
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

}

resource "aws_security_group_rule" "ingress_all_rancher_ha" {
    security_group_id = "${aws_security_group.rancher_ha_allow_internal.id}"
    type = "ingress"
    from_port = 0
    to_port = "0" 
    protocol = "-1"
    source_security_group_id = "${aws_security_group.rancher_ha_allow_internal.id}"
}

resource "aws_security_group_rule" "egress_all_rancher_ha" {
    security_group_id = "${aws_security_group.rancher_ha_allow_internal.id}"
    type = "egress"
    from_port = 0
    to_port = 0 
    protocol = "-1"
    source_security_group_id = "${aws_security_group.rancher_ha_allow_internal.id}"
}
# User-data template
resource "template_file" "user_data" {

    template = "${file("${path.module}/files/userdata.template")}"

    vars {

        # Database
        database_address  = "${var.database_address}"
        database_port     = "${var.database_port}"
        database_name     = "${var.database_name}"
        database_username = "${var.database_username}"
        database_password = "${var.database_password}"
        
	#Rancher HA encryption key
	encryption_key    = "${var.ha_encryption_key}"
    }

    lifecycle {
        create_before_destroy = true
    }

}

provider "aws" {
    region = "${var.region}"
}

# Elastic Load Balancer
resource "aws_elb" "rancher_ha" {
  name = "rancher-ha"
  subnets = ["${split(",", var.private_subnet_ids)}"]  
  cross_zone_load_balancing = true 
  internal = true
#  cross_zone_load_balancing = true 
  security_groups = ["${aws_security_group.rancher_ha_web_elb.id}"]
  listener {
    instance_port = 81 
    instance_protocol = "tcp"
    lb_port = 443
    lb_protocol = "ssl"
    ssl_certificate_id = "${aws_iam_server_certificate.rancher_ha.arn}"
  }
  health_check {
    healthy_threshold = 2
    unhealthy_threshold = 4
    timeout = 15
    target = "TCP:81"
    interval = 60
  }

  #cross_zone_load_balancing = true set this when multi az pattern is fixed
  cross_zone_load_balancing = true 
}
resource "aws_proxy_protocol_policy" "rancher_ha" {
	  load_balancer = "${aws_elb.rancher_ha.name}"
	    instance_ports = ["81", "444"]
    }

# rancher resource
resource "aws_launch_configuration" "rancher_ha" {
    name_prefix = "Launch-Config-rancher-server-ha"
    image_id = "${var.ami_id}"
    security_groups = [ "${aws_security_group.rancher_ha_allow_elb.id}",
                        "${aws_security_group.rancher_ha_web_elb.id}",
			"${aws_security_group.rancher_ha_allow_internal.id}"]
    instance_type = "${var.instance_size}"
    key_name      = "${var.key_name}"
    user_data     = "${template_file.user_data.rendered}"
    associate_public_ip_address = false
    ebs_optimized = true

}

resource "aws_autoscaling_group" "rancher_ha" {
  name   = "${var.name}-asg"
  min_size = "${var.scale_min_size}"
  max_size = "${var.scale_max_size}" 
  desired_capacity = "${var.scale_desired_size}" 
  health_check_grace_period = 900
  health_check_type = "ELB"
  force_delete = false 
  launch_configuration = "${aws_launch_configuration.rancher_ha.name}"
  load_balancers = ["${aws_elb.rancher_ha.name}"]
  vpc_zone_identifier = [ "${split(",",terraform_remote_state.tlg1.output.private_subnet_ids)}" ]
  tag {
    key = "Name"
    value = "${var.name}"
    propagate_at_launch = true
  }

}

resource "aws_route53_record" "rancher_ha" {
  zone_id = "${var.route_zone_id}"
  name    = "rancher.${var.sub_domain}"
  type    = "CNAME"
  ttl     = "5"
  records = ["${aws_elb.rancher_ha.dns_name}"] 
}

output "elb_dns"      { value = "${aws_elb.rancher_ha.dns_name}" } 
output "private_fqdn" { value = "${aws_route53_record.rancher_ha.fqdn}"
