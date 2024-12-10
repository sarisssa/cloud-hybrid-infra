terraform {
  backend "s3" {
    bucket = "tf-state-demetrian"
    key    = "demetrian.tfstate"
    region = "us-west-1"
    profile= "default"
  }
}

module "aws" {
  source = "./aws"
}

module "digitalocean" {
  source = "./digitalocean"
  pvt_key = var.pvt_key
  do_token = var.do_token
  email = var.email
  porkbun_secret = var.porkbun_secret
  porkbun_api_key = var.porkbun_api_key 
  domain = var.domain
}


