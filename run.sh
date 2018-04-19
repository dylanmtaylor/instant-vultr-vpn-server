#!/bin/bash
# Pre-reqs: have openvpn, sshpass and curl are installed on a 64-bit x86 Linux system.
# This script only works with CentOS VPS systems as I'm too lazy to port it.

# Prior to running, execute export VULTR_API_KEY=[YOUR_API_KEY_HERE]

# Install glide and setup go locally
export GOPATH=`pwd`
export GOBIN=$GOPATH/go/bin
mkdir -p $GOPATH/bin
export PATH="$PATH:$GOBIN/"
echo PATH=$PATH
export DATE=$(date +%s)
export ROOT_PW=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1  | tr -d '[:space:]')
curl https://glide.sh/get | sh

# Get Vultr CLI
go get github.com/JamesClonk/vultr
vultr version

# Create a new startup script to setup the server
# This is based on Nyr's OpenVPN installer except dramatically simplified and with many options chosen for you.
cat << EOF > temp_script
#!/bin/bash
echo User data executed > /root/success
OS=centos
GROUPNAME=nobody
RCLOCAL='/etc/rc.d/rc.local'
ROOT_PW=$ROOT_PW
PROTOCOL=udp
PORT=1194
echo \$ROOT_PW | passwd root --stdin # Set root password to our random value

IP=\$(ip addr | grep 'inet' | grep -v inet6 | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | grep -o -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1)
if [[ "\$IP" = "" ]]; then
		IP=\$(wget -4qO- "http://whatismyip.akamai.com/")
fi

newclient () {
	# Generates the custom client.ovpn
	cp /etc/openvpn/client-common.txt ~/\$1.ovpn
	echo "<ca>" >> ~/\$1.ovpn
	cat /etc/openvpn/easy-rsa/pki/ca.crt >> ~/\$1.ovpn
	echo "</ca>" >> ~/\$1.ovpn
	echo "<cert>" >> ~/\$1.ovpn
	cat /etc/openvpn/easy-rsa/pki/issued/\$1.crt >> ~/\$1.ovpn
	echo "</cert>" >> ~/\$1.ovpn
	echo "<key>" >> ~/\$1.ovpn
	cat /etc/openvpn/easy-rsa/pki/private/\$1.key >> ~/\$1.ovpn
	echo "</key>" >> ~/\$1.ovpn
	echo "<tls-auth>" >> ~/\$1.ovpn
	cat /etc/openvpn/ta.key >> ~/\$1.ovpn
	echo "</tls-auth>" >> ~/\$1.ovpn
}

yum -y install epel-release yum-utils; yum -y install openvpn iptraf-ng iftop htop fail2ban iotop iptables openssl wget ca-certificates

export CLIENT="openvpn_cert"

if [[ -d /etc/openvpn/easy-rsa/ ]]; then
  rm -rf /etc/openvpn/easy-rsa/
fi
# Get easy-rsa
wget -O ~/EasyRSA-3.0.4.tgz "https://github.com/OpenVPN/easy-rsa/releases/download/v3.0.4/EasyRSA-3.0.4.tgz"
tar xzf ~/EasyRSA-3.0.4.tgz -C ~/
mv ~/EasyRSA-3.0.4/ /etc/openvpn/
mv /etc/openvpn/EasyRSA-3.0.4/ /etc/openvpn/easy-rsa/
chown -R root:root /etc/openvpn/easy-rsa/
rm -rf ~/EasyRSA-3.0.4.tgz
cd /etc/openvpn/easy-rsa/
# Create the PKI, set up the CA, the DH params and the server + client certificates
./easyrsa init-pki
./easyrsa --batch build-ca nopass
./easyrsa gen-dh
./easyrsa build-server-full server nopass
./easyrsa build-client-full \$CLIENT nopass
EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
# Move the stuff we need
cp pki/ca.crt pki/private/ca.key pki/dh.pem pki/issued/server.crt pki/private/server.key pki/crl.pem /etc/openvpn
# CRL is read with each client connection, when OpenVPN is dropped to nobody
chown nobody:\$GROUPNAME /etc/openvpn/crl.pem
# Generate key for tls-auth
openvpn --genkey --secret /etc/openvpn/ta.key
# Generate server.conf
echo "port \$PORT
proto \$PROTOCOL
dev tun
sndbuf 0
rcvbuf 0
ca ca.crt
cert server.crt
key server.key
dh dh.pem
auth SHA512
tls-auth ta.key 0
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt" > /etc/openvpn/server.conf
echo 'push "redirect-gateway def1 bypass-dhcp"' >> /etc/openvpn/server.conf
echo 'push "dhcp-option DNS 1.1.1.1"' >> /etc/openvpn/server.conf
echo 'push "dhcp-option DNS 1.0.0.1"' >> /etc/openvpn/server.conf
echo "keepalive 10 120
cipher AES-256-CBC
comp-lzo
user nobody
group \$GROUPNAME
persist-key
persist-tun
status openvpn-status.log
verb 3
crl-verify crl.pem" >> /etc/openvpn/server.conf
# Enable net.ipv4.ip_forward for the system
sed -i '/\<net.ipv4.ip_forward\>/c\net.ipv4.ip_forward=1' /etc/sysctl.conf
if ! grep -q "\<net.ipv4.ip_forward\>" /etc/sysctl.conf; then
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
# Avoid an unneeded reboot
echo 1 > /proc/sys/net/ipv4/ip_forward
if pgrep firewalld; then
  # Using both permanent and not permanent rules to avoid a firewalld
  # reload.
  # We don't use --add-service=openvpn because that would only work with
  # the default port and protocol.
  firewall-cmd --zone=public --add-port=\$PORT/\$PROTOCOL
  firewall-cmd --zone=trusted --add-source=10.8.0.0/24
  firewall-cmd --permanent --zone=public --add-port=\$PORT/\$PROTOCOL
  firewall-cmd --permanent --zone=trusted --add-source=10.8.0.0/24
  # Set NAT for the VPN subnet
  firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to \$IP
  firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to \$IP
else
  # Needed to use rc.local with some systemd distros
  if [[ "\$OS" = 'debian' && ! -e \$RCLOCAL ]]; then
    echo '#!/bin/sh -e
exit 0' > \$RCLOCAL
  fi
  chmod +x \$RCLOCAL
  # Set NAT for the VPN subnet
  iptables -t nat -A POSTROUTING -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to \$IP
  sed -i "1 a\iptables -t nat -A POSTROUTING -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to \$IP" \$RCLOCAL
  if iptables -L -n | grep -qE '^(REJECT|DROP)'; then
    # If iptables has at least one REJECT rule, we asume this is needed.
    # Not the best approach but I can't think of other and this shouldn't
    # cause problems.
    iptables -I INPUT -p \$PROTOCOL --dport \$PORT -j ACCEPT
    iptables -I FORWARD -s 10.8.0.0/24 -j ACCEPT
    iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
    sed -i "1 a\iptables -I INPUT -p \$PROTOCOL --dport \$PORT -j ACCEPT" \$RCLOCAL
    sed -i "1 a\iptables -I FORWARD -s 10.8.0.0/24 -j ACCEPT" \$RCLOCAL
    sed -i "1 a\iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" \$RCLOCAL
  fi
fi
# If SELinux is enabled and a custom port or TCP was selected, we need this
if hash sestatus 2>/dev/null; then
  if sestatus | grep "Current mode" | grep -qs "enforcing"; then
    if [[ "\$PORT" != '1194' || "\$PROTOCOL" = 'tcp' ]]; then
      # semanage isn't available in CentOS 6 by default
      if ! hash semanage 2>/dev/null; then
        yum install policycoreutils-python -y
      fi
      semanage port -a -t openvpn_port_t -p \$PROTOCOL \$PORT
    fi
  fi
fi
# And finally, restart OpenVPN
if [[ "\$OS" = 'debian' ]]; then
  # Little hack to check for systemd
  if pgrep systemd-journal; then
    systemctl restart openvpn@server.service
  else
    /etc/init.d/openvpn restart
  fi
else
  if pgrep systemd-journal; then
    systemctl restart openvpn@server.service
    systemctl enable openvpn@server.service
  else
    service openvpn restart
    chkconfig openvpn on
  fi
fi
# Try to detect a NATed connection and ask about it to potential LowEndSpirit users
EXTERNALIP=\$(wget -4qO- "http://whatismyip.akamai.com/")
if [[ "\$IP" != "\$EXTERNALIP" ]]; then
  echo ""
  echo "Looks like your server could be behind a NAT!"
  echo ""
  echo "If your server is behind a NAT, I need to know the public IP or hostname"
  echo "If that's not the case, just ignore this and leave the next field blank"
  read -p "Public IP: " -e PUBLICIP
  if [[ "\$PUBLICIP" != "" ]]; then
    IP=\$PUBLICIP
  fi
fi
# client-common.txt is created so we have a template to add further users later
echo "client
dev tun
proto \$PROTOCOL
sndbuf 0
rcvbuf 0
remote \$IP \$PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA512
cipher AES-256-CBC
comp-lzo
setenv opt block-outside-dns
key-direction 1
verb 3" > /etc/openvpn/client-common.txt
newclient "\$CLIENT"
yum -y update # Security is important, but running this at the beginning slows things down
EOF
vultr script create --type="boot" --name="openvpn_$DATE" --file="temp_script"

sleep 3 # Wait for script to save; yes, this is a real race condition

# Figure out which script we're Using
SCRIPT_ID=$(vultr scripts | grep openvpn_$DATE | cut -f1)
echo Using $SCRIPT_ID ...

# Initialize a new server with the new startup script
vultr server create --name="openvpn_$DATE" --plan=201 --os=167 --hostname="openvpn" --script=$SCRIPT_ID
echo "Waiting a bit to give the VPS time to come online"
sleep 30 # give the server time to get assigned an IP address. If we don't wait long enough here, the server breaks
IP=$(vultr server list | grep openvpn_$DATE | cut -f3  | tr -d '[:space:]')
echo "*** VPS IP ADDRESS: $IP"
echo "*** VPS ROOT PASSWORD: $ROOT_PW"

echo "Waiting 3 minutes to let the server finish generating the certificates"
sleep 180
rm -f openvpn_cert.ovpn
sshpass -p \"$ROOT_PW\" scp root@$IP:/root/openvpn_cert.ovpn .

# Cleanup startup script
vultr script delete $(vultr script list | grep openvpn_$DATE | cut -f1)

echo "If everything worked correctly, openvpn_cert.ovpn can now be used to connect to the server"
echo "To troubleshoot, try checking /tmp/firstboot.log on the server."
echo "To connect, run this: sudo openvpn openvpn_cert.ovpn"
