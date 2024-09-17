#!/bin/bash

echo "Starting ISC Kea DHCP4 server and PostgreSQL setup..."

# ------------------- STEP 1: Kea DHCP4 Server Setup -------------------

echo "Step 1: Installing required packages for ISC Kea..."
apt update
apt install curl apt-transport-https -y

# Add ISC Kea repository and install the DHCP4 server
echo "Step 2: Adding ISC Kea repository and installing DHCP4 server..."
curl -1sLf 'https://dl.cloudsmith.io/public/isc/kea-2-6/setup.deb.sh' | sudo -E bash
apt install isc-kea-dhcp4-server -y
echo "ISC Kea DHCP4 server installed."
echo "install kea-admin-tools."
apt install isc-kea-admin -y
# Backup the original Kea DHCP4 configuration
echo "Step 3: Backing up the existing configuration..."
cd /etc/kea/
mv kea-dhcp4.conf kea-dhcp4.conf.bak

# Create the new kea-dhcp4.conf configuration file
echo "Step 4: Creating new Kea DHCP4 configuration..."
cat <<EOT > kea-dhcp4.conf
{
    "Dhcp4": {
        "interfaces-config": {
            "interfaces": ["ens192"],
            "dhcp-socket-type": "udp"
        },
        "control-socket": {
            "socket-type": "unix",
            "socket-name": "/tmp/kea4-ctrl-socket"
        },
        "lease-database": {
            "type": "memfile",
            "lfc-interval": 3600
        },
        "hosts-database": {
            "type": "postgresql",
            "name": "hostdb",
            "user": "kea",
            "password": "keadhcp",
            "host": ""
        },
        "expired-leases-processing": {
            "reclaim-timer-wait-time": 10,
            "flush-reclaimed-timer-wait-time": 25,
            "hold-reclaimed-time": 3600,
            "max-reclaim-leases": 100,
            "max-reclaim-time": 250,
            "unwarned-reclaim-cycles": 5
        },
        "renew-timer": 900,
        "rebind-timer": 1800,
        "valid-lifetime": 3600,
        "option-data": [
            {
                "name": "domain-name-servers",
                "data": "1.1.1.1"
            }
        ],
        "subnet4": [
            {
                "id": 4002,
                "subnet": "10.20.2.0/24",
                "option-data": [
                    {
                        "name": "routers",
                        "data": "10.20.2.1"
                    }
                ]
            }
        ],
        "loggers": [
            {
                "name": "kea-dhcp4",
                "output-options": [
                    {
                        "output": "stdout",
                        "pattern": "%-5p %m\n"
                    }
                ],
                "severity": "INFO",
                "debuglevel": 0
            }
        ]
    }
}
EOT
echo "New configuration file created."

# Set proper ownership for the configuration file
echo "Step 5: Setting ownership of the configuration file..."
chown _kea:root kea-dhcp4.conf
echo "Ownership set."

# Restart the Kea DHCP4 server
echo "Step 6: Restarting the Kea DHCP4 server..."
systemctl restart isc-kea-dhcp4-server
echo "Kea DHCP4 server restarted."

# Create the Python script for adding host reservations
echo "Step 7: Creating the Python script for host reservations..."
cat <<EOT > /etc/kea/add.sql
START TRANSACTION;
\set ipv4_reservation '192.0.2.4'
\set hostname   'myhost.example.org'
\set identifier_type 'hw-address'
\set identifier_value '10:20:30:40:50:60'
\set dhcp4_subnet_id 1

INSERT INTO hosts (dhcp_identifier,
                   dhcp_identifier_type,
                   dhcp4_subnet_id,
                   ipv4_address,
                   hostname)
VALUES (DECODE(REPLACE(:'identifier_value', ':', ''), 'hex'),
        (SELECT type FROM host_identifier_type WHERE name=:'identifier_type'),
        :dhcp4_subnet_id,
        (SELECT (:'ipv4_reservation'::inet - '0.0.0.0'::inet)),
        :'hostname');
COMMIT;
EOT
echo "script created."

# Make the Python script executable
chmod +x /etc/kea/add.py
echo "Python script is now executable."

# ------------------- STEP 2: PostgreSQL Setup -------------------

echo "Step 8: Adding PostgreSQL APT repository..."

# Add PostgreSQL repository to sources list
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'

# Import the repository signing key
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo tee /etc/apt/trusted.gpg.d/postgresql.asc > /dev/null

echo "PostgreSQL repository added."

# Update the package lists
echo "Step 9: Updating package lists and installing PostgreSQL..."
sudo apt update

# Install PostgreSQL
sudo apt install postgresql -y

# Restart PostgreSQL service
sudo systemctl restart postgresql
echo "PostgreSQL installed and restarted."

# Switch to postgres user and create database and user
echo "Step 10: Setting up PostgreSQL database and user..."

sudo -u postgres psql postgres <<EOF
CREATE DATABASE hostdb;
CREATE USER kea WITH PASSWORD 'keadhcp';
GRANT ALL PRIVILEGES ON DATABASE hostdb TO kea;
\c hostdb
GRANT ALL PRIVILEGES ON SCHEMA public TO kea;
\q
EOF

echo "Database 'hostdb' and user 'kea' created with necessary privileges."

# Find the PostgreSQL version
PG_VERSION=$(psql --version | awk '{print $3}' | cut -d '.' -f1,2)

# Edit the pg_hba.conf file
echo "Step 11: Configuring pg_hba.conf for password authentication..."

sudo sed -i "s/local   all             all                                     peer/local   all             all                                     md5/" /etc/postgresql/16/main/pg_hba.conf

echo "pg_hba.conf updated to use md5 authentication."

# Restart PostgreSQL service
sudo systemctl restart postgresql
echo "PostgreSQL restarted with updated authentication method."

# Load the database schema
echo "Step 12: Loading the DHCP database schema..."
psql -d hostdb -U kea -f /usr/share/kea/scripts/pgsql/dhcpdb_create.pgsql

echo "Database schema loaded successfully."

echo "Step 6: Restarting the Kea DHCP4 server..."
systemctl restart isc-kea-dhcp4-server
echo "Kea DHCP4 server restarted."

echo "ISC Kea DHCP4 and PostgreSQL setup complete."
