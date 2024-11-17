data "digitalocean_ssh_key" "terraform" {
  name = "terraform"
}

// <company-name>-<project-name>-<environment>-<location>-<resource>

resource "digitalocean_droplet" "sarisssa-infra-nyc-droplet" {
  image = "ubuntu-20-04-x64"
  name = "sarisssa-infra-nyc-droplet"
  region = "nyc3"
  size = "s-1vcpu-1gb"
  ssh_keys = [
    data.digitalocean_ssh_key.terraform.id
  ]
  
  connection {
    host = self.ipv4_address
    user = "root"
    type = "ssh"
    private_key = file(var.pvt_key)
    timeout = "2m"
  }

  provisioner "file" {
    source      = "remote-exec.sh"
    destination = "/tmp/remote-exec.sh"
  }

  provisioner "file" {
    source = "digitalocean/prometheus.yml"
    destination = "/tmp/prometheus.yml"
  }
  
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/remote-exec.sh",
      "/tmp/remote-exec.sh ${self.ipv4_address} ${var.domain} ${var.porkbun_secret} ${var.porkbun_api_key} ${var.email}"
    ]
  }
}

