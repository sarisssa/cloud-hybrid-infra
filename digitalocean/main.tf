data "digitalocean_ssh_key" "terraform" {
  name = "terraform"
}

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
    source = "digitalocean/prometheus.yml"
    destination = "/tmp/prometheus.yml"
  }
  
}

resource "null_resource" "run_on_file_change" {
  triggers = {
    file_hash = filemd5("${path.module}/playbook.yml")
  }

  provisioner "local-exec" {
    command = <<EOT
      mkdir -p ~/.ssh
      ssh-keyscan -H ${digitalocean_droplet.sarisssa-infra-nyc-droplet.ipv4_address} >> ~/.ssh/known_hosts
      ansible-playbook -i ${digitalocean_droplet.sarisssa-infra-nyc-droplet.ipv4_address}, --private-key=${var.pvt_key} -u root digitalocean/playbook.yml \
        -e "ipv4_address=${digitalocean_droplet.sarisssa-infra-nyc-droplet.ipv4_address} domain=${var.domain} porkbun_secret=${var.porkbun_secret} porkbun_api_key=${var.porkbun_api_key} email=${var.email}"
    EOT
  }
}

