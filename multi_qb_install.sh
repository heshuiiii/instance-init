#!/bin/sh
tput sgr0; clear

## Load Seedbox Components
source <(wget -qO- https://raw.githubusercontent.com/heshuiiii/Dedicated-Seedbox/refs/heads/main/Install.sh)
# Check if Seedbox Components is successfully loaded
if [ $? -ne 0 ]; then
	echo "Component ~Seedbox Components~ failed to load"
	echo "Check connection with GitHub"
	exit 1
fi

## Load loading animation
source <(wget -qO- https://raw.githubusercontent.com/Silejonu/bash_loading_animations/main/bash_loading_animations.sh)
# Check if bash loading animation is successfully loaded
if [ $? -ne 0 ]; then
	fail "Component ~Bash loading animation~ failed to load"
	fail_exit "Check connection with GitHub"
fi
# Run BLA::stop_loading_animation if the script is interrupted
trap BLA::stop_loading_animation SIGINT

## Install function
install_() {
info_2 "$2"
BLA::start_loading_animation "${BLA_classic[@]}"
$1 1> /dev/null 2> $3
if [ $? -ne 0 ]; then
	fail_3 "FAIL" 
else
	info_3 "Successful"
	export $4=1
fi
BLA::stop_loading_animation
}

## Multi-instance qBittorrent install function
install_multi_qb_() {
    local username=$1
    local password=$2
    local qb_ver=$3
    local lib_ver=$4
    local cache=$5
    
    # Define ports and incoming ports for 4 instances
    local ports=(8080 8081 8082 8083)
    local incoming_ports=(45000 45001 45002 45003)
    
    info_2 "Installing 4 qBittorrent instances"
    
    for i in {0..3}; do
        local instance_num=$((i + 1))
        local port=${ports[$i]}
        local incoming_port=${incoming_ports[$i]}
        local instance_name="qbittorrent-${instance_num}"
        
        info_3 "Installing qBittorrent instance ${instance_num} on port ${port}"
        
        # Create separate directory for each instance
        local instance_dir="/home/${username}/.config/${instance_name}"
        mkdir -p "$instance_dir"
        chown -R $username:$username "$instance_dir"
        
        # Install qBittorrent for this instance
        BLA::start_loading_animation "${BLA_classic[@]}"
        install_qBittorrent_ "$username" "$password" "$qb_ver" "$lib_ver" "$cache" "$port" "$incoming_port" "$instance_name" 1> /dev/null 2> /tmp/qb_error_${instance_num}
        
        if [ $? -ne 0 ]; then
            BLA::stop_loading_animation
            fail_3 "qBittorrent instance ${instance_num} installation FAILED"
            warn "Check /tmp/qb_error_${instance_num} for details"
        else
            BLA::stop_loading_animation
            info_3 "qBittorrent instance ${instance_num} installation Successful"
            
            # Create systemd service for this instance
            create_qb_service "$username" "$instance_name" "$port" "$incoming_port" "$instance_dir"
            
            export qb_install_success_${instance_num}=1
        fi
    done
}

## Create systemd service for qBittorrent instance
create_qb_service() {
    local username=$1
    local instance_name=$2
    local port=$3
    local incoming_port=$4
    local config_dir=$5
    
    cat << EOF > /etc/systemd/system/${instance_name}.service
[Unit]
Description=qBittorrent-nox ${instance_name}
After=network.target

[Service]
Type=forking
User=${username}
Group=${username}
UMask=002
ExecStart=/usr/bin/qbittorrent-nox -d --webui-port=${port} --profile=${config_dir}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ${instance_name}.service
    systemctl start ${instance_name}.service
}

## Installation environment Check
info "Checking Installation Environment"
# Check Root Privilege
if [ $(id -u) -ne 0 ]; then 
    fail_exit "This script needs root permission to run"
fi

# Linux Distro Version check
if [ -f /etc/os-release ]; then
	. /etc/os-release
	OS=$NAME
	VER=$VERSION_ID
elif type lsb_release >/dev/null 2>&1; then
	OS=$(lsb_release -si)
	VER=$(lsb_release -sr)
elif [ -f /etc/lsb-release ]; then
	. /etc/lsb-release
	OS=$DISTRIB_ID
	VER=$DISTRIB_RELEASE
elif [ -f /etc/debian_version ]; then
	OS=Debian
	VER=$(cat /etc/debian_version)
elif [ -f /etc/SuSe-release ]; then
	OS=SuSe
elif [ -f /etc/redhat-release ]; then
	OS=Redhat
else
	OS=$(uname -s)
	VER=$(uname -r)
fi

if [[ ! "$OS" =~ "Debian" ]] && [[ ! "$OS" =~ "Ubuntu" ]]; then	#Only Debian and Ubuntu are supported
	fail "$OS $VER is not supported"
	info "Only Debian 10+ and Ubuntu 20.04+ are supported"
	exit 1
fi

if [[ "$OS" =~ "Debian" ]]; then	#Debian 10+ are supported
	if [[ ! "$VER" =~ "10" ]] && [[ ! "$VER" =~ "11" ]] && [[ ! "$VER" =~ "12" ]]; then
		fail "$OS $VER is not supported"
		info "Only Debian 10+ are supported"
		exit 1
	fi
fi

if [[ "$OS" =~ "Ubuntu" ]]; then #Ubuntu 20.04+ are supported
	if [[ ! "$VER" =~ "20" ]] && [[ ! "$VER" =~ "22" ]] && [[ ! "$VER" =~ "23" ]]; then
		fail "$OS $VER is not supported"
		info "Only Ubuntu 20.04+ is supported"
		exit 1
	fi
fi

## Read input arguments
while getopts "u:p:c:q:l:rbvx3mh" opt; do
  case ${opt} in
	u ) # process option username
		username=${OPTARG}
		;;
	p ) # process option password
		password=${OPTARG}
		;;
	c ) # process option cache
		cache=${OPTARG}
		#Check if cache is a number
		while true
		do
			if ! [[ "$cache" =~ ^[0-9]+$ ]]; then
				warn "Cache must be a number"
				need_input "Please enter a cache size (in MB):"
				read cache
			else
				break
			fi
		done
		#Converting the cache to qBittorrent's unit (MiB)
		qb_cache=$cache
		;;
	q ) # process option qBittorrent version
		qb_install=1
		qb_ver=("qBittorrent-${OPTARG}")
		;;
	l ) # process option libtorrent
		lib_ver=("libtorrent-${OPTARG}")
		#Check if qBittorrent version is specified
		if [ -z "$qb_ver" ]; then
			warn "You must choose a qBittorrent version for your libtorrent install"
			qb_ver_choose
		fi
		;;
	m ) # process option multi qBittorrent instances
		multi_qb_install=1
		qb_install=1
		;;
	r ) # process option autoremove
		autoremove_install=1
		;;
	b ) # process option autobrr
		autobrr_install=1
		;;
	v ) # process option vertex
		vertex_install=1
		;;
	x ) # process option bbr
		unset bbrv3_install
		bbrx_install=1	  
		;;
	3 ) # process option bbr
		unset bbrx_install
		bbrv3_install=1
		;;
	h ) # process option help
		info "Help:"
		info "Usage: ./Install.sh -u <username> -p <password> -c <Cache Size(unit:MiB)> -q <qBittorrent version> -l <libtorrent version> -m -b -v -r -3 -x"
		info "Example: ./Install.sh -u jerry048 -p 1LDw39VOgors -c 3072 -q 4.3.9 -l v1.2.19 -m -b -v -r -3"
		source <(wget -qO- https://raw.githubusercontent.com/jerry048/Seedbox-Components/main/Torrent%20Clients/qBittorrent/qBittorrent_install.sh)
		seperator
		info "Options:"
		need_input "1. -u : Username"
		need_input "2. -p : Password"
		need_input "3. -c : Cache Size for qBittorrent (unit:MiB)"
		echo -e "\n"
		need_input "4. -q : qBittorrent version"
		need_input "Available qBittorrent versions:"
		tput sgr0; tput setaf 7; tput dim; history -p "${qb_ver_list[@]}"; tput sgr0
		echo -e "\n"
		need_input "5. -l : libtorrent version"
		need_input "Available libtorrent versions:"
		tput sgr0; tput setaf 7; tput dim; history -p "${lib_ver_list[@]}"; tput sgr0
		echo -e "\n"
		need_input "6. -m : Install 4 qBittorrent instances (ports: 8080,8081,8082,8083)"
		need_input "7. -r : Install autoremove-torrents"
		need_input "8. -b : Install autobrr"
		need_input "9. -v : Install vertex"
		need_input "10. -x : Install BBRx"
		need_input "11. -3 : Install BBRv3"
		need_input "12. -h : Display help message"
		exit 0
		;;
	\? ) 
		info "Help:"
		info_2 "Usage: ./Install.sh -u <username> -p <password> -c <Cache Size(unit:MiB)> -q <qBittorrent version> -l <libtorrent version> -m -b -v -r -3 -x"
		info_2 "Example ./Install.sh -u jerry048 -p 1LDw39VOgors -c 3072 -q 4.3.9 -l v1.2.19 -m -b -v -r -3"
		exit 1
		;;
	esac
done

# System Update & Dependencies Install
info "Start System Update & Dependencies Install"
update

## Install Seedbox Environment
tput sgr0; clear
info "Start Installing Seedbox Environment"
echo -e "\n"

# qBittorrent
source <(wget -qO- https://raw.githubusercontent.com/jerry048/Seedbox-Components/main/Torrent%20Clients/qBittorrent/qBittorrent_install.sh)
# Check if qBittorrent install is successfully loaded
if [ $? -ne 0 ]; then
	fail_exit "Component ~qBittorrent install~ failed to load"
fi

if [[ ! -z "$qb_install" ]]; then
	## Check if all the required arguments are specified
	#Check if username is specified
	if [ -z "$username" ]; then
		warn "Username is not specified"
		need_input "Please enter a username:"
		read username
	fi
	#Check if password is specified
	if [ -z "$password" ]; then
		warn "Password is not specified"
		need_input "Please enter a password:"
		read password
	fi
	## Create user if it does not exist
	if ! id -u $username > /dev/null 2>&1; then
		useradd -m -s /bin/bash $username
		# Check if the user is created successfully
		if [ $? -ne 0 ]; then
			warn "Failed to create user $username"
			return 1
		fi
	fi
	chown -R $username:$username /home/$username
	#Check if cache is specified
	if [ -z "$cache" ]; then
		warn "Cache is not specified"
		need_input "Please enter a cache size (in MB):"
		read cache
		#Check if cache is a number
		while true
		do
			if ! [[ "$cache" =~ ^[0-9]+$ ]]; then
				warn "Cache must be a number"
				need_input "Please enter a cache size (in MB):"
				read cache
			else
				break
			fi
		done
		qb_cache=$cache
	fi
	#Check if qBittorrent version is specified
	if [ -z "$qb_ver" ]; then
		warn "qBittorrent version is not specified"
		qb_ver_check
	fi
	#Check if libtorrent version is specified
	if [ -z "$lib_ver" ]; then
		warn "libtorrent version is not specified"
		lib_ver_check
	fi

	## qBittorrent & libtorrent compatibility check
	qb_install_check

	## Install qBittorrent (single or multiple instances)
	if [[ ! -z "$multi_qb_install" ]]; then
		# Install multiple qBittorrent instances
		install_multi_qb_ "$username" "$password" "$qb_ver" "$lib_ver" "$qb_cache"
	else
		# Install single qBittorrent instance
		qb_port=${qb_port:-8080}
		qb_incoming_port=${qb_incoming_port:-45000}
		install_ "install_qBittorrent_ $username $password $qb_ver $lib_ver $qb_cache $qb_port $qb_incoming_port" "Installing qBittorrent" "/tmp/qb_error" qb_install_success
	fi
fi

# autobrr Install
if [[ ! -z "$autobrr_install" ]]; then
	if [ -z "$autobrr_port" ]; then
		autobrr_port=7474
	fi
	install_ "install_autobrr_ $autobrr_port" "Installing autobrr" "/tmp/autobrr_error" autobrr_install_success
fi

# vertex Install
if [[ ! -z "$vertex_install" ]]; then
	if [ -z "$vertex_port" ]; then
		vertex_port=8081
	fi
	install_ "install_vertex_ $vertex_port" "Installing vertex" "/tmp/vertex_error" vertex_install_success
fi

# autoremove-torrents Install
if [[ ! -z "$autoremove_install" ]]; then
	install_ install_autoremove-torrents_ "Installing autoremove-torrents" "/tmp/autoremove_error" autoremove_install_success
fi

seperator

## Tunning
info "Start Doing System Tunning"
install_ tuned_ "Installing tuned" "/tmp/tuned_error" tuned_success
install_ set_txqueuelen_ "Setting txqueuelen" "/tmp/txqueuelen_error" txqueuelen_success
install_ set_file_open_limit_ "Setting File Open Limit" "/tmp/file_open_limit_error" file_open_limit_success

# Check for Virtual Environment since some of the tunning might not work on virtual machine
systemd-detect-virt > /dev/null
if [ $? -eq 0 ]; then
	warn "Virtualization is detected, skipping some of the tunning"
	install_ disable_tso_ "Disabling TSO" "/tmp/tso_error" tso_success
else
	install_ set_disk_scheduler_ "Setting Disk Scheduler" "/tmp/disk_scheduler_error" disk_scheduler_success
	install_ set_ring_buffer_ "Setting Ring Buffer" "/tmp/ring_buffer_error" ring_buffer_success
fi
install_ set_initial_congestion_window_ "Setting Initial Congestion Window" "/tmp/initial_congestion_window_error" initial_congestion_window_success
install_ kernel_settings_ "Setting Kernel Settings" "/tmp/kernel_settings_error" kernel_settings_success

# BBRx
if [[ ! -z "$bbrx_install" ]]; then
	# Check if Tweaked BBR is already installed
	if [[ ! -z "$(lsmod | grep bbrx)" ]]; then
		warn "Tweaked BBR is already installed"
	else
		install_ install_bbrx_ "Installing BBRx" "/tmp/bbrx_error" bbrx_install_success
	fi
fi

# BBRv3
if [[ ! -z "$bbrv3_install" ]]; then
	install_ install_bbrv3_ "Installing BBRv3" "/tmp/bbrv3_error" bbrv3_install_success
fi

## Configue Boot Script
info "Start Configuing Boot Script"
touch /root/.boot-script.sh && chmod +x /root/.boot-script.sh
cat << EOF > /root/.boot-script.sh
#!/bin/bash
sleep 120s
source <(wget -qO- https://raw.githubusercontent.com/jerry048/Seedbox-Components/main/seedbox_installation.sh)
# Check if Seedbox Components is successfully loaded
if [ \$? -ne 0 ]; then
	exit 1
fi
set_txqueuelen_
# Check for Virtual Environment since some of the tunning might not work on virtual machine
systemd-detect-virt > /dev/null
if [ \$? -eq 0 ]; then
	disable_tso_
else
	set_disk_scheduler_
	set_ring_buffer_
fi
set_initial_congestion_window_
EOF

# Configure the script to run during system startup
cat << EOF > /etc/systemd/system/boot-script.service
[Unit]
Description=boot-script
After=network.target

[Service]
Type=simple
ExecStart=/root/.boot-script.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF
systemctl enable boot-script.service

seperator

## Finalizing the install
info "Seedbox Installation Complete"
publicip=$(curl -s https://ipinfo.io/ip)

# Display Username and Password
# qBittorrent
if [[ ! -z "$multi_qb_install" ]]; then
	info "4 qBittorrent instances installed"
	for i in {1..4}; do
		local port=$((8079 + i))  # 8080, 8081, 8082, 8083
		if [[ ! -z "$(eval echo \$qb_install_success_${i})" ]]; then
			boring_text "qBittorrent Instance ${i} WebUI: http://$publicip:$port"
		fi
	done
	boring_text "qBittorrent Username: $username"
	boring_text "qBittorrent Password: $password"
	echo -e "\n"
elif [[ ! -z "$qb_install_success" ]]; then
	info "qBittorrent installed"
	boring_text "qBittorrent WebUI: http://$publicip:${qb_port:-8080}"
	boring_text "qBittorrent Username: $username"
	boring_text "qBittorrent Password: $password"
	echo -e "\n"
fi

# autoremove-torrents
if [[ ! -z "$autoremove_install_success" ]]; then
	info "autoremove-torrents installed"
	boring_text "Config at /home/$username/.config.yml"
	boring_text "Please read https://autoremove-torrents.readthedocs.io/en/latest/config.html for configuration"
	echo -e "\n"
fi

# autobrr
if [[ ! -z "$autobrr_install_success" ]]; then
	info "autobrr installed"
	boring_text "autobrr WebUI: http://$publicip:${autobrr_port:-7474}"
	echo -e "\n"
fi

# vertex
if [[ ! -z "$vertex_install_success" ]]; then
	info "vertex installed"
	boring_text "vertex WebUI: http://$publicip:${vertex_port:-8081}"
	boring_text "vertex Username: $username"
	boring_text "vertex Password: $password"
	echo -e "\n"
fi

# BBR
if [[ ! -z "$bbrx_install_success" ]]; then
	info "BBRx successfully installed, please reboot for it to take effect"
fi

if [[ ! -z "$bbrv3_install_success" ]]; then
	info "BBRv3 successfully installed, please reboot for it to take effect"
fi

# Service management instructions
if [[ ! -z "$multi_qb_install" ]]; then
	info "qBittorrent Service Management:"
	boring_text "Start all instances: systemctl start qbittorrent-{1..4}"
	boring_text "Stop all instances: systemctl stop qbittorrent-{1..4}"
	boring_text "Check status: systemctl status qbittorrent-{1..4}"
fi

exit 0
