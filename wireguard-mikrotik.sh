#!/usr/bin/env bash

BLUE='\033[0;34m'
NC='\033[0m'
INFO="${BLUE}[i]${NC}"

# Converts an IPv4 address to an integer
function ip_to_int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

function checkOS() {

	#? Check OS version
	if [[ -e /etc/debian_version ]]; then
			# shellcheck source=/dev/null
		source /etc/os-release
		OS="${ID}" # debian or ubuntu
		if [[ ${ID} == "debian" || ${ID} == "raspbian" ]]; then
			if [[ ${VERSION_ID} -lt 10 ]]; then
				echo "Your version of Debian (${VERSION_ID}) is not supported. Please use Debian 10 Buster or later"
				exit 95
			fi
			OS=debian #* overwrite if raspbian
		fi
	elif [[ -e /etc/fedora-release ]]; then
        # shellcheck source=/dev/null
		source /etc/os-release
		OS="${ID}"
	elif [[ -e /etc/centos-release ]]; then
        # shellcheck source=/dev/null
		source /etc/os-release
		OS=centos
	elif [[ -e /etc/oracle-release ]]; then
        # shellcheck source=/dev/null
		source /etc/os-release
		OS=oracle
	elif [[ -e /etc/arch-release ]]; then
		OS=arch
	elif [[ "$(uname -s)" == "Darwin" ]]; then
    OS=macos
	else
		echo "Looks like you aren't running this installer on a Debian, Ubuntu, Fedora, CentOS, Oracle or Arch Linux system"
		exit 95
	fi
	export OS
}

function installWireGuard() {

	#? Check root user
	if [[ "${EUID}" -ne 0 ]] && [[ "${OS}" != "macos" ]]; then
		echo ""
		echo "You need to run this script as root"
		echo ""
		exit 13
	fi

	#? Install WireGuard tools and module
	if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' && ${VERSION_ID} -gt 10 ]]; then
		apt-get update
		apt-get install -y wireguard qrencode
	elif [[ ${OS} == 'debian' ]]; then
		if ! grep -rqs "^deb .* buster-backports" /etc/apt/; then
			echo "deb http://deb.debian.org/debian buster-backports main" >/etc/apt/sources.list.d/backports.list
			apt-get update
		fi
		apt update
		apt-get install -y qrencode
		apt-get install -y -t buster-backports wireguard
	elif [[ ${OS} == 'fedora' ]]; then
		if [[ ${VERSION_ID} -lt 32 ]]; then
			dnf install -y dnf-plugins-core
			dnf copr enable -y jdoss/wireguard
			dnf install -y wireguard-dkms
		fi
		dnf install -y wireguard-tools qrencode
	elif [[ ${OS} == 'centos' ]]; then
		yum -y install epel-release elrepo-release
		if [[ ${VERSION_ID} -eq 7 ]]; then
			yum -y install yum-plugin-elrepo
		fi
		yum -y install kmod-wireguard wireguard-tools qrencode
	elif [[ ${OS} == 'oracle' ]]; then
		dnf install -y oraclelinux-developer-release-el8
		dnf config-manager --disable -y ol8_developer
		dnf config-manager --enable -y ol8_developer_UEKR6
		dnf config-manager --save -y --setopt=ol8_developer_UEKR6.includepkgs='wireguard-tools*'
		dnf install -y wireguard-tools qrencode
	elif [[ ${OS} == 'arch' ]]; then
		pacman -Sq --needed --noconfirm wireguard-tools qrencode
	elif [[ ${OS} == 'macos' ]]; then
    if ! command -v brew &> /dev/null
    then
			echo ""
			echo "Brew is not installed. Please install it and run this script again."
			echo "https://brew.sh/"
			exit 1
    fi
    brew install wireguard-tools qrencode
	fi
	echo ""
	echo "The installation is complete. Now you need to re-run the script with user access rights (not root)."
	echo ""
	exit 0
}

function installCheck() {
	if ! command -v wg &> /dev/null
	then
		echo "You must have \"wireguard-tools\" and \"qrencode\" installed."
		read -n1 -r -p "Press any key to continue and install needed packages..."
		installWireGuard
	fi
}

function serverName() {
    until [[ ${SERVER_WG_NIC} =~ ^[a-zA-Z0-9_]+$ && ${#SERVER_WG_NIC} -lt 16 && ! ${SERVER_WG_NIC} =~ - ]]; do
        echo "Tell me a name for the server WireGuard interface. ('wg0' is used by default, no '-' allowed)"
        read -rp "WireGuard interface name (server name): " -e SERVER_WG_NIC
        SERVER_WG_NIC=${SERVER_WG_NIC:-wg0}
        if [[ ${SERVER_WG_NIC} =~ - ]]; then
            echo "Server name must not contain '-' characters."
        fi
    done
}

function installQuestions() {
	echo "I need to ask you a few questions before starting the setup."
	echo "You can leave the default options and just press enter if you are ok with them."
	echo ""

	# Ask if IPv6 should be enabled
	while true; do
		read -rp "Enable IPv6 for this server? [Y/n]: " -e ENABLE_IPV6
		ENABLE_IPV6=${ENABLE_IPV6,,} # to lowercase
		if [[ -z "$ENABLE_IPV6" || "$ENABLE_IPV6" == "y" || "$ENABLE_IPV6" == "yes" ]]; then
			SERVER_ENABLE_IPV6="yes"
			break
		elif [[ "$ENABLE_IPV6" == "n" || "$ENABLE_IPV6" == "no" ]]; then
			SERVER_ENABLE_IPV6="no"
			break
		else
			echo "Please answer yes or no."
		fi
	done

	# Detect public IPv4 or IPv6 address and pre-fill for the user
	SERVER_PUB_IP=$(host myip.opendns.com resolver1.opendns.com | grep -oE 'has address [0-9.]+' | cut -d ' ' -f3)
	echo "Your public IPv4 address is ${SERVER_PUB_IP}"
	if [[ -z ${SERVER_PUB_IP} ]]; then
		# Detect public IPv6 address
		if [[ ${OS} == "macos" ]]; then
			SERVER_PUB_IP=$(ifconfig | grep -A4 'en0:' | grep 'inet6' | awk '{print $2}')
		else
			SERVER_PUB_IP=$(ip -6 addr | sed -ne 's|^.* inet6 \([^/]*\)/.* scope global.*$|\1|p' | head -1)
		fi
	fi

	while true; do
    read -rp "Enter IPv4, IPv6, or domain name for public address [default used ${SERVER_PUB_IP}]: " -e USER_INPUT_SERVER_PUB_IP
    SERVER_PUB_IP=${USER_INPUT_SERVER_PUB_IP:-$SERVER_PUB_IP}
    # Validate IPv4
    if [[ ${SERVER_PUB_IP} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      break
    # Validate IPv6
    elif [[ ${SERVER_PUB_IP} =~ ^[0-9a-fA-F:]+:[0-9a-fA-F:]*$ ]]; then
      SERVER_PUB_IP="[${SERVER_PUB_IP}]"
      break
    # Validate domain name (RFC 1035, basic check)
    elif [[ ${SERVER_PUB_IP} =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
      break
    else
      echo "Invalid input. Please enter a valid IPv4, IPv6, or domain name."
    fi
	done

	# Ask for server's WireGuard IPv4 and subnet
	while true; do
		read -rp "Enter the server's WireGuard IPv4 address with subnet (e.g. 192.168.10.254/23): " -e SERVER_WG_IPV4_CIDR
		if [[ $SERVER_WG_IPV4_CIDR =~ ^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\/(3[0-2]|[12]?[0-9])$ ]]; then
			SERVER_WG_IPV4="${SERVER_WG_IPV4_CIDR%/*}"
			SERVER_WG_SUBNET="${SERVER_WG_IPV4_CIDR#*/}"
			break
		else
			echo "Invalid format. Please enter in the form x.x.x.x/yy, with a valid IPv4 and subnet 0-32."
		fi
	done

	# Only ask for IPv6 if enabled
	if [[ "$SERVER_ENABLE_IPV6" == "yes" ]]; then
		until [[ ${SERVER_WG_IPV6} =~ ^([a-f0-9]{1,4}:){3,4}: ]]; do
			if [[ ${OS} == 'macos' ]]; then
				SERVER_WG_IPV6="fd42:$(jot -r 1 10 90):$(jot -r 1 10 90)::1"
				read -rp "Server's WireGuard IPv6 [default used ${SERVER_WG_IPV6}]: " -e USER_INPUT_SERVER_WG_IPV6
				SERVER_WG_IPV6=${USER_INPUT_SERVER_WG_IPV6:-$SERVER_WG_IPV6}
			else
				read -rp "Server's WireGuard IPv6: " -e -i fd42:"$(shuf -i 10-90 -n 1)":"$(shuf -i 10-90 -n 1)"::1 SERVER_WG_IPV6
			fi
		done
	else
		SERVER_WG_IPV6=""
	fi

	RANDOM_PORT=$(shuf -i 49152-65535 -n1)
	until [[ ${SERVER_PORT} =~ ^[0-9]+$ ]] && [ "${SERVER_PORT}" -ge 1 ] && [ "${SERVER_PORT}" -le 65535 ]; do
		if [[ ${OS} == 'macos' ]]; then
			read -rp "Server's WireGuard port [1-65535] [default ${RANDOM_PORT}]: " -e USER_INPUT_SERVER_PORT
			SERVER_PORT=${USER_INPUT_SERVER_PORT:-$RANDOM_PORT}
		else
			read -rp "Server's WireGuard port [1-65535]: " -e -i "${RANDOM_PORT}" SERVER_PORT
		fi
	done

	# Ask what kind of server is needed
    echo "What kind of server do you need?"
    echo "  1) Route all traffic (AllowedIPs: 0.0.0.0/0)"
    echo "  2) Route subnet only (AllowedIPs: <server subnet, e.g. 192.168.2.0/24>)"
    echo "  3) Route multiple subnets (AllowedIPs: <subnet1, e.g. 192.168.2.0/24>, <subnet2, e.g. 192.168.100.0/24>)"
    until [[ $SERVER_ALLOWED_IPS_CHOICE =~ ^[1-3]$ ]]; do
        read -rp "Select an option [1-3]: " SERVER_ALLOWED_IPS_CHOICE
    done
    case $SERVER_ALLOWED_IPS_CHOICE in
        1)
            SERVER_ALLOWED_IPS="0.0.0.0/0"
            # Ask for DNS only if routing all traffic
            until [[ ${CLIENT_DNS_1} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
                if [[ ${OS} == 'macos' ]]; then
                    CLIENT_DNS_1='94.140.14.14'
                    read -rp "First DNS resolver to use for the clients [default ${CLIENT_DNS_1}]: " -e USER_INPUT_CLIENT_DNS_1
                    CLIENT_DNS_1=${USER_INPUT_CLIENT_DNS_1:-$CLIENT_DNS_1}
                else
                    read -rp "First DNS resolver to use for the clients: " -e -i 94.140.14.14 CLIENT_DNS_1
                fi
            done
            until [[ ${CLIENT_DNS_2} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
                if [[ ${OS} == 'macos' ]]; then
                    CLIENT_DNS_DEF_2='94.140.15.15'
                    read -rp "Second DNS resolver to use for the clients (optional) [default ${CLIENT_DNS_DEF_2}]: " -e USER_INPUT_CLIENT_DNS_2
                    CLIENT_DNS_2=${USER_INPUT_CLIENT_DNS_2:-$CLIENT_DNS_DEF_2}
                else
                    read -rp "Second DNS resolver to use for the clients (optional): " -e -i 94.140.15.15 CLIENT_DNS_2
                    if [[ ${CLIENT_DNS_2} == "" ]]; then
                        CLIENT_DNS_2="${CLIENT_DNS_1}"
                    fi
                fi
            done
            ;;
        2)
            SERVER_ALLOWED_IPS="${SERVER_WG_IPV4%.*}.0/${SERVER_WG_SUBNET}"
            CLIENT_DNS_1=""
            CLIENT_DNS_2=""
            ;;
        3)
            read -rp "Enter comma-separated subnets (e.g. 192.168.2.0/24,192.168.100.0/24): " SERVER_ALLOWED_IPS
            CLIENT_DNS_1=""
            CLIENT_DNS_2=""
            ;;
    esac

	echo ""
	echo "Okay, that was all I needed. We are ready to setup your WireGuard server now."
	echo "You will be able to generate a client at the end of the installation."
	read -n1 -r -p "Press any key to continue..."
}

function newInterface() {
	# Run setup questions first
	installQuestions

	# Make sure the directory exists (this does not seem the be the case on fedora)
	mkdir -p "$(pwd)"/wireguard/"${SERVER_WG_NIC}"/mikrotik >/dev/null 2>&1

	SERVER_PRIV_KEY=$(wg genkey)
	SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | wg pubkey)

	# Save WireGuard settings #SERVER_PUB_NIC=${SERVER_PUB_NIC}
	echo "SERVER_PUB_IP=${SERVER_PUB_IP}
SERVER_WG_NIC=${SERVER_WG_NIC}
SERVER_WG_IPV4=${SERVER_WG_IPV4}
SERVER_WG_SUBNET=${SERVER_WG_SUBNET}
SERVER_WG_IPV6=${SERVER_WG_IPV6}
SERVER_ENABLE_IPV6=${SERVER_ENABLE_IPV6}
SERVER_PORT=${SERVER_PORT}
SERVER_PRIV_KEY=${SERVER_PRIV_KEY}
SERVER_PUB_KEY=${SERVER_PUB_KEY}
CLIENT_DNS_1=${CLIENT_DNS_1}
CLIENT_DNS_2=${CLIENT_DNS_2}
SERVER_ALLOWED_IPS=${SERVER_ALLOWED_IPS}" > "$(pwd)/wireguard/${SERVER_WG_NIC}/params"

    # Save WireGuard settings to the MikroTik
    cat > "$(pwd)/wireguard/${SERVER_WG_NIC}/mikrotik/${SERVER_WG_NIC}.rsc" <<EOF
# WireGuard interface configure
/interface wireguard
add listen-port=${SERVER_PORT} mtu=1420 name=${SERVER_WG_NIC} private-key="${SERVER_PRIV_KEY}" comment=wg-mikrotik-${SERVER_WG_NIC}-interface
/ip firewall filter
add action=accept chain=input comment=wg-mikrotik-${SERVER_WG_NIC}-interface dst-port=${SERVER_PORT} protocol=udp
/ip firewall filter move [/ip firewall filter find comment=wg-mikrotik-${SERVER_WG_NIC}-interface] 1
/ip address
add address=${SERVER_WG_IPV4}/${SERVER_WG_SUBNET} comment=wg-mikrotik-${SERVER_WG_NIC}-interface interface=${SERVER_WG_NIC}
EOF

    # Add IPv6 address to MikroTik config if enabled
    if [[ "$SERVER_ENABLE_IPV6" == "yes" && -n "$SERVER_WG_IPV6" ]]; then
        cat >> "$(pwd)/wireguard/${SERVER_WG_NIC}/mikrotik/${SERVER_WG_NIC}.rsc" <<EOF
/ipv6 address
add address=${SERVER_WG_IPV6}/64 comment=wg-mikrotik-${SERVER_WG_NIC}-interface interface=${SERVER_WG_NIC}
EOF
    fi

	# Add server interface
	if [[ "$SERVER_ENABLE_IPV6" == "yes" ]]; then
		echo "[Interface]
Address = ${SERVER_WG_IPV4}/${SERVER_WG_SUBNET},${SERVER_WG_IPV6}/64
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}" > "$(pwd)/wireguard/${SERVER_WG_NIC}/${SERVER_WG_NIC}.conf"
	else
		echo "[Interface]
Address = ${SERVER_WG_IPV4}/${SERVER_WG_SUBNET}
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}" > "$(pwd)/wireguard/${SERVER_WG_NIC}/${SERVER_WG_NIC}.conf"
	fi

	newClient
	echo -e "${INFO} MikroTik interface config available in $(pwd)/wireguard/${SERVER_WG_NIC}/mikrotik/${SERVER_WG_NIC}.rsc"
	echo -e "${INFO} If you want to add more clients, you simply need to run this script another time!"

    # Generate purge script for this server (robust, correct MikroTik syntax)
    PURGE_SCRIPT_PATH="$(pwd)/wireguard/${SERVER_WG_NIC}/mikrotik/purge-wg-mikrotik-${SERVER_WG_NIC}.rsc"
    cat > "$PURGE_SCRIPT_PATH" <<EOF
# purge-wg-mikrotik-${SERVER_WG_NIC}.rsc
# This script will remove all rules with the comment prefix 'wg-mikrotik-${SERVER_WG_NIC}' from the MikroTik router

/interface wireguard remove [find where comment~"^wg-mikrotik-${SERVER_WG_NIC}"]
/interface wireguard peers remove [find where comment~"^wg-mikrotik-${SERVER_WG_NIC}"]
/ip firewall filter remove [find where comment~"^wg-mikrotik-${SERVER_WG_NIC}"]
/ip address remove [find where comment~"^wg-mikrotik-${SERVER_WG_NIC}"]
/ipv6 address remove [find where comment~"^wg-mikrotik-${SERVER_WG_NIC}"]
EOF
}

function newClient() {
    ENDPOINT="${SERVER_PUB_IP}:${SERVER_PORT}"

    echo ""
    echo "Tell me a name for the client."
    echo "The name must consist of alphanumeric character. It may also include an underscore or a dash and can't exceed 15 chars."

    until [[ ${CLIENT_NAME} =~ ^[a-zA-Z0-9_-]+$ && ${CLIENT_EXISTS} == '0' && ${#CLIENT_NAME} -lt 16 ]]; do
        read -rp "Client name: " -e CLIENT_NAME
        CLIENT_EXISTS=$(grep -c -E "^### Client ${CLIENT_NAME}$" "$(pwd)/wireguard/${SERVER_WG_NIC}/${SERVER_WG_NIC}.conf")

        if [[ ${CLIENT_EXISTS} == '1' ]]; then
            echo ""
            echo "A client with the specified name was already created, please choose another name."
            echo ""
        fi
    done

	for DOT_IP in {2..254}; do
		if [[ ${OS} == 'macos' ]]; then
			DOT_EXISTS=$(grep -c "$(echo "${SERVER_WG_IPV4}" | rev | cut -c 2- | rev)${DOT_IP}" "$(pwd)/wireguard/${SERVER_WG_NIC}/${SERVER_WG_NIC}.conf")
		else
			DOT_EXISTS=$(grep -c "${SERVER_WG_IPV4::-1}${DOT_IP}" "$(pwd)/wireguard/${SERVER_WG_NIC}/${SERVER_WG_NIC}.conf")
		fi
		if [[ ${DOT_EXISTS} == '0' ]]; then
			break
		fi
	done

    # Calculate network and broadcast for the subnet
    IFS=. read -r o1 o2 o3 o4 <<< "$SERVER_WG_IPV4"
    NETMASK=$(( 0xFFFFFFFF << (32 - SERVER_WG_SUBNET) & 0xFFFFFFFF ))
    IPINT=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
    NETINT=$(( IPINT & NETMASK ))
    BROADCASTINT=$(( NETINT | (0xFFFFFFFF >> SERVER_WG_SUBNET) ))
    SERVERINT=$IPINT
    TOTAL_HOSTS=$(( BROADCASTINT - NETINT - 1 ))

	if [[ ${DOT_EXISTS} == '1' ]]; then
        echo ""
        echo "The subnet ${SERVER_WG_IPV4}/${SERVER_WG_SUBNET} supports only ${TOTAL_HOSTS} clients (excluding network, broadcast, and server IP)."
        exit 99
    fi

	BASE_IP=$(echo "$SERVER_WG_IPV4" | awk -F '.' '{ print $1"."$2"."$3 }')
	until [[ ${IPV4_EXISTS} == '0' ]]; do
		if [[ ${OS} == 'macos' ]]; then
			read -rp "Client's WireGuard IPv4 [default used ${BASE_IP}.${DOT_IP}]: " -e USER_INPUT_DOT_IP
			DOT_IP=${USER_INPUT_DOT_IP:-$DOT_IP}
		else
			read -rp "Client's WireGuard IPv4: ${BASE_IP}." -e -i "${DOT_IP}" DOT_IP
		fi

		if ! [[ ${DOT_IP} =~ ^[0-9]+$ && ${DOT_IP} -ge 2 && ${DOT_IP} -le 254 ]]; then
			echo ""
			echo "Invalid IPv4 address. The last octet must be between 2 and 254."
			echo ""
			continue
		fi

		CLIENT_WG_IPV4="${BASE_IP}.${DOT_IP}"

		if ! [[ ${CLIENT_WG_IPV4} =~ ^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$ ]]; then
            echo ""
            echo "Invalid IPv4 address format. Please enter a valid IPv4 address in the subnet ${SERVER_WG_IPV4}/${SERVER_WG_SUBNET}."
            echo ""
            continue
        fi
        CLIENTINT=$(ip_to_int "$CLIENT_WG_IPV4")
        if (( CLIENTINT <= NETINT || CLIENTINT >= BROADCASTINT )); then
            echo "Client IP must be inside the subnet ${SERVER_WG_IPV4}/${SERVER_WG_SUBNET} and not the network or broadcast address."
            continue
        fi
        if (( CLIENTINT == SERVERINT )); then
            echo "Client IP must not be the same as the server IP (${SERVER_WG_IPV4})."
            continue
        fi

		IPV4_EXISTS=$(grep -c "$CLIENT_WG_IPV4/24" "$(pwd)/wireguard/${SERVER_WG_NIC}/${SERVER_WG_NIC}.conf")

		if [[ ${IPV4_EXISTS} == '1' ]]; then
			echo ""
			echo "A client with the specified IPv4 was already created, please choose another IPv4."
			echo ""
		fi
	done

	# Only ask for IPv6 if enabled
	if [[ "$SERVER_ENABLE_IPV6" == "yes" ]]; then
		BASE_IP=$(echo "$SERVER_WG_IPV6" | awk -F '::' '{ print $1 }')
		until [[ ${IPV6_EXISTS} == '0' && ${DOT_IP} =~ ^[0-9a-fA-F]+$ ]]; do
			if [[ ${OS} == 'macos' ]]; then
				read -rp "Client's WireGuard IPv6 [default used ${BASE_IP}::${DOT_IP}]: " -e USER_INPUT_DOT_IP
				DOT_IP=${USER_INPUT_DOT_IP:-$DOT_IP}
			else
				read -rp "Client's WireGuard IPv6: ${BASE_IP}::" -e -i "${DOT_IP}" DOT_IP
			fi

			if ! [[ ${DOT_IP} =~ ^[0-9a-fA-F]+$ ]]; then
				echo ""
				echo "Invalid IPv6 address. Must be a hexadecimal number."
				echo ""
				continue
			fi

			CLIENT_WG_IPV6="${BASE_IP}::${DOT_IP}"

			# Validate complete IPv6 address format
			if ! [[ ${CLIENT_WG_IPV6} =~ ^([0-9a-fA-F]{1,4}:){1,7}[0-9a-fA-F]{1,4}$ ]]; then
				echo ""
				echo "Invalid IPv6 address format."
				echo ""
				continue
			fi

			IPV6_EXISTS=$(grep -c "${CLIENT_WG_IPV6}/64" "$(pwd)/wireguard/${SERVER_WG_NIC}/${SERVER_WG_NIC}.conf")

			if [[ ${IPV6_EXISTS} == '1' ]]; then
				echo ""
				echo "A client with the specified IPv6 was already created, please choose another IPv6."
				echo ""
			fi
		done
	else
		CLIENT_WG_IPV6=""
	fi

	# Set ALLOWED_IPV4 from SERVER_ALLOWED_IPS (from params)
	ALLOWED_IPV4="$SERVER_ALLOWED_IPS"

	# Only ask for IPv6 allowed IPs if enabled
	if [[ "$SERVER_ENABLE_IPV6" == "yes" && -n "$SERVER_WG_IPV6" ]]; then
		until [[ ${ALLOWED_IPV6} =~ ^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))(\/(\(1(1[0-9]|2[0-8])\)|([0-9][0-9])|([0-9])))?$ ]]; do
			if [[ ${OS} == 'macos' ]]; then
				ALLOWED_IPV6="::/0"
				read -rp "Client's allowed IPv6 [default used ${ALLOWED_IPV6}]: " -e USER_INPUT_ALLOWED_IPV6
				ALLOWED_IPV6=${USER_INPUT_ALLOWED_IPV6:-$ALLOWED_IPV6}
			else
				read -rp "Client's allowed IPv6: " -e -i "::/0" ALLOWED_IPV6
			fi
		done
	else
		ALLOWED_IPV6=""
	fi

	# Generate key pair for the client
	CLIENT_PRIV_KEY=$(wg genkey)
	CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
	CLIENT_PRE_SHARED_KEY=$(wg genpsk)

    mkdir -p "$(pwd)/wireguard/${SERVER_WG_NIC}/client/${CLIENT_NAME}" >/dev/null 2>&1
	HOME_DIR="$(pwd)/wireguard/${SERVER_WG_NIC}/client/${CLIENT_NAME}"
    CLIENT_CONF_NAME="${SERVER_WG_NIC}.conf"
    CLIENT_PNG_NAME="${SERVER_WG_NIC}.png"

    # Create client file and add the server as a peer
    if [[ "$SERVER_ENABLE_IPV6" == "yes" && -n "$CLIENT_WG_IPV6" ]]; then
        if [[ -n "$CLIENT_DNS_1" ]]; then
            echo "[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128
DNS = ${CLIENT_DNS_1},${CLIENT_DNS_2}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED_IPV4},${ALLOWED_IPV6}
PersistentKeepalive = 25" >"${HOME_DIR}/${CLIENT_CONF_NAME}"
        else
            echo "[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED_IPV4},${ALLOWED_IPV6}
PersistentKeepalive = 25" >"${HOME_DIR}/${CLIENT_CONF_NAME}"
        fi
    else
        if [[ -n "$CLIENT_DNS_1" ]]; then
            echo "[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32
DNS = ${CLIENT_DNS_1},${CLIENT_DNS_2}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED_IPV4}
PersistentKeepalive = 25" >"${HOME_DIR}/${CLIENT_CONF_NAME}"
        else
            echo "[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED_IPV4}
PersistentKeepalive = 25" >"${HOME_DIR}/${CLIENT_CONF_NAME}"
        fi
    fi

    qrencode -t ansiutf8 -l L <"${HOME_DIR}/${CLIENT_CONF_NAME}"
    qrencode -l L -s 6 -d 225 -o "${HOME_DIR}/${CLIENT_PNG_NAME}" <"${HOME_DIR}/${CLIENT_CONF_NAME}"

    # Add the client as a peer to the MikroTik (to client folder)
    echo "# WireGuard client peer configure
/interface wireguard peers
add allowed-address=${CLIENT_WG_IPV4}/32 comment=wg-mikrotik-${SERVER_WG_NIC}-${CLIENT_NAME} interface=${SERVER_WG_NIC} \
    preshared-key=\"${CLIENT_PRE_SHARED_KEY}\" public-key=\"${CLIENT_PUB_KEY}\"
    " >"${HOME_DIR}/mikrotik-peer-${SERVER_WG_NIC}-client-${CLIENT_NAME}.rsc"

    # Add the client as a peer to the MikroTik
    echo "# WireGuard client peer configure
/interface wireguard peers
add allowed-address=${CLIENT_WG_IPV4}/32 comment=wg-mikrotik-${SERVER_WG_NIC}-${CLIENT_NAME} interface=${SERVER_WG_NIC} \
    preshared-key=\"${CLIENT_PRE_SHARED_KEY}\" public-key=\"${CLIENT_PUB_KEY}\" persistent-keepalive=25
    " >> "$(pwd)/wireguard/${SERVER_WG_NIC}/mikrotik/${SERVER_WG_NIC}.rsc"

    # Add the client as a peer to the server
	if [[ "$SERVER_ENABLE_IPV6" == "yes" && -n "$CLIENT_WG_IPV6" ]]; then
		echo -e "\n### Client ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128" >>"$(pwd)/wireguard/${SERVER_WG_NIC}/${SERVER_WG_NIC}.conf"
	else
		echo -e "\n### Client ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32" >>"$(pwd)/wireguard/${SERVER_WG_NIC}/${SERVER_WG_NIC}.conf"
	fi

	echo -e "\nHere is your client config file as a QR Code:"

	qrencode -t ansiutf8 -l L <"${HOME_DIR}/${CLIENT_CONF_NAME}"
	qrencode -l L -s 6 -d 225 -o "${HOME_DIR}/${CLIENT_PNG_NAME}" <"${HOME_DIR}/${CLIENT_CONF_NAME}"

	echo -e "${INFO} Config available in ${HOME_DIR}/${CLIENT_CONF_NAME}"
	echo -e "${INFO} QR is also available in ${HOME_DIR}/${CLIENT_PNG_NAME}"
	echo -e "${INFO} MikroTik peer config available in ${HOME_DIR}/mikrotik-${SERVER_WG_NIC}-client-${CLIENT_NAME}.rsc"
}
function manageMenu() {
	echo ""
	echo "It looks like this WireGuard interface is already."
	echo ""
	echo "What do you want to do?"
	echo "   1) Add a new client"
	echo "   2) Exit"
	until [[ ${MENU_OPTION} =~ ^[1-4]$ ]]; do
		read -rp "Select an option [1-2]: " MENU_OPTION
	done
	case "${MENU_OPTION}" in
	1)
		newClient
		;;
	2)
		exit 0
		;;
	esac
}

#? List of existing configurations
function listConfs() {
    local directory
    directory="$(pwd)/wireguard"
    SERVER_LIST=()
    if [ -d "${directory}" ]; then
        echo "List of existing configurations:"
        i=1
        for folder in "${directory}"/*/; do
            local users count folder_name
            users="${folder}/client/"
            count=$(find "$users" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
            folder_name=$(basename "${folder}")
            echo "${i}. ${folder_name} [${count} user(s)]"
            SERVER_LIST+=("${folder_name}")
            ((i++))
        done
        if (( i > 1 )); then
            while true; do
                read -rp "Select a server by number or enter a new name: " SERVER_SELECTION
                if [[ $SERVER_SELECTION =~ ^[0-9]+$ ]] && (( SERVER_SELECTION >= 1 && SERVER_SELECTION < i )); then
                    SERVER_WG_NIC="${SERVER_LIST[$((SERVER_SELECTION-1))]}"
                    break
                elif [[ $SERVER_SELECTION =~ ^[a-zA-Z0-9_]+$ ]]; then
                    SERVER_WG_NIC="$SERVER_SELECTION"
                    break
                else
                    echo "Invalid selection. Enter a number from the list or a new server name."
                fi
            done
        fi
    fi
    echo ""
}

echo ""
echo "Welcome to WireGuard-MikroTik configurator!"
echo "The git repository is available at: https://github.com/IgorKha/wireguard-mikrotik"
echo ""

#? Check OS
checkOS
echo "Your OS is ${OS}"

#? Check for root, WireGuard
installCheck

listConfs

#? Check server exist
serverName

#? Check if WireGuard is already installed and load params
if [[ -e $(pwd)/wireguard/${SERVER_WG_NIC}/params ]]; then
	# shellcheck source=/dev/null
	source "$(pwd)/wireguard/${SERVER_WG_NIC}/params"
	manageMenu
else
	newInterface
fi
