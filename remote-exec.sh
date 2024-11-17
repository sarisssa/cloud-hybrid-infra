#!/bin/bash

set -e

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

check_command() {
    if [ $? -eq 0 ]; then
        log "✅ $1 completed successfully"
    else
        log "❌ $1 failed"
        exit 1
    fi
}

wait_for_apt() {
    local max_attempts=60  
    local attempt=1

    log "Waiting for apt locks to be released..."
    
    while [ $attempt -le $max_attempts ]; do
        if sudo lsof /var/lib/dpkg/lock-frontend > /dev/null 2>&1; then
            log "Attempt $attempt: Package system is locked. Waiting 10 seconds..."
            sleep 10
            attempt=$((attempt + 1))
        else
            # Double check with a small delay to ensure stability
            sleep 2
            if ! sudo lsof /var/lib/dpkg/lock-frontend > /dev/null 2>&1; then
                log "Package system is now available"
                return 0
            fi
        fi
    done

    log "Error: Package system is still locked after 10 minutes. Aborting."
    exit 1
}

# Function to safely run apt commands
safe_apt_get() {
    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if wait_for_apt; then
            if sudo apt-get "$@"; then
                return 0
            fi
        fi
        log "Attempt $attempt failed. Retrying..."
        attempt=$((attempt + 1))
        sleep 5
    done

    log "Error: apt-get command failed after $max_attempts attempts"
    return 1
}

# Validate input parameters
if [ -z "$1" ]; then
    log "Error: IPv4 address argument is required"
    echo "Usage: $0 <ipv4_address>"
    exit 1
fi

# Configuration variables
IPV4_ADDRESS="$1"
DOMAIN="$2"
PORKBUN_SECRET="$3"
PORKBUN_API_KEY="$4"
EMAIL="$5"

log "Starting infra setup for $DOMAIN"

echo $IPV4_ADDRESS HELLO WORLDDDDDDD

# Update PATH
export PATH=$PATH:/usr/bin
log "Updated PATH environment"

log "Updating system packages..."
wait_for_apt
safe_apt_get update
check_command "System update"

log "Installing Nginx..."
safe_apt_get install nginx -y
check_command "Nginx installation"

log "Stopping Nginx for Certbot..."
sudo systemctl stop nginx
check_command "Nginx stop"

# Install Certbot via Snap
log "Installing Certbot and dependencies..."
safe_apt_get install -y snapd
sudo snap install core
sudo snap refresh core
sudo snap install --classic certbot
sudo ln -sf /snap/bin/certbot /usr/bin/certbot
check_command "Certbot installation"

# Install Docker
log "Installing Docker..."
{
    safe_apt_get install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
} 2>/dev/null
check_command "Docker prerequisites"

log "Adding Docker repository..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
check_command "Docker repository setup"

log "Installing Docker packages..."
wait_for_apt
safe_apt_get update
safe_apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
check_command "Docker installation"

# Install and run Prometheus
log "Pulling Prometheus Docker image..."
docker pull prom/prometheus
check_command "Prometheus Docker image pull"

# Install Node Exporter to monitor system metrics
log "Installing Node Exporter..."
wget https://github.com/prometheus/node_exporter/releases/latest/download/node_exporter-1.8.2.linux-amd64.tar.gz
tar xvfz node_exporter-1.8.2.linux-amd64.tar.gz
sudo mv node_exporter-1.8.2.linux-amd64/node_exporter /usr/local/bin/
rm -rf node_exporter-1.8.2

# Start Node Exporter as a background service
nohup /usr/local/bin/node_exporter &
check_command "Node Exporter running"

# Purge all existing A Records and create a new A Record in Porkbun
log "Updating DNS records..."

curl --location "https://api.porkbun.com/api/json/v3/dns/deleteByNameType/$DOMAIN/A" \
--data '{
	"secretapikey": "'$PORKBUN_SECRET'",
    "apikey": "'$PORKBUN_API_KEY'"
}'

log "Deleting old DNS records..."

curl --location "https://api.porkbun.com/api/json/v3/dns/create/$DOMAIN" \
--data '{
    "secretapikey": "'$PORKBUN_SECRET'",
    "apikey": "'$PORKBUN_API_KEY'",
    "type": "A",
    "content": "'$IPV4_ADDRESS'",
    "ttl": "200"
}'
check_command "DNS update"

log "Waiting for DNS propagation (30 seconds)..."
sleep 30

log "Ensuring Nginx is stopped..."
sudo systemctl stop nginx || true
sleep 5

log "Generating SSL certificate..."
sudo certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m $EMAIL
check_command "SSL certificate generation"

# Purge old configurations
log "Cleaning up old Nginx configurations..."
sudo rm -f /etc/nginx/sites-available/$DOMAIN
sudo rm -f /etc/nginx/sites-enabled/$DOMAIN
sudo rm -f /etc/nginx/sites-enabled/default
check_command "Nginx cleanup"

# Create website directory
log "Setting up website directory..."
sudo mkdir -p /var/www/$DOMAIN/html
sudo chmod -R 755 /var/www/$DOMAIN
echo '<h1>Hello from '$DOMAIN'</h1>' | sudo tee /var/www/$DOMAIN/html/index.html
check_command "Website directory setup"

# Verify SSL certificate exists
if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    log "Error: SSL certificate files not found. Certbot may have failed."
    exit 1
fi

# Create Nginx configuration
log "Creating Nginx configuration..."
sudo bash -c 'cat > /etc/nginx/sites-available/'$DOMAIN' <<EOF
server {
    listen 80;
    server_name '$DOMAIN' www.'$DOMAIN';
    
    # Redirect all HTTP requests to HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name '$DOMAIN' www.'$DOMAIN';

    ssl_certificate /etc/letsencrypt/live/'$DOMAIN'/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/'$DOMAIN'/privkey.pem;

    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384";

    root /var/www/'$DOMAIN'/html;
    index index.html;

    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;

        # Disable buffering for streaming support
        proxy_buffering off;
        proxy_set_header X-Accel-Buffering no;
    }

    location /prometheus/ {
        proxy_pass http://localhost:9090;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;

    }
}
EOF'
check_command "Nginx configuration creation"

docker run -d --name prometheus -p 9090:9090 -v /tmp/prometheus.yml:/etc/prometheus/prometheus.yml prom/prometheus --config.file=/etc/prometheus/prometheus.yml --web.external-url=/prometheus


# Final Nginx Checks
log "Enabling Nginx site..."
sudo ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
check_command "Nginx site enable"

log "Testing Nginx configuration..."
sudo nginx -t
check_command "Nginx configuration test"

log "Starting Nginx..."
sudo systemctl start nginx
check_command "Nginx start"

log "Infrastructure setup completed successfully🎉"

docker pull sarisssa/demetrian:main
docker run -d --name demetrian-fe -p 3000:3000 sarisssa/demetrian:main

