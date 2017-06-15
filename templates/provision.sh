#!/usr/bin/env bash
set -e

echo "--> Grabbing IPs"
PRIVATE_IP=$(curl --silent http://169.254.169.254/latest/meta-data/local-ipv4)
PUBLIC_IP=$(curl --silent http://169.254.169.254/latest/meta-data/public-ipv4)

echo "--> Adding helper for IP retrieval"
sudo tee /etc/profile.d/ips.sh > /dev/null <<EOF
function private-ip {
  echo "$PRIVATE_IP"
}

function public-ip {
  echo "$PUBLIC_IP"
}
EOF

echo "--> Formatting disk"
sudo mkfs.xfs -K /dev/xvdb
sudo mkdir -p /mnt
sudo mount -o discard /dev/xvdb /mnt
sudo tee -a /etc/fstab > /dev/null <<"EOF"
/dev/xvdb   /mnt   xfs    defaults,nofail,discard   0   2
EOF

function ssh-apt {
  sudo DEBIAN_FRONTEND=noninteractive apt-get -yqq \
    --force-yes \
    -o Dpkg::Use-Pty=0 \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    "$@"
}

echo "--> Installing common dependencies"
ssh-apt dist-upgrade
ssh-apt update
ssh-apt upgrade
ssh-apt install \
  apt-transport-https \
  build-essential \
  ca-certificates \
  curl \
  emacs \
  git \
  jq \
  linux-image-extra-virtual \
  software-properties-common \
  unzip \
  vim \
  wget
ssh-apt clean
ssh-apt autoclean
ssh-apt autoremove

echo "--> Disabling checkpoint"
sudo tee /etc/profile.d/checkpoint.sh > /dev/null <<"EOF"
export CHECKPOINT_DISABLE=1
EOF
source /etc/profile.d/checkpoint.sh

echo "--> Setting hostname"
echo "127.0.0.1  ${hostname}" | sudo tee -a /etc/hosts
echo "${hostname}" | sudo tee /etc/hostname
sudo hostname -F /etc/hostname

echo "--> Creating user"
sudo useradd "${username}" \
  --shell /bin/bash \
  --create-home
sudo tee "/etc/sudoers.d/${username}" > /dev/null <<"EOF"
%${username} ALL=NOPASSWD:ALL
EOF
sudo chmod 0440 "/etc/sudoers.d/${username}"
sudo usermod -a -G sudo "${username}"
sudo mkdir -p "/home/${username}/.ssh"
sudo cp "/home/ubuntu/.ssh/authorized_keys" "/home/${username}/.ssh/authorized_keys"
sudo mkdir -p "/home/${username}/.cache"
sudo touch "/home/${username}/.cache/motd.legal-displayed"
sudo touch "/home/${username}/.sudo_as_admin_successful"
sudo chown -R "${username}:${username}" "/home/${username}"

echo "--> Configuring MOTD"
sudo rm -rf /etc/update-motd.d/*
sudo tee /etc/update-motd.d/00-hashicorp > /dev/null <<"EOF"
#!/bin/sh

echo "Welcome to the HashiCorp demo! Have a great day!"
EOF
sudo chmod +x /etc/update-motd.d/00-hashicorp
sudo run-parts /etc/update-motd.d/

echo "--> Ignoring LastLog"
sudo sed -i'' 's/PrintLastLog\ yes/PrintLastLog\ no/' /etc/ssh/sshd_config
sudo systemctl restart ssh

echo "--> Instaling postgresql"
curl -s https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
sudo apt-get -yqq update
sudo apt-get -yqq install postgresql postgresql-contrib
sudo tee /etc/postgresql/*/main/pg_hba.conf > /dev/null <<"EOF"
local   all             postgres                                trust
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
EOF
sudo systemctl restart postgresql

echo "--> Creating database myapp"
psql -U postgres -c 'CREATE DATABASE myapp;'

echo "--> Setting psql prompt"
sudo tee "/home/${username}/.psqlrc" > /dev/null <<"EOF"
\set QUIET 1
\set COMP_KEYWORD_CASE upper
\set PROMPT1 '%n > '

\echo 'Welcome to PostgreSQL!'
\echo 'Type \\q to exit.\n'
EOF

echo "--> Ensuring .psqlrc is owned by ${username}"
sudo chown "${username}:${username}" "/home/${username}/.psqlrc"

echo "--> Fetching Vault"
pushd /tmp
curl \
  --silent \
  --location \
  --output vault.zip \
  "${vault_url}"
unzip -qq vault.zip
sudo mv vault /usr/local/bin/vault
sudo chmod +x /usr/local/bin/vault
rm -rf vault.zip
popd

echo "--> Writing configuration"
sudo mkdir -p /mnt/vault
sudo mkdir -p /mnt/vault/data
sudo mkdir -p /etc/vault.d
sudo tee /etc/vault.d/config.hcl > /dev/null <<EOF
ui           = true
cluster_name = "vault-demo"

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = 1
}

storage "file" {
  path = "/mnt/vault/data"
}
EOF

echo "--> Writing profile"
sudo tee /etc/profile.d/vault.sh > /dev/null <<"EOF"
alias vualt="vault"
export VAULT_ADDR="http://127.0.0.1:8200"
EOF
source /etc/profile.d/vault.sh

echo "--> Generating systemd unit"
sudo tee /etc/systemd/system/vault.service > /dev/null <<"EOF"
[Unit]
Description=Vault Server
Requires=network-online.target
After=network.target

[Service]
Environment=GOMAXPROCS=8
Environment="VAULT_ADDR=http://127.0.0.1:8200"
Restart=on-failure
ExecStart=/usr/local/bin/vault server -config="/etc/vault.d/config.hcl"
ExecStartPost=/bin/bash -c "sleep 5 && /usr/local/bin/vault unseal $(cat /var/log/vault.log | grep -i 'Unseal Key' | cut -d':' -f2 | tr -d ' ') || true"
ExecReload=/bin/kill -HUP $MAINPID
KillSignal=SIGINT

[Install]
WantedBy=multi-user.target
EOF

echo "--> Starting vault"
sudo systemctl enable vault
sudo systemctl start vault
sleep 5

echo "--> Initializing vault"
vault init -key-shares=1 -key-threshold=1 | sudo tee /var/log/vault.log

echo "--> Unsealing vault"
/usr/local/bin/vault unseal "$(cat /var/log/vault.log | grep -i 'Unseal Key' | cut -d':' -f2 | tr -d ' ')"

echo "--> Authenticating to Vault"
vault auth "$(cat /var/log/vault.log | grep -i 'Root token' | cut -d':' -f2 | tr -d ' ')"

echo "--> Creating a rememberable root token"
vault token-create -orphan -id="root"

echo "--> Configuring transit"
vault mount transit
vault write -f transit/keys/my-app

echo "--> Configuring database"
vault mount database
vault write database/config/postgresql \
  plugin_name="postgresql-database-plugin" \
  connection_url="postgresql://postgres@localhost:5432/myapp" \
  allowed_roles="readonly"

vault write database/roles/readonly \
  db_name="postgresql" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";"

echo "--> Configuring AWS"
vault mount aws
vault write aws/config/root \
  access_key="${aws_access_key}" \
  secret_key="${aws_secret_key}" \
  region="${aws_region}"

vault write aws/roles/user policy="$(cat <<-EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "iam:*",
      "Resource": "*"
    }
  ]
}
EOF
)"

echo "--> Configuring PKI"
vault mount pki
vault mount-tune -max-lease-ttl="87600h" pki
vault write pki/root/generate/internal \
  common_name="sethvargo.com" \
  ttl="87600h"
vault write pki/config/urls \
  issuing_certificates="http://127.0.0.1:8200/v1/pki/ca" \
  crl_distribution_points="http://127.0.0.1:8200/v1/pki/crl"
vault write pki/roles/my-website \
  allowed_domains="sethvargo.com" \
  allow_subdomains="true" \
  max_ttl="72h"

echo "--> Configuring TOTP"
vault mount totp
vault write totp/keys/demo \
  url="otpauth://totp/Vault:seth@sethvargo.com?secret=Y64VEVMBTSXCYIWRSHRNDZW62MPGVU2G&issuer=Vault"

echo "--> Install nginx"
sudo apt-get -yqq install nginx

echo "--> Writing nginx configuration"
sudo tee "/etc/nginx/sites-enabled/default" > /dev/null <<"EOF"
server {
  listen 80;
  server_name ${hostname};

  add_header X-Frame-Options DENY;
  add_header X-Content-Type-Options nosniff;

  location / {
    proxy_pass http://127.0.0.1:8200/;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }
}
EOF

echo "--> Restarting nginx"
sudo systemctl restart nginx

echo "--> Rebooting"
sudo systemctl reboot
