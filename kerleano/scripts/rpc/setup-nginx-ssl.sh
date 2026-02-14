#!/bin/bash
# Setup nginx reverse proxy with Let's Encrypt SSL for Kerleano RPC node
# Run as ubuntu user (with sudo)

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <domain> [email]"
    echo "  domain: your FQDN (e.g. rpc.kerleano.example.com)"
    echo "  email:  email for Let's Encrypt notifications (optional)"
    exit 1
fi

DOMAIN=$1
EMAIL=${2:-""}

# Install nginx and certbot
sudo apt-get update
sudo apt-get install -y nginx certbot python3-certbot-nginx

# Deploy nginx config
sudo cp /chain/rpc/nginx-rpc-locations.conf /etc/nginx/rpc-locations.conf
sudo sed "s/YOUR_DOMAIN/$DOMAIN/g" /chain/rpc/nginx-rpc.conf > /tmp/nginx-rpc.conf
sudo cp /tmp/nginx-rpc.conf /etc/nginx/sites-available/rpc
sudo ln -sf /etc/nginx/sites-available/rpc /etc/nginx/sites-enabled/rpc
sudo rm -f /etc/nginx/sites-enabled/default

# Test and reload nginx
sudo nginx -t
sudo systemctl reload nginx

# Obtain SSL certificate (certbot will modify the nginx config to add the 443 server block)
if [ -n "$EMAIL" ]; then
    sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
else
    sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
fi

# Certbot auto-renewal is installed automatically via systemd timer
echo ""
echo "Done! Your RPC endpoint is available at:"
echo "  HTTPS: https://$DOMAIN/"
echo "  WSS:   wss://$DOMAIN/ws"
