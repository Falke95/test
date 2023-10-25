#!/bin/bash

if [[ -e /etc/system-release ]]; then
    DISTRO=`cat /etc/system-release`
else
    DISTRO=`cat /etc/issue`
fi

is_ubuntu() {
  [[ $DISTRO =~ ^Ubuntu ]]
}

function is_centos7 {
  if [[ $DISTRO == "CentOS Linux release 7"* ]]; then
      true
  else
      false
  fi
}

if is_centos7; then
    echo "Host OS is Centos7"
elif is_ubuntu; then
    echo "Host OS is Ubuntu"
    UBUNTU_RELEASE=`lsb_release -a | grep ^Release | awk '{print $2}'`
    if [[ $UBUNTU_RELEASE != "20.04" ]]; then
        echo "This version of Ubuntu is not currently supported. Supported versions: 20.04 (LTS)"
        exit
    fi

else
    echo "Unsupported Distro: $DISTRO" 1>&2
    exit 1
fi

if [ -f /opt/bin/utils.ini ]; then

    MYSQL_PASS=`cat /opt/bin/utils.ini | grep SU_PASSWD | awk '{print $3}'`

    BILLING_DB_HOST=`cat /opt/bin/utils.ini | grep BILLING_DB_HOST | awk '{print $3}'`
    BILLING_DB_NAME=`cat /opt/bin/utils.ini | grep BILLING_DB_NAME | awk '{print $3}'`
    BILLING_DB_USER=`cat /opt/bin/utils.ini | grep BILLING_DB_USER | awk '{print $3}'`
    BILLING_DB_PASS=`cat /opt/bin/utils.ini | grep BILLING_DB_PASS | awk '{print $3}'`

    CATALOG_DB_HOST=`cat /opt/bin/utils.ini | grep CATALOG_DB_HOST | awk '{print $3}'`
    CATALOG_DB_NAME=`cat /opt/bin/utils.ini | grep CATALOG_DB_NAME | awk '{print $3}'`
    CATALOG_DB_USER=`cat /opt/bin/utils.ini | grep CATALOG_DB_USER | awk '{print $3}'`
    CATALOG_DB_PASS=`cat /opt/bin/utils.ini | grep CATALOG_DB_PASS | awk '{print $3}'`
    MAIN_VHOST=`cat /opt/bin/utils.ini | grep MAIN_VHOST | awk '{print $3}'`
    PROFTPD_PASS=`cat /opt/bin/utils.ini | grep PROFTPD_DB_PASS | awk '{print $3}'`
else
    MYSQL_PASS=`date +%s | sha256sum | base64 | head -c 10 ; echo`
    sleep 1
    BILLING_DB_HOST="localhost"
    BILLING_DB_NAME="sc_billing"
    BILLING_DB_USER="sc_billing_user"
    BILLING_DB_PASS=`date +%s | sha256sum | base64 | head -c 10 ; echo`
    sleep 1
    CATALOG_DB_HOST="localhost"
    CATALOG_DB_NAME="sc_catalog"
    CATALOG_DB_USER="sc_catalog_user"
    CATALOG_DB_PASS=`date +%s | sha256sum | base64 | head -c 10 ; echo`
    sleep 1
    PROFTPD_PASS=`date +%s | sha256sum | base64 | head -c 10 ; echo`
fi

# etc/ispmgr.db
#mysqllocalhostroot
NODE_NAME=
MY_PWD=`pwd`
SRC_DIR=$MY_PWD

if is_centos7; then
    APACHE_USER="apache"
    NGINX_USER="nginx"
    APACHE_SERVICE_NAME="httpd"
    BINARY_TARGET="centos7"
    APACHE_CONF_BASE="/etc/$APACHE_SERVICE_NAME/conf.d"
    SUPERVISOR_SERVICE_NAME="supervisord"
    if rpm -q net-tools > /dev/null; then
        echo "Package 'net-tools' already installed, skip"
    else
        echo "Installing package net-tools..."
        yum -y install net-tools
    fi
    # Sync time
    service ntpdate restart

elif is_ubuntu; then
    APACHE_USER="www-data"
    NGINX_USER="www-data"
    APACHE_SERVICE_NAME="apache2"
    BINARY_TARGET="ubuntu20"
    APACHE_CONF_BASE="/etc/$APACHE_SERVICE_NAME/sites-enabled"
    SUPERVISOR_SERVICE_NAME="supervisor"
    apt update
    apt install -y ntpdate ntp net-tools curl
    # Sync time
    service ntp restart
fi

NGINX_CONF_BASE="/etc/nginx/conf.d"
NGINX_PORT="8080"
SC_PANEL_PORT="2345"
NGINX_SSL_PORT="8080"
PYTHON_ENV="/usr"
UWSGI_BINPATH="/usr/bin/uwsgi"
SUPERVISOR_CONF_BASE="/etc/supervisor/conf.d"
LICENSE_KEY=""
SSL_DONE=0
SSL_FOLDER="/etc/letsencrypt"


if [ -d /usr/local/mgr5/etc ]; then
    echo "ISP manager detected, getting MySQL root password..."
    pass=`cat /usr/local/mgr5/etc/common.conf | grep -oP '(?<=<property name="rootpassword">).*(?=</property)'`

    if [ -z "$pass" ]; then
	echo "Failed to et MySQL root password from ISP manager"
	pass=`/usr/local/mgr5/etc/scripts/mysql_passwd`
	if [ -z "$pass" ]; then
	    echo "Failed to et MySQL root password from ISP manager (2)"
	    exit
	else
	    MYSQL_PASS=$pass
	    echo "ISP manager password: $MYSQL_PASS"
	fi
    else
	MYSQL_PASS=$pass
	echo "ISP manager password: $MYSQL_PASS"
    fi
fi

# User directory
if [ -d /var/users ]; then
    echo "User directory already exists"
else
    read -p "The software default installation path is /var/users. Make sure you have enough space on that partition. If not - you can create a symbolic link from /var/users to any other partition that has enough disk space. Press [y] to continue or any other key to quit." -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]
    then
        echo "Cancel"
        [[ "$0" = "$BASH_SOURCE" ]] && exit 1 || return 1
    fi
    echo "Creating /var/users"
    mkdir /var/users
fi

IP=`curl -s http://whatismyip.akamai.com/`

if [ -z $IP ]; then
    IP=`/sbin/ifconfig eth0 | grep 'inet' | cut -d: -f2 | awk '{print $2}'`
fi

if [ -z $IP ]; then
    echo "eth0 missing, get venet0:0 IP"
    IP=`ifconfig venet0:0 | awk '/inet / {print $2}'`
fi

if [ -z $IP ]; then
    echo "venet0 missing, using hostname command..."
    IP=`hostname -I`
    #IP=$(echo $IP|tr -d '\n')
fi

if [ -z $IP ]; then
    echo "Unable to get the local IP address"
    exit 1
fi

IP="$(echo -e "${IP}" | tr -d '[:space:]')"

if [ -z "$MAIN_VHOST" ]; then
    echo "Please enter your domain name or leave blank to run the software on IP address [$IP]:"
    echo "NOTE: SSL encryption is available for valid domains only and not available for IP address"
    read MAIN_VHOST
    if [ -z "$MAIN_VHOST" ]; then
        echo "Are going use your IP address (not domain) - this is not recommended. Type 'yes' to confirm and continue"
        read yes
        if [[ "$yes" =~ ^([yY][eE][sS]|[yY])+$ ]]
        then
            echo "Using [$IP] as a hostname"
            MAIN_VHOST=$IP
        else
            echo "Interrupted"
            exit
        fi
    fi
fi

ADMIN_EMAIL=
ADMIN_PASS=`date +%s | sha256sum | base64 | head -c 10 ; echo`

while [[ $ADMIN_EMAIL = "" ]]; do
   read -r -p "Please enter your admin account email: " ADMIN_EMAIL
done

if [[ $MAIN_VHOST =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    USING_VHOST=0
else
    USING_VHOST=1
fi

echo "Starting installation"
echo "MySQL root password: $MYSQL_PASS"
echo "Python Lib directory: $PYTHON_LIBPATH"
echo "Apache user: $APACHE_USER"
echo "Apache service: $APACHE_SERVICE_NAME"
echo "Apache's conf.d: $APACHE_CONF_BASE"
echo "IP address: $IP"

# Packages
if is_centos7; then
    packages=(mc ntp ntpdate gcc-c++ wget autoconf automake make cmake htop httpd httpd-itk mariadb-server mariadb-devel gcc proftpd proftpd-mysql nginx supervisor flac awstats perl-Geo-IP libvorbis libvorbis-devel mysql++ id3lib-devel libcurl-devel libid3tag-devel speex-devel mercurial php glibc.i686 libicu-devel php-pecl-geoip zlib-devel libjpeg-devel freetype-devel libsamplerate-devel libtool unzip patch icecast proftpd-mysql ImageMagick openssl-devel libxslt-devel mod_ssl python3 python3-pip python3-devel certbot certbot-apache certbot-nginx php-fpm psmisc sox  libmad lame-libs ca-certificates davfs2 libebur128)

    if rpm -q yum-utils; then
        echo "Yum utils are already installed, skip..."
    else
        yum -y install yum-utils
        [ $? -eq 0 ] && echo "Yum Utils installed."
        [ $? -ne 0 ] && echo "Yum utils installation failed!" && exit
    fi


    if rpm -q epel-release; then
        echo "Epel source already installed, skip..."
    else
        yum install -y epel-release
        #yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
        [ $? -eq 0 ] && echo "Epel repo installed."
        [ $? -ne 0 ] && echo "Epel installation failed!" && exit
        yum clean all
    fi


    if rpm -q ius-release; then
        echo "IUS source already installed, skip..."
    else
        yum -y install https://repo.ius.io/ius-release-el7.rpm
        [ $? -eq 0 ] && echo "IUS repo installed."
        [ $? -ne 0 ] && echo "IUS installation failed!" && exit
        yum clean all
    fi
    yum-config-manager --enable epel
    yum-config-manager --enable ius

    echo "Installing packages"
    for p in ${packages[*]}
    do
        if rpm -q $p > /dev/null; then
        	echo "Package '$p' already installed, skip"
        else
        	echo "Installing package $p..."
        	yum -y install $p
        	[ $? -eq 0 ] && echo "Package $p has been installed successfully"
        	[ $? -ne 0 ] && echo "Package $p installation failed!" && exit
        fi
    done
    if rpm -q sox-plugins-freeworld > /dev/null; then
        echo "Package 'sox-plugins-freeworld' already installed, skip"
    else
        echo "Installing package sox-plugins-freeworld..."
        #rpm -i http://li.nux.ro/download/nux/dextop/el7/x86_64/sox-plugins-freeworld-14.4.1-3.el7.nux.x86_64.rpm
        rpm -i https://download1.rpmfusion.org/free/el/updates/7/x86_64/s/sox-plugins-freeworld-14.4.1-3.el7.x86_64.rpm
        [ $? -eq 0 ] && echo "Package sox-plugins-freeworld has been installed successfully"
        [ $? -ne 0 ] && echo "Package sox-plugins-freeworld installation failed!" && exit
    fi

    if rpm -q audiowaveform > /dev/null; then
        echo "Package 'audiowaveform' already installed, skip"
    else
        echo "Installing package audiowaveform..."
        yum install -y https://github.com/bbc/audiowaveform/releases/download/1.5.1/audiowaveform-1.5.1-1.el7.x86_64.rpm
        [ $? -eq 0 ] && echo "Package audiowaveform has been installed successfully"
        [ $? -ne 0 ] && echo "Package audiowaveform installation failed!" && exit
    fi
    
    echo "Finished installing packages"
elif is_ubuntu; then
    apt update
    DEBIAN_FRONTEND=noninteractive apt install -y mc apache2 gcc nginx supervisor python3 python3-dev python3-pip htop mysql-server libmysqlclient-dev libapache2-mpm-itk proftpd proftpd-mod-mysql lame awstats libgeo-ip-perl imagemagick libjpeg-dev zlib1g-dev policycoreutils software-properties-common letsencrypt python3-certbot-nginx python3-certbot-apache php-fpm libapache2-mod-php php-mysql libmysql++-dev icecast2 libspeex1 sox curl lib32z1 net-tools iptables davfs2 libebur128-1 libavcodec58 libavformat58 libtag1v5
    [ $? -ne 0 ] && echo "Packages installation failed!" && exit
    add-apt-repository -y ppa:chris-needham/ppa
    [ $? -ne 0 ] && echo "Packages installation failed!" && exit
    apt-get update
    apt-get install -y audiowaveform
    [ $? -ne 0 ] && echo "Packages installation failed!" && exit
    echo "Finished installing packages"
fi

APACHE_UID=`id -u $APACHE_USER`
APACHE_GID=`id -g $APACHE_USER`
PYTHON3_LIBPATH=`python3 -c "import sys; print(min(list(x for x in sys.path if x), key=len))"`
PYTHON3_VERSION=`python3 --version | awk '{print substr($2, 1, 3)}'`

# Enable Apache-itk (launch mod_php scripts with user_id set)
if is_centos7; then
    ln -s /usr/bin/python3.6 /usr/bin/python3
    echo "Enabling Apache-itk..."
    sed -i '/^#.*mpm_itk_module/s/^#//' /etc/httpd/conf.modules.d/00-mpm-itk.conf
    echo "Enabling Apache virtual hosts naming..."
    sed -i '/NameVirtualHost \*:80/ s/^#//' /etc/httpd/conf/httpd.conf
    sed -i 's/prefork.c/itk.c/' /etc/httpd/conf.d/php.conf
    rm -f /etc/nginx/conf.d/default.conf
    rm -f /etc/nginx/nginx.conf.default
fi

# Check geoip database
if [ -f /usr/share/GeoIP/GeoLite2-City.mmdb ]; then
    echo "GeoIP files alredy installed"
else
    wget -O /tmp/GeoIP.tar.gz https://everestcast.com/dist/GeoIP.tar.gz
    tar -C /usr/share -xzf /tmp/GeoIP.tar.gz
    rm -f /tmp/GeoIP.tar.gz
fi

# get AWStats paths
if is_centos7; then
    awtstas_www=`rpm -ql awstats | grep "/os/linux.png"`
    AWSTATSWWW=${awtstas_www/\/icon\/os\/linux.png/}
    awstats_pl=`rpm -ql awstats | grep "awstats\.pl$"`
    AWSTATSCGI=`dirname $awstats_pl`
    echo "Awstats htdocs: $AWSTATSWWW"
    echo "Awstats cgi-bin: $AWSTATSCGI"
    chmod 777 /etc/awstats
    sed -i "s/Allow from 127.0.0.1/Allow from all/" "$APACHE_CONF_BASE/awstats.conf"
elif is_ubuntu; then
    awtstas_www=`dpkg -L awstats | grep "/os/linux.png"`
    AWSTATSWWW=${awtstas_www/\/icon\/os\/linux.png/}
    awstats_pl=`dpkg -L awstats | grep "awstats\.pl"`
    AWSTATSCGI=`dirname $awstats_pl`
    echo "Awstats htdocs: $AWSTATSWWW"
    echo "Awstats cgi-bin: $AWSTATSCGI"
    chmod 777 /etc/awstats
    rm -f /etc/apache2/sites-enabled/000-default.conf

fi

# UWSGI Python 3
pip3 install --upgrade pip==21.3.1
pip3 uninstall -y uwsgi
pip3 install uwsgi

RETVAL=$?
[ $RETVAL -eq 0 ] && echo "UWSGI installed."
[ $RETVAL -ne 0 ] && echo "UWSGI installation failed!" && exit
'cp' -f /usr/local/bin/uwsgi /usr/bin/uwsgi3
'cp' -f /usr/local/bin/uwsgi /usr/bin/uwsgi
chmod +x /usr/bin/uwsgi3
chmod +x /usr/bin/uwsgi

echo "Installing backend dependencies"
if [ -d /opt/web_panel ]; then
    echo "Web interface already installed"
else
    echo "Installing Web interface"
    mkdir /opt/web_panel
    wget -O /tmp/web_panel.tar.gz https://everestcast.com/dist/web_panel$PYTHON3_VERSION.tar.gz
    tar -xzf /tmp/web_panel.tar.gz --directory /opt/web_panel
    rm -f /tmp/web_panel.tar.gz
fi

pip3 install --ignore-installed -r /opt/web_panel/backend/requirements.txt
RETVAL=$?
[ $RETVAL -eq 0 ] && echo "Requirements installed."
[ $RETVAL -ne 0 ] && echo "Requirements installation failed!" && exit

if is_centos7; then
    if [ -d /var/run/mariadb ]; then
        echo "/var/run/mariadb directory exists"
    else
        mkdir /var/run/mariadb
        chown mysql:mysql /var/run/mariadb
    fi

    systemctl restart mariadb

    if [ $? -eq 0 ]; then
        echo "MySQL (Mariadb) Server restarted"
    else
        echo "MySQL (Mariadb) Server restart failed"
        service mysqld restart
        if [ $? -eq 0 ]; then
            echo "MySQL (community) Server restarted"
        else
            echo "MySQL (community) Server restart failed"
            exit
        fi
    fi
elif is_ubuntu; then
    service mysql restart
    if [ $? -eq 0 ]; then
        echo "MySQL Server started"
    else
        echo "MySQL Server start failed"
        exit
    fi
fi
/usr/bin/mysqladmin -u root password $MYSQL_PASS

if [ $? -eq 0 ]; then
    echo "MySQL root password set"
else
    echo "WARNING: Failed to set MySQL root password."
fi

# Set MySQL max_connections
if is_centos7; then
    MYSQL_CONFIG=/etc/my.cnf
    if [ ! -f /etc/systemd/system/mariadb.service.d/limits.conf ]; then
        echo "Raising MySQL limit on the maximum number of open connections to 2000"
        mkdir /etc/systemd/system/mariadb.service.d/
        printf "[Service]\nLimitNOFILE=infinity\n" > /etc/systemd/system/mariadb.service.d/limits.conf
        systemctl daemon-reload
    fi
    if ! grep -qF "max_connections" $MYSQL_CONFIG
    then
        sed '/\[mysqld\]/a max_connections = 2000\' -i $MYSQL_CONFIG
    fi
elif is_ubuntu; then
    if ! egrep -q "^max_connections" /etc/mysql/mysql.conf.d/mysqld.cnf
    then
        echo "Setting 2000 max connections in MySQL"
        sed '/\[mysqld\]/a max_connections = 2000\' -i /etc/mysql/mysql.conf.d/mysqld.cnf
    fi
    rm -f /etc/apache2/sites-enabled/000-default.conf

    # Enable MySQL root connections for non-root users
    mysql -u root -p$MYSQL_PASS -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_PASS';" mysql;
    mysql -u root -p$MYSQL_PASS -e "flush privileges;"

fi
# MySQL timezone support
mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root -p$MYSQL_PASS mysql


# Install billing modules to system-wide python modules directory
cp -rf "/opt/web_panel/backend/billing/python3/radiotochka/" "$PYTHON3_LIBPATH/"

# Copy and configure utils
if [ -d /opt/bin ]; then
    echo "/opt/bin exists"
else
    mkdir /opt/bin
fi

if [ -d "$MY_PWD/utils/" ]; then
    echo "Setup utils already downloaded"
else
    wget -O /tmp/setup-utils.tar.gz https://everestcast.com/dist/setup-utils$PYTHON3_VERSION.tar.gz
    tar -xzf /tmp/setup-utils.tar.gz --directory $MY_PWD
    rm -f /tmp/setup-utils.tar.gz
fi

echo "Installing additional utilities"
source $MY_PWD/utils/install_utils
sed -i "s/NODE_NAME/$NODE_NAME/g" /opt/bin/utils.ini
sed -i "s/HOSTIP/$IP/g" /opt/bin/utils.ini
sed -i "s/MYSQL_ROOT_PASS/$MYSQL_PASS/g" /opt/bin/utils.ini
sed -i "s:AWSTATSWWW:$AWSTATSWWW:g" /opt/bin/utils.ini
sed -i "s:AWSTATSCGI:$AWSTATSCGI:g" /opt/bin/utils.ini
sed -i "s/APACHE_SERVICE_NAME/$APACHE_SERVICE_NAME/g" /opt/bin/utils.ini
sed -i "s:APACHE_CONF_BASE:$APACHE_CONF_BASE:g" /opt/bin/utils.ini
sed -i "s:MAINVHOST:$MAIN_VHOST:g" /opt/bin/utils.ini
sed -i "s:WWWUSER:$APACHE_USER:g" /opt/bin/utils.ini
sed -i "s:WWWUID:$APACHE_UID:g" /opt/bin/utils.ini
sed -i "s:WWWGID:$APACHE_GID:g" /opt/bin/utils.ini
sed -i "s:NGINX_CONF_BASE:$NGINX_CONF_BASE:g" /opt/bin/utils.ini
sed -i "s:NGINX_PORT:$NGINX_PORT:g" /opt/bin/utils.ini
sed -i "s:NGINX_SSL_PORT:$NGINX_SSL_PORT:g" /opt/bin/utils.ini
sed -i "s:PYTHONENV:$PYTHON_ENV:g" /opt/bin/utils.ini
sed -i "s:UWSGIBINPATH:$UWSGI_BINPATH:g" /opt/bin/utils.ini
sed -i "s:SUPERVISOR_CONF_BASE:$SUPERVISOR_CONF_BASE:g" /opt/bin/utils.ini
sed -i "s:SUPERVISOR_CONF_BASE:$SUPERVISOR_CONF_BASE:g" /opt/bin/utils.ini
sed -i "s:SCADMINPORT:$SC_PANEL_PORT:g" /opt/bin/utils.ini

sed -i "s:PROFTPD_DB_PASS_V:$PROFTPD_PASS:g" /opt/bin/utils.ini

# Billing
sed -i "s:BILLING_DB_HOST_V:$BILLING_DB_HOST:g" /opt/bin/utils.ini
sed -i "s:BILLING_DB_NAME_V:$BILLING_DB_NAME:g" /opt/bin/utils.ini
sed -i "s:BILLING_DB_USER_V:$BILLING_DB_USER:g" /opt/bin/utils.ini
sed -i "s:BILLING_DB_PASS_V:$BILLING_DB_PASS:g" /opt/bin/utils.ini

# General radio user
useradd -d /opt/sc_radio -s /bin/false -M sc_radio
groupadd sc_radios
usermod -a -G sc_radios sc_radio

chown root:sc_radios /opt/bin/utils.ini
chmod 660 /opt/bin/utils.ini

echo "Setting up crontab"
source $SRC_DIR/utils/install_crontab

echo "Setting up ProFTPd"
source $SRC_DIR/utils/install_proftpd

echo "Setting up logrotate"
source $SRC_DIR/utils/install_logrotate

echo "Setting up Geo Blocking"
source $SRC_DIR/utils/install_iptables_geoip

# Download FFMPEG
if [ -f /usr/bin/ffmpeg ]; then
    echo "FFMPEG is already installed"
else
    echo "Downloading FFMPEG..."
    wget -O /usr/bin/ffmpeg https://everestcast.com/dist/binaries/ffmpeg
    chmod +x /usr/bin/ffmpeg
fi


echo "Setting up supervisor"

if [ -d /etc/supervisor/conf.d ]; then
    echo "Supervisor conf.d directory exists"
else
    echo "Updating supervisor"
    #pip install supervisor
    #pip uninstall -y supervisor
    #pip install supervisor
    echo "[unix_http_server]" > /etc/supervisord.conf
    echo "file=/var/run//supervisor.sock   ; (the path to the socket file)" >> /etc/supervisord.conf
    echo "chmod=0700                       ; sockef file mode (default 0700)" >> /etc/supervisord.conf
    echo "[supervisord]" >> /etc/supervisord.conf
    echo "logfile=/var/log/supervisor/supervisord.log ; (main log file;default $CWD/supervisord.log)" >> /etc/supervisord.conf
    echo "pidfile=/var/run/supervisord.pid ; (supervisord pidfile;default supervisord.pid)" >> /etc/supervisord.conf
    echo "childlogdir=/var/log/supervisor            ; ('AUTO' child log dir, default $TEMP)" >> /etc/supervisord.conf
    echo "[rpcinterface:supervisor]" >> /etc/supervisord.conf
    echo "supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface" >> /etc/supervisord.conf
    echo "[supervisorctl]" >> /etc/supervisord.conf
    echo "serverurl=unix:///var/run//supervisor.sock ; use a unix:// URL  for a unix socket" >> /etc/supervisord.conf
    echo "[include]" >> /etc/supervisord.conf
    echo "files = /etc/supervisor/conf.d/*.conf" >> /etc/supervisord.conf

    echo "Creating supervisor subdirectories"

    mkdir /etc/supervisor
    mkdir /etc/supervisor/conf.d
    service $SUPERVISOR_SERVICE_NAME restart
fi
echo "Supervisor setup finished"

if [ -d /opt/sc_radio ]; then
    echo "Hosting web interface already installed"
else
    echo "Installing hosting Web interface..."
    mkdir /opt/sc_radio
    wget -O /tmp/sc_radio.tar.gz https://everestcast.com/dist/sc_radio$PYTHON3_VERSION.tar.gz
    tar -xzf /tmp/sc_radio.tar.gz --directory /opt/sc_radio
    rm -f /tmp/sc_radio.tar.gz
fi

cp $SRC_DIR/utils/etc/nginx/sc_radio.conf $NGINX_CONF_BASE/sc_radio.conf
'cp' -f $SRC_DIR/utils/etc/nginx/nginx.conf $NGINX_CONF_BASE/../nginx.conf
sed -i "s/user nginx/user $NGINX_USER/" $NGINX_CONF_BASE/../nginx.conf
rm -f /etc/nginx/sites-enabled/default
service nginx restart

cp $SRC_DIR/utils/etc/supervisor/sc_radio.conf $SUPERVISOR_CONF_BASE/sc_radio.conf
sed -i "s:MAIN_VHOST:$MAIN_VHOST:g" $NGINX_CONF_BASE/sc_radio.conf

cp $SRC_DIR/utils/etc/httpd/sc_radio.conf $APACHE_CONF_BASE/sc_radio.conf
sed -i "s:MAIN_VHOST:$MAIN_VHOST:g" $APACHE_CONF_BASE/sc_radio.conf

cp -f $SRC_DIR/utils/update_icecast_ssl.py /opt/bin/

service $APACHE_SERVICE_NAME restart

if [ $USING_VHOST == 1 ]; then
    read -r -p "Do you want to create Let's Encrypt SSL certificate for your domain? [y/N] " ssl
    if [[ "$ssl" =~ ^([yY][eE][sS]|[yY])+$ ]]
    # Ssl accepted
    then
        EMAIL_ADDRESS=
        while [[ $EMAIL_ADDRESS = "" ]]; do
            read -r -p "Enter your email address (required by Let's Encrypt SSL cenrtificate): " EMAIL_ADDRESS
        done
        if [ -z "$EMAIL_ADDRESS" ]; then
            echo "Email address is required"
            exit
        fi
        sed -i "s:EMAIL_ADDRESS:$EMAIL_ADDRESS:g" $APACHE_CONF_BASE/sc_radio.conf

        service $APACHE_SERVICE_NAME restart
        service iptables stop
        service firewalld stop

        certbot -n --agree-tos --email=$EMAIL_ADDRESS --authenticator webroot --installer apache --webroot-path /opt/sc_radio/static -d $MAIN_VHOST
        [ $? -eq 0 ] && echo "SSL certificates installed."
        [ $? -ne 0 ] && echo "SSL certificates installation failed!" && exit
        # sed -i -E s"/listen\s+([[:digit:]]+);/listen \1 ssl;/" $NGINX_CONF_BASE/sc_radio.conf
        # sed -i "/ssl/ s/# *//" $NGINX_CONF_BASE/sc_radio.conf
        sed -i "/server /,/charset/!b;//!d;/server /a \ listen $SC_PANEL_PORT ssl http2;\n\ server_name $MAIN_VHOST;\n\ ssl_certificate $SSL_FOLDER/live/$MAIN_VHOST/fullchain.pem;\n\ ssl_certificate_key $SSL_FOLDER/live/$MAIN_VHOST/privkey.pem;\n" $NGINX_CONF_BASE/sc_radio.conf

        cp $SRC_DIR/utils/update_icecast_ssl.py $SSL_FOLDER/renewal-hooks/deploy/
        cp -f /opt/bin/update_icecast_ssl.py $SSL_FOLDER/renewal-hooks/deploy/update_icecast_ssl.py

        chown root:sc_radios $SSL_FOLDER/archive
        chown root:sc_radios $SSL_FOLDER/live
        chmod 750 $SSL_FOLDER/archive
        chmod 750 $SSL_FOLDER/live
        $SSL_FOLDER/renewal-hooks/deploy/update_icecast_ssl.py
        SSL_DONE=1
    else
       echo "SSL setup skipped"
    fi

else
    USING_VHOST=0
fi


# Copy Shoutcast1 binary files
if [ -d /opt/shoutcast1 ]; then
    echo "Shoutcast V.1 already installed"
else
    echo "Installing ShoutCast V.1 binary"
    mkdir /opt/shoutcast1
    mkdir /opt/shoutcast1/bin
    wget -O /opt/shoutcast1/bin/sc_serv https://everestcast.com/dist/binaries/shoutcast1/bin/sc_serv
    chmod +x /opt/shoutcast1/bin/sc_serv
fi

# Copy Shoutcast2 binary files
if [ -d /opt/shoutcast2 ]; then
    echo "Shoutcast2 bin exists"
else
    echo "Installing ShoutCast2 binary"
    mkdir /opt/shoutcast2
    mkdir /opt/shoutcast2/bin
    wget -O /opt/shoutcast2/bin/sc_serv https://everestcast.com/dist/binaries/shoutcast2/bin/sc_serv
    wget -O /opt/shoutcast2/bin/sc_serv2.6 https://everestcast.com/dist/binaries/shoutcast2/bin/sc_serv2.6
    wget -O /opt/shoutcast2/bin/cacert.pem https://everestcast.com/dist/binaries/shoutcast2/bin/cacert.pem
    chmod +x /opt/shoutcast2/bin/sc_serv
    chmod +x /opt/shoutcast2/bin/sc_serv2.6
fi

# Icecast binary file
if [ -d /opt/icecast ]; then
    echo "Icecast bin exists"
else
    echo "Installing Icecast binary"
    mkdir /opt/icecast
    mkdir /opt/icecast/bin
    rm -f /opt/icecast/bin/icecast
    wget --no-check-certificate -O /opt/icecast/bin/icecast https://everestcast.com/dist/binaries/icecast/$BINARY_TARGET/icecast
    chmod +x /opt/icecast/bin/icecast

    #cp -f /usr/bin/icecast /opt/icecast/bin/
    #cp -f /usr/bin/icecast2 /opt/icecast/bin/icecast
fi

# Icecast-kh binary file
if [ -f /opt/icecast/bin/icecast-kh ]; then
    echo "Icecast-kh is already installed"
else
    echo "Downloading Icecast-kh..."
    wget --no-check-certificate -O /opt/icecast/bin/icecast-kh https://everestcast.com/dist/binaries/icecast/$BINARY_TARGET/icecast-kh
    chmod +x /opt/icecast/bin/icecast-kh
fi

# Copy icecast www files
if [ -d /opt/icecast/web ]; then
    echo "Icecast web files already there"
else
    echo "Installing Icecast web files"
    wget -O /tmp/icecast-files.tar.gz https://everestcast.com/dist/icecast-files.tar.gz
    tar -xzf /tmp/icecast-files.tar.gz --directory /opt/icecast
    rm -f /tmp/icecast-files.tar.gz
fi

# Install optional mp3s
if [ -d /opt/mp3 ]; then
    echo "Optional mp3s already there"
else
    echo "Copying system mp3s"
    mkdir /opt/mp3
    wget -O /opt/mp3/silence.mp3 https://everestcast.com/dist/mp3/silence.mp3
fi

# Setup databases
mysql -u root -p$MYSQL_PASS -h $BILLING_DB_HOST -e "CREATE DATABASE IF NOT EXISTS $BILLING_DB_NAME CHARACTER SET utf8 COLLATE utf8_general_ci;"
mysql -u root -p$MYSQL_PASS -h $BILLING_DB_HOST -e "CREATE USER $BILLING_DB_USER@$BILLING_DB_HOST IDENTIFIED BY '$BILLING_DB_PASS';"
mysql -u root -p$MYSQL_PASS -h $BILLING_DB_HOST -e "GRANT ALL PRIVILEGES ON $BILLING_DB_NAME.* TO $BILLING_DB_USER@$BILLING_DB_HOST;"

pip3 install -r /opt/sc_radio/requirements.txt
RETVAL=$?
[ $RETVAL -eq 0 ] && echo "Requirements installed."
[ $RETVAL -ne 0 ] && echo "Requirements installation failed!" && exit

chown sc_radio:sc_radios -R /opt/sc_radio
python3 /opt/sc_radio/manage.py migrate

if [ $SSL_DONE == 1 ]; then
    sed -i "s|http://localhost:8000|https://$MAIN_VHOST:$SC_PANEL_PORT|" /opt/sc_radio/static/_nuxt/*.js
else
    sed -i "s/localhost:8000/$MAIN_VHOST:$SC_PANEL_PORT/" /opt/sc_radio/static/_nuxt/*.js
fi

python3 /opt/sc_radio/manage.py create_admin $ADMIN_PASS $ADMIN_EMAIL
python3 /opt/sc_radio/manage.py setup_defaults


python3 /opt/sc_radio/manage.py set_licence sc

# License
if [ -z "$LICENSE_KEY" ]; then
    while [[ $LICENSE_KEY = "" ]]; do
        read -r -p "Please enter your Licence Key: " LICENSE_KEY
    done
fi

python3 /opt/sc_radio/manage.py set_licence $LICENSE_KEY
# License

# Setup SELinux
setsebool -P allow_ftpd_full_access=1
setsebool -P ftpd_connect_db 1
semanage port -a -t http_port_t  -p tcp $SC_PANEL_PORT
echo 0 > /sys/fs/selinux/enforce


echo "Setting up startup services"
if is_centos7; then
    # Autorun
    systemctl enable crond.service
    systemctl enable nginx
    systemctl enable mariadb
    systemctl enable ntpdate.service
    systemctl enable proftpd
    systemctl enable php-fpm

    # Disable iptables autoload
    systemctl disable firewalld.service
    systemctl disable iptables0
    chkconfig ip6tables off
    chkconfig iptables off
    service firewalld stop

    # Restart
    service crond restart
    service mariadb restart
    service php-fpm restart

    # Set php-fpm socket path
    sed -i 's/listen \= 127.0.0.1:9000/listen \= \/var\/run\/php-fpm.sock/' /etc/php-fpm.d/www.conf

elif is_ubuntu; then
    # Autorun
    systemctl enable cron.service
    systemctl enable nginx
    systemctl enable mysql
    systemctl enable ntp
    systemctl enable proftpd
    systemctl enable php7.4-fpm
    # Disable iptables autoload
    ufw disable

    # Restart
    service cron restart
    service mysql restart
    service php7.4-fpm restart

    # Set php-fpm socket path
    sed -i 's/listen \= \/run\/php\/php7.4-fpm.sock/listen \= \/var\/run\/php-fpm.sock/' /etc/php/7.4/fpm/pool.d/www.conf

    # Apache modules
    # a2enmod proxy
    a2enmod proxy_http
    a2enmod rewrite
    # a2enmod ssl
    rm -f /etc/apache2/sites-enabled/000-default.conf
fi

systemctl enable $SUPERVISOR_SERVICE_NAME
service $SUPERVISOR_SERVICE_NAME restart

systemctl enable $APACHE_SERVICE_NAME
service $APACHE_SERVICE_NAME restart

service nginx restart
supervisorctl restart sc_radio


if [ -f /usr/local/bin/radiopoint ]; then
    echo "Radio Service already installed"
else
    echo "Installing radio service binaries..."
    wget --no-check-certificate -O /usr/local/bin/radiopoint https://everestcast.com/dist/binaries/$BINARY_TARGET/radiopoint
    wget --no-check-certificate -O /usr/local/bin/content_indexer https://everestcast.com/dist/binaries/$BINARY_TARGET/content_indexer
    chmod +x /usr/local/bin/radiopoint
    chmod +x /usr/local/bin/content_indexer
fi

echo "Installing Loud Gain..."
rm -f /usr/local/bin/loudgain
wget --no-check-certificate -O /usr/local/bin/loudgain https://everestcast.com/dist/binaries/$BINARY_TARGET/loudgain
chmod +x /usr/local/bin/loudgain


rm -rf $MY_PWD/utils/

selinuxenabled
if [ $? -ne 0 ]
then
    echo "Selinux is [disabled]"
else
    echo "Selinux is [enabled], disabling"
    sed -i 's/enforcing/disabled/g' /etc/selinux/config /etc/selinux/config
    sed -i 's/permissive/disabled/g' /etc/selinux/config /etc/selinux/config
    echo "Make sure to reboot your server (type 'reboot') to disable SELinux"
fi
# Increase the maximum number of FS watchers via inotify to 32k
echo fs.inotify.max_user_watches=32768 | sudo tee -a /etc/sysctl.conf && sudo sysctl -p

# Generate main locales
locale-gen en_US.UTF-8
locale-gen bg_BG.UTF-8
locale-gen es_ES.UTF-8
locale-gen fr_FR.UTF-8
locale-gen ja_JP.UTF-8
locale-gen zh_CN.UTF-8
locale-gen it_IT.UTF-8
locale-gen ko_KR.UTF-8
locale-gen ru_RU.UTF-8
locale-gen zh_TW.UTF-8
locale-gen de_DE.UTF-8

update-locale LANG="en_US.UTF-8" LANGUAGE="en_US"

# Update version number
VERSION=`curl -s 'https://everestcast.com/dist/changelog.json' | python3 -c "import sys,json; print(list(json.load(sys.stdin).keys())[0])"`
if [ -z "$VERSION" ]
then
      echo "Failed to load version number"
else
    echo "Software Version $VERSION installation is complete"
    mysql -u root -p$MYSQL_PASS -e "UPDATE license SET version='$VERSION';" sc_billing;
fi

echo "Installation is complete, you can now sign in to the control panel:"
if [ $SSL_DONE == 1 ]; then
    echo "URL: https://$MAIN_VHOST:$SC_PANEL_PORT"
else
    echo "URL: http://$MAIN_VHOST:$SC_PANEL_PORT"
fi
echo
echo "Username: admin"
echo "Password: $ADMIN_PASS"

