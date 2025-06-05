#!/bin/bash

set -e  # Stop bij fouten
export DEBIAN_FRONTEND=noninteractive

# Standaardwaarden
HOSTNAME="localhost"
USERNAME="admin"
PASSWORD="password123"
EMAIL="test@example.com"
STORAGEACCOUNT=""
CONTAINER=""

for i in "$@"; do
	case $i in
		--hostname=*) HOSTNAME="${i#*=}" ;;
		--username=*) USERNAME="${i#*=}" ;;
		--password=*) PASSWORD="${i#*=}" ;;
		--email=*) EMAIL="${i#*=}" ;;
		--storageaccount=*) STORAGEACCOUNT="${i#*=}" ;;
		--container=*) CONTAINER="${i#*=}" ;;
	esac
done

echo "[INFO] Systeem bijwerken en vereisten installeren..."
apt-get update
apt-get install -y software-properties-common
add-apt-repository -y universe || echo "[WAARSCHUWING] Universe repo toevoegen faalde, mogelijk al actief."
apt-get update
apt-get upgrade -y

apt-get install -y php8.1 php8.1-cli php8.1-common php8.1-imap php8.1-redis php8.1-snmp php8.1-xml php8.1-zip php8.1-mbstring php8.1-curl php8.1-gd php8.1-mysql apache2 mariadb-server certbot nfs-common python3-certbot-apache unzip wget curl

echo "[INFO] Controleren of database al bestaat..."
DBPASSWORD=$(openssl rand -base64 14)
if ! mysql -e "USE nextcloud;" 2>/dev/null; then
    echo "[INFO] Database wordt aangemaakt..."
    mysql -e "CREATE DATABASE nextcloud; GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost' IDENTIFIED BY '$DBPASSWORD'; FLUSH PRIVILEGES;"
else
    echo "[WARN] Database 'nextcloud' bestaat al, overslaan..."
    # Eventueel hier DBPASSWORD uit een veilige locatie halen?
    DBPASSWORD="wachtwoord_hier_handmatig_invullen_of_uit_bestand"
fi

echo "[INFO] Fileshare mounten..."
mkdir -p /mnt/files
NFS_PATH="$STORAGEACCOUNT.privatelink.blob.core.windows.net:/$STORAGEACCOUNT/$CONTAINER"
echo "$NFS_PATH /mnt/files nfs defaults,sec=sys,vers=3,nolock,proto=tcp,nofail,x-systemd.automount 0 0" >> /etc/fstab
mount -a || {
    echo "[FOUT] Mount mislukt. Controleer of de Private Endpoint + DNS correct zijn.";
    exit 1
}
if ! mountpoint -q /mnt/files; then
    echo "[FOUT] /mnt/files is geen actieve mount. Stoppen..."
    exit 1
fi

echo "[INFO] Nextcloud downloaden en installeren..."
cd /var/www/html
wget -q https://download.nextcloud.com/server/releases/nextcloud-24.0.1.zip
unzip -q nextcloud-24.0.1.zip
rm nextcloud-24.0.1.zip
chown -R root:root nextcloud
cd nextcloud

php occ maintenance:install \
  --database "mysql" \
  --database-name "nextcloud" \
  --database-user "nextcloud" \
  --database-pass "$DBPASSWORD" \
  --admin-user "$USERNAME" \
  --admin-pass "$PASSWORD" \
  --data-dir /mnt/files

sed -i "s/0 => 'localhost',/0 => '$HOSTNAME',/g" ./config/config.php
sed -i "s#'overwrite.cli.url' => 'https://localhost'#'overwrite.cli.url' => 'http://$HOSTNAME'#" ./config/config.php

cd ..
chown -R www-data:www-data nextcloud
chown -R www-data:www-data /mnt/files

echo "[INFO] Apache configureren..."
cat > /etc/apache2/sites-available/nextcloud.conf << EOF
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

    ErrorLog /var/log/apache2/${HOSTNAME}_error.log
    CustomLog /var/log/apache2/${HOSTNAME}_access.log combined
</VirtualHost>
EOF

a2ensite nextcloud.conf
a2enmod rewrite

echo "[INFO] Let's Encrypt certificaat aanvragen..."
certbot run -d "$HOSTNAME" --agree-tos --apache -m "$EMAIL" -n || {
  echo "[WARN] Certbot configuratie is mogelijk mislukt. Controleer of poort 80 open is."
}

systemctl restart apache2
echo "[KLAAR] Nextcloud-installatie voltooid op http://$HOSTNAME"
