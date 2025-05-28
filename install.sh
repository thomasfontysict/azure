#!/bin/bash

export DEBIAN_FRONTEND=noninteractive

# defaults 
HOSTNAME="localhost"
USERNAME="admin"
PASSWORD="password123"
EMAIL="test@example.com"
STORAGEACCOUNT=""
CONTAINER=""

for i in "$@"
do
	case $i in
		--hostname=*)
		HOSTNAME="${i#*=}" 
		;;
		--username=*)
		USERNAME="${i#*=}"
		;;
		--password=*)
		PASSWORD="${i#*=}"
		;;
		--email=*)
		EMAIL="${i#*=}"
		;;
		--storageaccount=*)
		STORAGEACCOUNT="${i#*=}"
		;;	
		--container=*)
		CONTAINER="${i#*=}"
		;;			
		*)
		;;
	esac
done

# Zorg dat universe repository beschikbaar is en update pakketlijst
apt-get update
apt-get install -y software-properties-common
add-apt-repository universe
apt-get update
apt-get upgrade -y

# Installeer alle benodigde pakketten in één keer
apt-get install -y php8.1 php8.1-cli php8.1-common php8.1-imap php8.1-redis php8.1-snmp php8.1-xml php8.1-zip php8.1-mbstring php8.1-curl php8.1-gd php8.1-mysql apache2 mariadb-server certbot nfs-common python3-certbot-apache unzip wget curl

# Maak database en gebruiker aan
DBPASSWORD=$(openssl rand -base64 14)
mysql -e "CREATE DATABASE nextcloud;GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost' IDENTIFIED BY '$DBPASSWORD';FLUSH PRIVILEGES;"

# Mount de file storage
mkdir -p /mnt/files
echo "$STORAGEACCOUNT.privatelink.blob.core.windows.net:/$STORAGEACCOUNT/$CONTAINER  /mnt/files    nfs defaults,sec=sys,vers=3,nolock,proto=tcp,nofail    0 0" >> /etc/fstab 
mount -a
if ! mountpoint -q /mnt/files; then
  echo "Mounting failed"
  exit 1
fi

# Download Nextcloud
cd /var/www/html
wget https://download.nextcloud.com/server/releases/nextcloud-24.0.1.zip
unzip nextcloud-24.0.1.zip
chown -R root:root nextcloud
cd nextcloud

# Installeer Nextcloud
php occ maintenance:install --database "mysql" --database-name "nextcloud"  --database-user "nextcloud" --database-pass "$DBPASSWORD" --admin-user "$USERNAME" --admin-pass "$PASSWORD" --data-dir /mnt/files
sed -i "s/0 => 'localhost',/0 => '$HOSTNAME',/g" ./config/config.php
sed -i "s/  'overwrite.cli.url' => 'https:\/\/localhost',/  'overwrite.cli.url' => 'http:\/\/$HOSTNAME',/g" ./config/config.php

cd ..
chown -R www-data:www-data nextcloud
chown -R www-data:www-data /mnt/files

# Configureer Apache
tee /etc/apache2/sites-available/nextcloud.conf << EOF
<VirtualHost *:80>
ServerName $HOSTNAME
DocumentRoot /var/www/html/nextcloud

<Directory /var/www/html/nextcloud/>
 Require all granted
 Options FollowSymlinks MultiViews
 AllowOverride All
 <IfModule mod_dav.c>
 Dav off
 </IfModule>
</Directory>

ErrorLog /var/log/apache2/$HOSTNAME.error_log
CustomLog /var/log/apache2/$HOSTNAME.access_log common
</VirtualHost>
EOF

a2ensite nextcloud.conf
a2enmod rewrite

# Verkrijg Let's Encrypt certificaat
certbot run -d $HOSTNAME --agree-tos --apache -m $EMAIL -n

# Herstart Apache
systemctl restart apache2
