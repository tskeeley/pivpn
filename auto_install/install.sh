#!/usr/bin/env bash
# PiVPN: Trivial openvpn setup and configuration
# Easiest setup and mangement of openvpn on Raspberry Pi
# http://pivpn.io
# Heavily adapted from the pi-hole.net project and...
# https://github.com/StarshipEngineer/OpenVPN-Setup/
#
# Install with this command (from your Pi):
#
# curl -L http://install.pivpn.io | bash


######## VARIABLES #########

tmpLog=/tmp/pivpn-install.log
instalLogLoc=/etc/pivpn/install.log

pivpnGitUrl="https://github.com/pivpn/pivpn.git"
pivpnFilesDir="/etc/.pivpn"


# Find the rows and columns
rows=$(tput lines)
columns=$(tput cols)

# Divide by two so the dialogs take up half of the screen, which looks nice.
r=$(( rows / 2 ))
c=$(( columns / 2 ))


# Find IP used to route to outside world

IPv4dev=$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++)if($i~/dev/)print $(i+1)}')
IPv4addr=$(ip -o -f inet addr show dev "$IPv4dev" | awk '{print $4}' | awk 'END {print}')
IPv4gw=$(ip route get 8.8.8.8 | awk '{print $3}')

availableInterfaces=$(ip -o link | awk '{print $2}' | grep -v "lo" | cut -d':' -f1)
availableUsers=$(awk -F':' '$3>=500 && $3<=60000 {print $1}' /etc/passwd)
dhcpcdFile=/etc/dhcpcd.conf

######## FIRST CHECK ########
# Must be root to install
echo ":::"
if [[ $EUID -eq 0 ]];then
    echo "::: You are root."
else
    echo "::: sudo will be used for the install."
    # Check if it is actually installed
    # If it isn't, exit because the install cannot complete
    if [[ $(dpkg-query -s sudo) ]];then
        export SUDO="sudo"
        export SUDOE="sudo -E"
    else
        echo "::: Please install sudo or run this as root."
        exit 1
    fi
fi

####### FUNCTIONS ##########
spinner()
{
    local pid=$1
    local delay=0.50
    local spinstr='/-\|'
    while [ "$(ps a | awk '{print $1}' | grep "$pid")" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

welcomeDialogs() {
    # Display the welcome dialog
    whiptail --msgbox --backtitle "Welcome" --title "PiVPN Automated Installer" "This installer will transform your Raspberry Pi into an openvpn server!" $r $c

    # Explain the need for a static address
    whiptail --msgbox --backtitle "Initiating network interface" --title "Static IP Needed" "The PiVPN is a SERVER so it needs a STATIC IP ADDRESS to function properly.
    
In the next section, you can choose to use your current network settings (DHCP) or to manually edit them." $r $c
}

chooseUser() {
    # Explain the local user
    whiptail --msgbox --backtitle "Parsing User List" --title "Local Users" "Choose a local user that will hold your ovpn configurations." $r $c

    userArray=()
    firstloop=1

    while read -r line
    do
        mode="OFF"
        if [[ $firstloop -eq 1 ]]; then
            firstloop=0
            mode="ON"
        fi
        userArray+=("$line" "available" "$mode")
    done <<< "$availableUsers"

    # Find out how many users are available to choose from
    userCount=$(echo "$availableUsers" | wc -l)
    chooseUserCmd=(whiptail --title "Choose A User" --separate-output --radiolist "Choose:" $r $c $userCount)
    chooseUserOptions=$("${chooseUserCmd[@]}" "${userArray[@]}" 2>&1 >/dev/tty)
    if [[ $? = 0 ]]; then
        for desiredUser in $chooseUserOptions
        do
            pivpnUser=$desiredUser
            echo "::: Using User: $pivpnUser"
            echo "${pivpnUser}" > /tmp/pivpnUSR
        done
    else
        echo "::: Cancel selected, exiting...."
        exit 1
    fi
}


verifyFreeDiskSpace() {
    # I have no idea what the minimum space needed is, but checking for at least 50MB sounds like a good idea.
    requiredFreeBytes=51200

    existingFreeBytes=$(df -lk / 2>&1 | awk '{print $4}' | head -2 | tail -1)
    if ! [[ "$existingFreeBytes" =~ ^([0-9])+$ ]]; then
        existingFreeBytes=$(df -lk /dev 2>&1 | awk '{print $4}' | head -2 | tail -1)
    fi

    if [[ $existingFreeBytes -lt $requiredFreeBytes ]]; then
        whiptail --msgbox --backtitle "Insufficient Disk Space" --title "Insufficient Disk Space" "\nYour system appears to be low on disk space. PiVPN recomends a minimum of $requiredFreeBytes Bytes.\nYou only have $existingFreeBytes Free.\n\nIf this is a new install you may need to expand your disk.\n\nTry running:\n    'sudo raspi-config'\nChoose the 'expand file system option'\n\nAfter rebooting, run this installation again.\n\ncurl -L http://install.pivpn.io | bash\n" $r $c
        echo "$existingFreeBytes is less than $requiredFreeBytes"
        echo "Insufficient free space, exiting..."
        exit 1
    fi
}


chooseInterface() {
    # Turn the available interfaces into an array so it can be used with a whiptail dialog
    interfacesArray=()
    firstloop=1

    while read -r line
    do
        mode="OFF"
        if [[ $firstloop -eq 1 ]]; then
            firstloop=0
            mode="ON"
        fi
        interfacesArray+=("$line" "available" "$mode")
    done <<< "$availableInterfaces"

    # Find out how many interfaces are available to choose from
    interfaceCount=$(echo "$availableInterfaces" | wc -l)
    chooseInterfaceCmd=(whiptail --separate-output --radiolist "Choose An Interface" $r $c $interfaceCount)
    chooseInterfaceOptions=$("${chooseInterfaceCmd[@]}" "${interfacesArray[@]}" 2>&1 >/dev/tty)
    if [[ $? = 0 ]]; then
        for desiredInterface in $chooseInterfaceOptions
        do
            pivpnInterface=$desiredInterface
            echo "::: Using interface: $pivpnInterface"
            echo "${pivpnInterface}" > /tmp/pivpnINT
        done
    else
        echo "::: Cancel selected, exiting...."
        exit 1
    fi
}

getStaticIPv4Settings() {
    # Ask if the user wants to use DHCP settings as their static IP
    if (whiptail --backtitle "Calibrating network interface" --title "Static IP Address" --yesno "Do you want to use your current network settings as a static address?
                    IP address:    $IPv4addr
                    Gateway:       $IPv4gw" $r $c) then
        # If they choose yes, let the user know that the IP address will not be available via DHCP and may cause a conflict.
        whiptail --msgbox --backtitle "IP information" --title "FYI: IP Conflict" "It is possible your router could still try to assign this IP to a device, which would cause a conflict.  But in most cases the router is smart enough to not do that.
If you are worried, either manually set the address, or modify the DHCP reservation pool so it does not include the IP you want.
It is also possible to use a DHCP reservation, but if you are going to do that, you might as well set a static address." $r $c
        # Nothing else to do since the variables are already set above
    else
        # Otherwise, we need to ask the user to input their desired settings.
        # Start by getting the IPv4 address (pre-filling it with info gathered from DHCP)
        # Start a loop to let the user enter their information with the chance to go back and edit it if necessary
        until [[ $ipSettingsCorrect = True ]]
        do
            # Ask for the IPv4 address
            IPv4addr=$(whiptail --backtitle "Calibrating network interface" --title "IPv4 address" --inputbox "Enter your desired IPv4 address" $r $c "$IPv4addr" 3>&1 1>&2 2>&3)
            if [[ $? = 0 ]];then
            echo "::: Your static IPv4 address:    $IPv4addr"
            # Ask for the gateway
            IPv4gw=$(whiptail --backtitle "Calibrating network interface" --title "IPv4 gateway (router)" --inputbox "Enter your desired IPv4 default gateway" $r $c "$IPv4gw" 3>&1 1>&2 2>&3)
            if [[ $? = 0 ]];then
                echo "::: Your static IPv4 gateway:    $IPv4gw"
                # Give the user a chance to review their settings before moving on
                if (whiptail --backtitle "Calibrating network interface" --title "Static IP Address" --yesno "Are these settings correct?
                    IP address:    $IPv4addr
                    Gateway:       $IPv4gw" $r $c)then
                    # If the settings are correct, then we need to set the piVPNIP
                    # Saving it to a temporary file us to retrieve it later when we run the gravity.sh script
                    echo "${IPv4addr%/*}" > /tmp/pivpnIP
                    echo "$pivpnInterface" > /tmp/pivpnINT
                    # After that's done, the loop ends and we move on
                    ipSettingsCorrect=True
                else
                    # If the settings are wrong, the loop continues
                    ipSettingsCorrect=False
                fi
            else
                # Cancelling gateway settings window
                ipSettingsCorrect=False
                echo "::: Cancel selected. Exiting..."
                exit 1
            fi
        else
            # Cancelling IPv4 settings window
            ipSettingsCorrect=False
            echo "::: Cancel selected. Exiting..."
            exit 1
        fi
        done
        # End the if statement for DHCP vs. static
    fi
}

setDHCPCD() {
    # Append these lines to dhcpcd.conf to enable a static IP
    echo "::: interface $pivpnInterface
    static ip_address=$IPv4addr
    static routers=$IPv4gw
    static domain_name_servers=$IPv4gw" | $SUDO tee -a $dhcpcdFile >/dev/null
}

setStaticIPv4() {
    # Tries to set the IPv4 address
    if grep -q "$IPv4addr" $dhcpcdFile; then
        # address already set, noop
        :
    else
        setDHCPCD
        $SUDO ip addr replace dev "$pivpnInterface" "$IPv4addr"
        echo ":::"
        echo "::: Setting IP to $IPv4addr.  You may need to restart after the install is complete."
        echo ":::"
    fi
}

function valid_ip()
{
    local  ip=$1
    local  stat=1

    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 \
        && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

installScripts() {
    # Install the scripts from /etc/.pivpn to their various locations
    $SUDO echo ":::"
    $SUDO echo -n "::: Installing scripts to /opt/pivpn..."
    if [ ! -d /opt/pivpn ]; then
        $SUDO mkdir /opt/pivpn
        $SUDO chown "$pivpnUser":root /opt/pivpn
        $SUDO chmod u+srwx /opt/pivpn
    fi
    $SUDO cp /etc/.pivpn/scripts/makeOVPN.sh /opt/pivpn/makeOVPN.sh
    $SUDO cp /etc/.pivpn/scripts/listOVPN.sh /opt/pivpn/listOVPN.sh
    $SUDO cp /etc/.pivpn/scripts/removeOVPN.sh /opt/pivpn/removeOVPN.sh
    $SUDO cp /etc/.pivpn/scripts/uninstall.sh /opt/pivpn/uninstall.sh
    $SUDO cp /etc/.pivpn/scripts/pivpnDebug.sh /opt/pivpn/pivpnDebug.sh
    $SUDO chmod 0755 /opt/pivpn/{makeOVPN,listOVPN,removeOVPN,uninstall,pivpnDebug}.sh
    $SUDO cp /etc/.pivpn/pivpn /usr/local/bin/pivpn
    $SUDO chmod 0755 /usr/local/bin/pivpn
    $SUDO cp /etc/.pivpn/scripts/bash-completion /etc/bash_completion.d/pivpn
    . /etc/bash_completion.d/pivpn

    $SUDO echo " done."
}

stopServices() {
    # Stop openvpn
    $SUDO echo ":::"
    $SUDO echo -n "::: Stopping openvpn service..."
    $SUDO systemctl openvpn.service stop || true
    $SUDO echo " done."
}

checkForDependencies() {
    #Running apt-get update/upgrade with minimal output can cause some issues with
    #requiring user input (e.g password for phpmyadmin see #218)
    #We'll change the logic up here, to check to see if there are any updates availible and
    # if so, advise the user to run apt-get update/upgrade at their own discretion
    #Check to see if apt-get update has already been run today
    # it needs to have been run at least once on new installs!

    timestamp=$(stat -c %Y /var/cache/apt/)
    timestampAsDate=$(date -d @"$timestamp" "+%b %e")
    today=$(date "+%b %e")

    if [ ! "$today" == "$timestampAsDate" ]; then
        #update package lists
        echo ":::"
        echo -n "::: apt-get update has not been run today. Running now..."
        $SUDO apt-get -qq update & spinner $!
        echo " done!"
    fi
    echo ":::"
    echo -n "::: Checking apt-get for upgraded packages...."
    updatesToInstall=$($SUDO apt-get -s -o Debug::NoLocking=true upgrade | grep -c ^Inst)
    echo " done!"
    echo ":::"
    if [[ $updatesToInstall -eq "0" ]]; then
        echo "::: Your pi is up to date! Continuing with PiVPN installation..."
    else
        echo "::: There are $updatesToInstall updates availible for your pi!"
        echo "::: We recommend you run 'sudo apt-get upgrade' after installing PiVPN! "
        echo ":::"
    fi
    echo ":::"
    echo "::: Checking dependencies:"

  dependencies=( openvpn easy-rsa git iptables-persistent dnsutils )
    for i in "${dependencies[@]}"; do
        echo -n ":::    Checking for $i..."
        if [ "$(dpkg-query -W -f='${Status}' "$i" 2>/dev/null | grep -c "ok installed")" -eq 0 ]; then
            echo -n " Not found! Installing...."
            #Supply answers to the questions so we don't prompt user
            if [[ $i -eq "iptables-persistent" ]]; then
                echo iptables-persistent iptables-persistent/autosave_v4 boolean true | $SUDO debconf-set-selections
                echo iptables-persistent iptables-persistent/autosave_v6 boolean false | $SUDO debconf-set-selections
            fi
            $SUDO apt-get -y -qq install "$i" > /dev/null & spinner $!
            echo " done!"
        else
            echo " already installed!"
        fi
    done
}

getGitFiles() {
    # Setup git repos for base files
    echo ":::"
    echo "::: Checking for existing base files..."
    if is_repo $pivpnFilesDir; then
        make_repo $pivpnFilesDir $pivpnGitUrl
    else
        update_repo $pivpnFilesDir
    fi
}

is_repo() {
    # If the directory does not have a .git folder it is not a repo
    echo -n ":::    Checking $1 is a repo..."
        if [ -d "$1/.git" ]; then
        echo " OK!"
        return 1
    fi
    echo " not found!!"
    return 0
}

make_repo() {
    # Remove the non-repos interface and clone the interface
    echo -n ":::    Cloning $2 into $1..."
    $SUDO rm -rf "$1"
    $SUDO git clone -q "$2" "$1" > /dev/null & spinner $!
    echo " done!"
}

update_repo() {
    # Pull the latest commits
    echo -n ":::     Updating repo in $1..."
    cd "$1" || exit
    $SUDO git pull -q > /dev/null & spinner $!
    echo " done!"
}

confOpenVPN () {
    # Ask user if want to modify default port
    SERVER_NAME="server"
    PORT=$(whiptail --title "Default OpenVPN Port" --inputbox "You can modify the default OpenVPN port. \nEnter a new value or hit 'Enter' to retain the default" $r $c 1194 3>&1 1>&2 2>&3)    

    # Ask user for desired level of encryption
    ENCRYPT=$(whiptail --backtitle "Setup OpenVPN" --title "Encryption Strength" --radiolist \
    "Choose your desired level of encryption:" $r $c 2 \
    "2048" "Use 2048-bit encryption. Slower to set up, but more secure." ON \
    "1024" "Use 1024-bit encryption. Faster to set up, but less secure." OFF 3>&1 1>&2 2>&3)

    exitstatus=$?
    if [ $exitstatus != 0 ]; then
        echo "::: Cancel selected. Exiting..."
        exit 1
    fi

    # Copy the easy-rsa files to a directory inside the new openvpn directory
    $SUDO cp -r /usr/share/easy-rsa /etc/openvpn

    # Edit the EASY_RSA variable in the vars file to point to the new easy-rsa directory,
    # And change from default 1024 encryption if desired
    $SUDO cd /etc/openvpn/easy-rsa
    $SUDO sed -i 's:"`pwd`":"/etc/openvpn/easy-rsa":' vars
    if [[ $ENCRYPT -eq "1024" ]]; then
        $SUDO sed -i "s/\(KEY_SIZE=\).*/\1${ENCRYPT}/" vars
    fi

    whiptail --title "Certificate Information" --msgbox "You will now be shown the default values for fields that will be used in the certificate. \nIt is fine to leave these as-is since only you and the clients you create will ever see this. \nHowever, if you want to change the values, simply select the ones you wish to modify." $r $c

    CERTVAL=$(whiptail --title "Certificate Information" --checklist "Choose any certificate values you want to change" $r $c 7 \
        "COUNTRY" "= US" OFF \
        "STATE" "= CA" OFF \
        "CITY" "= SanFranciso" OFF \
        "ORG" "= Fort-Funston" OFF \
        "SERVER_NAME" "= server" OFF \
        "KEY_NAME" "= EasyRSA" OFF \
        "EMAIL" "= me@myhost.mydomain" OFF 3>&1 1>&2 2>&3)

    exitstatus=$?
    if [ $exitstatus != 0 ]; then
        echo "::: Cancel selected. Exiting..."
        exit 1
    fi

    for i in $CERTVAL
        do
            if [ $i == '"COUNTRY"' ]; then
                COUNTRY=$(whiptail --title "Certificate Country" --inputbox \
                "Enter a 2 letter abbreviation for Country" $r $c US 3>&1 1>&2 2>&3)
                $SUDO sed -i "s/\(KEY_COUNTRY=\"\).*/\1${COUNTRY}\"/" vars
            fi
            if [ $i == '"STATE"' ]; then
                STATE=$(whiptail --title "Certificate State" --inputbox \
                "Enter a 2 letter abbreviated State or Province" $r $c CA 3>&1 1>&2 2>&3)
                $SUDO sed -i "s/\(KEY_PROVINCE=\"\).*/\1${STATE}\"/" vars
            fi
            if [ $i == '"CITY"' ]; then
                CITY=$(whiptail --title "Certificate City" --inputbox \
                "Enter a City name" $r $c SanFrancisco 3>&1 1>&2 2>&3)
                $SUDO sed -i "s/\(KEY_CITY=\"\).*/\1${CITY}\"/" vars
            fi
            if [ $i == '"ORG"' ]; then
                ORG=$(whiptail --title "Certificate Org" --inputbox \
                "Enter an Organization name" $r $c Fort-Funston 3>&1 1>&2 2>&3)
                $SUDO sed -i "s/\(KEY_ORG=\"\).*/\1${ORG}\"/" vars
            fi
            if [ $i == '"EMAIL"' ]; then
                EMAIL=$(whiptail --title "Certificate Email" --inputbox \
                "Enter an Email Address" $r $c "me@myhost.mydomain" 3>&1 1>&2 2>&3)
                $SUDO sed -i "s/\(KEY_EMAIL=\"\).*/\1${EMAIL}\"/" vars
            fi
            if [ $i == '"SERVER_NAME"' ]; then
                SERVER_NAME=$(whiptail --title "Server Name" --inputbox \
                "Enter a Server Name" $r $c "pivpn" 3>&1 1>&2 2>&3)
                # This began a rabbit hole of errors. Nope.
                #sed -i '/export KEY_CN/s/^#//g' vars
                #sed -i "s/\(KEY_CN=\"\).*/\1${SERVER_NAME}\"/" vars
            fi
            if [ $i == '"KEY_NAME"' ]; then
                KEY_NAME=$(whiptail --title "Key Name" --inputbox \
                "Enter a Key Name" $r $c "EasyRSA" 3>&1 1>&2 2>&3)
                $SUDO sed -i "s/\(KEY_NAME=\"\).*/\1${KEY_NAME}\"/" vars
            fi
        done
    # Make PiVPN the OU
    KEY_OU=PiVPN
    $SUDO sed -i "s/\(KEY_OU=\"\).*/\1${KEY_OU}\"/" vars

    # It seems you have to set this if you mess with key_cn, lets not.
    # grep -q 'KEY_ALTNAMES=' vars || printf '\nexport KEY_ALTNAMES="PiVPN_KEYALT"\n' >> vars
    
    # source the vars file just edited
    source ./vars

    # Remove any previous keys
    ${SUDOE} ./clean-all

    # Build the certificate authority
    echo "::: Building CA..."
    ${SUDOE} ./build-ca < /etc/.pivpn/ca_info.txt
    printf "\n::: CA Complete.\n"

    whiptail --msgbox --backtitle "Setup OpenVPN" --title "Server Information" "The server key, Diffie-Hellman key, and HMAC key will now be generated." $r $c

    # Build the server
    ${SUDOE} ./build-key-server --batch $SERVER_NAME

    # Generate Diffie-Hellman key exchange
    ${SUDOE} ./build-dh

    # Generate static HMAC key to defend against DDoS
    ${SUDOE} openvpn --genkey --secret keys/ta.key

    # Write config file for server using the template .txt file
    LOCALIP=$(ifconfig $pivpnInterface | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*')
    $SUDO sed 's/LOCALIP/'$LOCALIP'/' </etc/.pivpn/server_config.txt >/etc/openvpn/server.conf
    if [ $ENCRYPT = 2048 ]; then
        $SUDO sed -i 's:dh1024:dh2048:' /etc/openvpn/server.conf
    fi
    
    # if they modified port put value in server.conf
    if [ $PORT != 1194 ]; then
        $SUDO sed -i -e "s/1194/${PORT}/g" /etc/openvpn/server.conf
    fi

    # write out server certs to conf file
    $SUDO sed -i "s/\(key \/etc\/openvpn\/easy-rsa\/keys\/\).*/\1$SERVER_NAME.key/" /etc/openvpn/server.conf
    $SUDO sed -i "s/\(cert \/etc\/openvpn\/easy-rsa\/keys\/\).*/\1$SERVER_NAME.crt/" /etc/openvpn/server.conf
}

confNetwork() {
    # Enable forwarding of internet traffic
    $SUDO sed -i '/net.ipv4.ip_forward=1/s/^#//g' /etc/sysctl.conf
    $SUDO sysctl -p

    # Write script to run openvpn and allow it through firewall on boot using the template .txt file
    $SUDO iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $IPv4dev -j MASQUERADE
    $SUDO netfilter-persistent save
}

confOVPN() {
    IPv4pub=$(dig +short myip.opendns.com @resolver1.opendns.com)
    $SUDO cp /tmp/pivpnUSR /etc/pivpn/INSTALL_USER

    # Set status that no certs have been revoked
    $SUDO echo 0 > /etc/pivpn/REVOKE_STATUS

    METH=$(whiptail --title "Public IP or DNS" --radiolist "Will clients use a Public IP or DNS Name to connect to your server?" $r $c 2 \
    "$IPv4pub" "Use this public IP" "ON" \
    "DNS Entry" "Use a public DNS" "OFF" 3>&1 1>&2 2>&3) 
    
    exitstatus=$?
    if [ $exitstatus != 0 ]; then
    echo "::: Cancel selected. Exiting..."
        exit 1
    fi

    if [ "$METH" == "$IPv4pub" ]; then
        $SUDO sed 's/IPv4pub/'$IPv4pub'/' </etc/.pivpn/Default.txt >/etc/openvpn/easy-rsa/keys/Default.txt
    else 
        PUBLICDNS=$(whiptail --title "PiVPN Setup" --inputbox "What is the public DNS name of this Raspberry Pi?" $r $c 3>&1 1>&2 2>&3)
        exitstatus=$?
        if [ $exitstatus = 0 ]; then
            $SUDO sed 's/IPv4pub/'$PUBLICDNS'/' </etc/.pivpn/Default.txt >/etc/openvpn/easy-rsa/keys/Default.txt
            whiptail --title "Setup OpenVPN" --infobox "Using PUBLIC DNS: $PUBLICDNS" $r $c
        else
            whiptail --title "Setup OpenVPN" --infobox "Cancelled" $r $c
            exit 1
        fi
    fi
    
    # Allow user to change DNS the clients use
    if (whiptail --title "VPN Client DNS" --yes-button "Default DNS" --no-button "Change DNS" --yesno "By Default your VPN Clients will use Google DNS. \nIf you wish to change this to your own DNS, you can do so now." $r $c) then
        echo "::: Using Google DNS servers for your VPN Clients"
    else
        OVPNDNS=$(whiptail --title "VPN Client DNS" --inputbox "Please enter the IP Address of the DNS server your clients should use" $r $c 8.8.8.8 3>&1 1>&2 2>&3)
        echo "::: Using $OVPNDNS as a DNS server for your VPN Clients"
    fi

    # if they modified port put value in Default.txt for clients to use
    if [ $PORT != 1194 ]; then
        $SUDO sed -i -e "s/1194/${PORT}/g" /etc/openvpn/easy-rsa/keys/Default.txt
    fi
    
    # if they changed client dns put in server config 
    if [[ $OVPNDNS != "8.8.8.8" ]]; then
        $SUDO sed -i -e "s/dhcp-option DNS 8.8.8.8/dhcp-option DNS ${OVPNDNS}/g" /etc/openvpn/server.conf
    fi

    ### ask about dns for clients

    $SUDO mkdir /home/$pivpnUser/ovpns
    $SUDO chmod 0777 -R /home/$pivpnUser/ovpns
}

installPiVPN() {
    checkForDependencies
    stopServices
    $SUDO mkdir -p /etc/pivpn/
    getGitFiles
    installScripts
    confOpenVPN
    confNetwork
    confOVPN
}

displayFinalMessage() {
    # Final completion message to user
    $SUDO systemctl enable openvpn.service
    $SUDO systemctl start openvpn.service
    whiptail --msgbox --backtitle "Make it so." --title "Installation Complete!" "Now run 'pivpn add' to create the ovpn profiles. 
Run 'pivpn help' to see what else you can do!
The install log is in /etc/pivpn." $r $c
    if (whiptail --title "Reboot" --yesno --defaultno "It is strongly recommended you reboot after installation.  Would you like to reboot now?" $r $c); then
        whiptail --title "Rebooting" --msgbox "The system will now reboot." $r $c
        printf "\nRebooting system...\n"
        $SUDO sleep 3
        $SUDO shutdown -r now
    fi
}

######## SCRIPT ############
# Start the installer
welcomeDialogs

# Verify there is enough disk space for the install
verifyFreeDiskSpace

# Find interfaces and let the user choose one
chooseInterface
getStaticIPv4Settings
setStaticIPv4

# Choose the user for the ovpns
chooseUser

# Install and log everything to a file
installPiVPN

# Move the log file into /etc/pivpn for storage
#$SUDO mv $tmpLog $installLogLoc

displayFinalMessage

echo "::: Install Complete..."