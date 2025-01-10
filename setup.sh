#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Function to print status messages
print_status() {
    echo -e "${YELLOW}[*] $1${NC}"
}

print_success() {
    echo -e "${GREEN}[+] $1${NC}"
}

print_error() {
    echo -e "${RED}[-] $1${NC}"
}

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
    print_error "Please run as root"
    exit 1
fi

# Get configuration values
read -p "Enter PostgreSQL password for arweave_user: " DB_PASSWORD
read -p "Enter email for SSL certificate: " SSL_EMAIL

print_status "Starting Arweave Tracker installation..."

# Update system
print_status "Updating system packages..."
apt update && apt upgrade -y

# Install required packages
print_status "Installing required packages..."
apt install -y python3.11 python3.11-venv python3-pip postgresql postgresql-contrib nginx certbot python3-certbot-nginx

# Configure PostgreSQL
print_status "Configuring PostgreSQL..."
sudo -u postgres psql -c "CREATE DATABASE arweave_tracker;"
sudo -u postgres psql -c "CREATE USER arweave_user WITH PASSWORD '$DB_PASSWORD';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE arweave_tracker TO arweave_user;"

# Create application directory
print_status "Setting up application directory..."
mkdir -p /var/www/arweave-tracker
cd /var/www/arweave-tracker

# Create virtual environment and install packages
print_status "Setting up Python environment..."
python3.11 -m venv venv
source venv/bin/activate
pip install streamlit plotly psycopg2-binary requests apscheduler

# Create environment file
print_status "Creating environment file..."
cat > /var/www/arweave-tracker/.env << EOF
PGDATABASE=arweave_tracker
PGUSER=arweave_user
PGPASSWORD=$DB_PASSWORD
PGHOST=localhost
PGPORT=5432
EOF

# Create systemd service
print_status "Creating systemd service..."
cat > /etc/systemd/system/arweave-tracker.service << EOF
[Unit]
Description=Arweave Wallet Tracker
After=network.target

[Service]
User=www-data
WorkingDirectory=/var/www/arweave-tracker
Environment="PATH=/var/www/arweave-tracker/venv/bin"
EnvironmentFile=/var/www/arweave-tracker/.env
ExecStart=/var/www/arweave-tracker/venv/bin/streamlit run main.py --server.port 5000 --server.address 0.0.0.0

[Install]
WantedBy=multi-user.target
EOF

# Configure Nginx
print_status "Configuring Nginx..."
cat > /etc/nginx/sites-available/arweave-tracker << EOF
server {
    listen 80;
    server_name arweave.pixelguardian.eu;

    location / {
        proxy_pass http://localhost:5000;
        proxy_http_version 1.1;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$http_host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

# Enable site
ln -s /etc/nginx/sites-available/arweave-tracker /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Configure backup script
print_status "Setting up backup system..."
cat > /usr/local/bin/backup-arweave-tracker.sh << EOF
#!/bin/bash
BACKUP_DIR="/var/backups/arweave-tracker"
TIMESTAMP=\$(date +"%Y%m%d_%H%M%S")
mkdir -p \$BACKUP_DIR

# Backup database
pg_dump arweave_tracker > \$BACKUP_DIR/backup_\$TIMESTAMP.sql

# Backup application files
tar -czf \$BACKUP_DIR/app_backup_\$TIMESTAMP.tar.gz /var/www/arweave-tracker

# Keep only last 7 days of backups
find \$BACKUP_DIR -type f -mtime +7 -delete
EOF

chmod +x /usr/local/bin/backup-arweave-tracker.sh
echo "0 2 * * * /usr/local/bin/backup-arweave-tracker.sh" | tee -a /var/spool/cron/crontabs/root

# Configure firewall
print_status "Configuring firewall..."
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow ssh
ufw --force enable

# Start services
print_status "Starting services..."
systemctl enable postgresql
systemctl start postgresql
systemctl enable arweave-tracker
systemctl start arweave-tracker
systemctl enable nginx
systemctl start nginx

# Configure SSL
print_status "Configuring SSL certificate..."
certbot --nginx -d arweave.pixelguardian.eu --non-interactive --agree-tos --email "$SSL_EMAIL"

print_success "Installation complete!"
print_success "Your application should be available at https://arweave.pixelguardian.eu"
print_status "Please copy your application files to /var/www/arweave-tracker/"
print_status "Check the deployment guide for additional configuration options and troubleshooting"

# Test the installation
print_status "Testing installation..."
curl -sI https://arweave.pixelguardian.eu | head -n 1

# Final instructions
cat << EOF

==============================================
Installation Complete!
==============================================

Next steps:
1. Copy your application files to /var/www/arweave-tracker/
2. Restart the service: sudo systemctl restart arweave-tracker
3. Check the logs: sudo journalctl -u arweave-tracker -f
4. Test the application at https://arweave.pixelguardian.eu

For troubleshooting, refer to the deployment guide.
EOF
