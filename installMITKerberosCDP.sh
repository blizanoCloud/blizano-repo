#!/bin/bash
# PENDING TO INCLUDE https://docs.cloudera.com/cdp-private-cloud-base/7.1.8/security-kerberos-authentication/topics/cm-security-kerberos-enabling-step3-cm-principal.html#ariaid-title3 

# Variables
LOCAL_KRB5_CONF="/etc/krb5.conf"
LOCAL_HOSTNAME=$(hostname -f)
REALM="COELAB.CLOUDERA.COM"
ROOT_PASSWORD="your_root_password"  # Replace with root password for remote servers

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "WARN: This script must be run as root. Exiting."
    exit 1
fi

# Function to fix repository configuration on remote servers
fix_remote_repo_config() {
    local server="$1"
    echo "Fixing repository configurations on $server..."
    sshpass -p "$ROOT_PASSWORD" ssh -o StrictHostKeyChecking=no root@$server "
        sed -i.bak 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
        sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*
        yum clean all && yum makecache
    " && echo "Repository configuration fixed on $server." || echo "Failed to fix repositories on $server."
}

# Function to install sshpass
install_sshpass() {
    echo "Installing sshpass..."
    if ! command -v sshpass &> /dev/null; then
        yum install -y sshpass --disablerepo=cloudera-manager && echo "sshpass installed successfully." || echo "Failed to install sshpass."
    else
        echo "sshpass is already installed."
    fi
}

# Function to install MIT Kerberos on remote servers
install_kerberos() {
    local server="$1"
    echo "Installing MIT Kerberos on $server..."
    fix_remote_repo_config "$server"
    sshpass -p "$ROOT_PASSWORD" ssh -o StrictHostKeyChecking=no root@$server "yum install -y krb5-server krb5-workstation" \
        && echo "MIT Kerberos installed on $server." || echo "Failed to install MIT Kerberos on $server."
}

# Function to initialize Kerberos database
initialize_kerberos_db() {
    echo "Initializing Kerberos database..."
    if [ ! -f /var/kerberos/krb5kdc/principal ]; then
        echo "No Kerberos database found. Creating it now..."
        kdb5_util create -s <<EOF
blizano
blizano
EOF
    else
        echo "Kerberos database already exists."
    fi
}

# Function to configure krb5.conf
configure_krb5_conf() {
    local server="$1"
    echo "Configuring krb5.conf on $server..."
    sshpass -p "$ROOT_PASSWORD" ssh -o StrictHostKeyChecking=no root@$server "
        cat <<EOF | sudo tee /etc/krb5.conf > /dev/null
[libdefaults]
    default_realm = $REALM
    dns_lookup_realm = false
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
    rdns = false
    allow_weak_crypto = true
    default_tgs_enctypes = aes256-cts aes128-cts des-cbc-crc des-cbc-md5
    default_tkt_enctypes = aes256-cts aes128-cts des-cbc-crc des-cbc-md5
    krb_enc_types = aes256-cts aes128-cts des-cbc-crc des-cbc-md5
    default_ccache_name = FILE:/tmp/krb5cc_%{uid}

[realms]
    $REALM = {
        kdc = $LOCAL_HOSTNAME
        admin_server = $LOCAL_HOSTNAME
    }

[domain_realm]
    .$REALM = $REALM
    $REALM = $REALM
EOF
        systemctl restart krb5kdc
        systemctl restart kadmin
    " && echo "krb5.conf configured on $server." || echo "Failed to configure krb5.conf on $server."
}

# Function to create admin/admin principal
create_admin_principal() {
    echo "Creating admin/admin principal..."
    kadmin.local -q "addprinc -pw blizano admin/admin" && echo "admin/admin created successfully!" || echo "Failed to create admin/admin user."
    systemctl restart krb5kdc
    systemctl restart kadmin
}

# Function to test Kerberos authentication
test_kinit() {
    echo "Testing kinit for admin/admin..."
    echo "blizano" | kinit admin/admin && echo "kinit successful." || echo "kinit failed."
}

# Main menu
show_menu() {
    echo "Select an option:"
    echo "1) Install sshpass"
    echo "2) Install MIT Kerberos"
    echo "3) Configure krb5.conf on all servers"
    echo "4) Initialize Kerberos and Test"
    echo "5) Perform all tasks"
    echo "6) Exit"
    read -p "Enter your choice [1-6]: " choice
    return $choice
}

# Main script logic
main() {
    while true; do
        show_menu
        choice=$?
        case $choice in
            1)
                install_sshpass
                ;;
            2)
                read -p "Enter a comma-separated list of servers: " server_list
                IFS=',' read -ra SERVERS <<< "$server_list"
                for server in "${SERVERS[@]}"; do
                    install_kerberos "$server"
                done
                ;;
            3)
                read -p "Enter a comma-separated list of servers: " server_list
                IFS=',' read -ra SERVERS <<< "$server_list"
                for server in "${SERVERS[@]}"; do
                    configure_krb5_conf "$server"
                done
                ;;
            4)
                initialize_kerberos_db
                create_admin_principal
                test_kinit
                ;;
            5)
                install_sshpass
                read -p "Enter a comma-separated list of servers: " server_list
                IFS=',' read -ra SERVERS <<< "$server_list"
                for server in "${SERVERS[@]}"; do
                    install_kerberos "$server"
                    configure_krb5_conf "$server"
                done
                initialize_kerberos_db
                create_admin_principal
                test_kinit
                ;;
            6)
                echo "Exiting script."
                break
                ;;
            *)
                echo "Invalid option. Please try again."
                ;;
        esac
    done
}

# Run the main function
main
