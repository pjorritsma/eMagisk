#!/system/bin/sh

# Base stuff we need
POGOPKG=com.nianticlabs.pokemongo
UNINSTALLPKGS="com.ionitech.airscreen cm.aptoidetv.pt com.netflix.mediaclient org.xbmc.kodi com.google.android.youtube.tv"
CONFIGFILE='/data/local/tmp/emagisk.config'
setprop net.dns1 1.1.1.1 && setprop net.dns2 4.4.4.4

# Check for the mitm pkg

get_mitm_pkg() { # This function is so hardcoded that I'm allergic to it 
	ps aux | grep -E -C0 "atlas|gocheats" | grep -C0 -v grep | awk -F ' ' '/com.pokemod.atlas/{print $NF} /com.gocheats.launcher/{print $NF}' | grep -E -C0 "atlas|gocheats" | sed 's/^[0-9]*://' | sed 's/:mapping$//'
}

check_mitmpkg() {
	if [ "$(pm list packages com.gocheats.launcher)" = "package:com.gocheats.launcher" ]; then
		log -p i -t eMagiskATVService "Found GC!"
		MITMPKG=com.gocheats.launcher
	elif [ "$(pm list packages com.pokemod.atlas.beta)" = "package:com.pokemod.atlas.beta" ]; then
		log -p i -t eMagiskATVService "Found Atlas developer version!"
		MITMPKG=com.pokemod.atlas.beta
	elif [ "$(pm list packages com.pokemod.atlas)" = "package:com.pokemod.atlas" ]; then
		log -p i -t eMagiskATVService "Found Atlas production version!"
		MITMPKG=com.pokemod.atlas
	else
		log -p i -t eMagiskATVService "No MITM installed. Abort!"
		exit 1
	fi
}

# This is for the X96 Mini and X96W Atvs. Can be adapted to other ATVs that have a led status indicator

led_red(){
    if [ -e /sys/class/leds/led-sys ]; then
        echo 0 > /sys/class/leds/led-sys/brightness
    fi
}

led_blue(){
    if [ -e /sys/class/leds/led-sys ]; then
        echo 1 > /sys/class/leds/led-sys/brightness
    fi
}

# Stops MITM and Pogo and restarts MITM MappingService

force_restart() {
	killall com.nianticlabs.pokemongo
	if [ "$(pm list packages com.gocheats.launcher)" = "package:com.gocheats.launcher" ]; then
		am force-stop $MITMPKG
		sleep 5
		monkey -p $MITMPKG 1
	else
		am stopservice $MITMPKG/com.pokemod.atlas.services.MappingService
		am force-stop $POGOPKG
		am force-stop $MITMPKG
		sleep 5
		android_version=$(getprop ro.build.version.release)
		if [ "$(echo $android_version | cut -d. -f1)" -ge 8 ]; then
			monkey -p $MITMPKG 1 # To solve "Error: app is in background uid null"
			sleep 3
   			input keyevent KEYCODE_HOME
		fi
		am startservice $MITMPKG/com.pokemod.atlas.services.MappingService
	fi
	log -p i -t eMagiskATVService "Services were restarted!"
}

# Adjust the script depending on MITM

check_mitmpkg

# Send a webhook to discord if it's configured

webhook() {
	# Check if discord_webhook variable is set
	if [[ -z "$discord_webhook" ]]; then
		log -p i -t eMagiskATVService "discord_webhook variable is not set. Cannot send webhook."
		return
	fi

	# Check internet connectivity by pinging 8.8.8.8 and 1.1.1.1
	if ! ping -c 1 -W 1 8.8.8.8 >/dev/null && ! ping -c 1 -W 1 1.1.1.1 >/dev/null; then
		log -p i -t eMagiskATVService "No internet connectivity. Skipping webhook."
		return
	fi

	local message="$1"
	local local_ip="$(ip route get 1.1.1.1 | awk '{print $7}')"
	local wan_ip="$(curl -s -k https://ipinfo.io/ip)"
	local mac_address="$(ip link show eth0 | awk '/ether/ {print $2}')"
	local mac_address_nodots="$(ip link show eth0 | awk '/ether/ {print $2}' | tr -d ':')"
	local timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
	local mitm_version="NOT INSTALLED"
	local pogo_version="NOT INSTALLED"
	local agent=""
	local playStoreVersion=""
	local temperature="$(cat /sys/class/thermal/thermal_zone0/temp | awk '{print substr($0, 1, length($0)-3)}')"
	playStoreVersion=$(dumpsys package com.android.vending | grep versionName | head -n 1 | cut -d "=" -f 2 | cut -d " " -f 1)
	android_version=$(getprop ro.build.version.release)
	
	mitmDeviceName="NO NAME"
	if [ -f /data/local/tmp/atlas_config.json ]; then
	mitmDeviceName=$(cat /data/local/tmp/atlas_config.json | awk -F\" '{print $12}')
	else
	mitmDeviceName=$(cat /data/local/tmp/config.json | awk -F\" '/device_name/ {print $4}')
	fi

	# Get mitm version
	mitm_version="$(dumpsys package "$MITMPKG" | awk -F "=" '/versionName/ {print $2}')"

	# Get pogo version
	pogo_version="$(dumpsys package com.nianticlabs.pokemongo | awk -F "=" '/versionName/ {print $2}')"

	# Create a temporary directory to store the files
	local temp_dir="/data/local/tmp/webhook_${timestamp}"
	mkdir "$temp_dir"

	# Retrieve the logcat logs
	logcat -v colors -d > "$temp_dir/logcat_${MITMPKG}_${timestamp}_${mac_address_nodots}_selfSentLog.log"
	
	# Create the payload JSON
	local payload_json="{\"username\":\"$mitmDeviceName\",\"content\":\"$message"
	payload_json+="\\n*Device name*: $mitmDeviceName"
	payload_json+="\\nLocal IP: ||$local_ip||"
	payload_json+="\\nWAN IP: ||$wan_ip||"
	payload_json+="\\nmac: $mac_address"
	payload_json+="\\nTemp: $temperature"
	payload_json+="\\nmitm: $MITMPKG"
	payload_json+="\\nmitm version: $mitm_version"
	if [[ -n "$agent" ]]; then
		payload_json+="\\nmitm agent: $agent"
	fi
	payload_json+="\\npogo version: $pogo_version"
	payload_json+="\\nPlay Store version: $playStoreVersion"
	payload_json+="\\nAndroid version: $android_version"
	payload_json+="\"}"

	log -p i -t eMagiskATVService "Sending discord webhook"
	# Upload the payload JSON and logcat logs to Discord
	if [[ $MITMPKG == com.pokemod.atlas* ]]; then
		curl -X POST -k -H "Content-Type: multipart/form-data" -F "payload_json=$payload_json" "$discord_webhook" -F "logcat=@$temp_dir/logcat_${MITMPKG}_${timestamp}_${mac_address_nodots}_selfSentLog.log" -F "atlaslog=@/data/local/tmp/atlas.log"
	else
		curl -X POST -k -H "Content-Type: multipart/form-data" -F "payload_json=$payload_json" "$discord_webhook" -F "logcat=@$temp_dir/logcat_${MITMPKG}_${timestamp}_${mac_address_nodots}_selfSentLog.log"
	fi
	# Clean up temporary files
	rm -rf "$temp_dir"
}

# Recheck if $CONFIGFILE exists and has data. Repulls data and checks the RDM connection status.

configfile_rdm() {
	if [[ -s $CONFIGFILE ]]; then
		log -p i -t eMagiskATVService "$CONFIGFILE exists and has data. Data will be pulled."
		source $CONFIGFILE
		export rdm_user rdm_password rdm_backendURL discord_webhook timezone autoupdate heartbeat_endpoint heartbeat_secret
	else
		log -p i -t eMagiskATVService "Failed to pull the info. Make sure $($CONFIGFILE) exists and has the correct data."
	fi

	# RDM connection check

	rdmConnect=$(curl -s -k -o /dev/null -w "%{http_code}" -u $rdm_user:$rdm_password "$rdm_backendURL/api/get_data?show_devices=true")
	if [[ $rdmConnect = "200" ]]; then
		log -p i -t eMagiskATVService "RDM connection status: $rdmConnect"
		log -p i -t eMagiskATVService "RDM Connection was successful!"
		led_red
	elif [[ $rdmConnect = "401" ]]; then
		log -p i -t eMagiskATVService "RDM connection status: $rdmConnect -> Recheck in 4 minutes"
		log -p i -t eMagiskATVService "Check your $CONFIGFILE values, credentials and rdm_user permissions!"
		led_blue
		webhook "Check your $CONFIGFILE values, credentials and rdm_user permissions! RDM connection status: $rdmConnect"
		sleep $((240+$RANDOM%10))
	elif [[ $rdmConnect = "Internal" ]]; then
		log -p i -t eMagiskATVService "RDM connection status: $rdmConnect -> Recheck in 4 minutes"
		log -p i -t eMagiskATVService "The RDM Server couldn't response properly to eMagisk!"
		led_red
		webhook "The RDM Server couldn't response properly to eMagisk! RDM connection status: $rdmConnect"
		sleep $((240+$RANDOM%10))

	elif [[ -z $rdmConnect ]]; then
		log -p i -t eMagiskATVService "RDM connection status: $rdmConnect -> Recheck in 4 minutes"
		log -p i -t eMagiskATVService "Check your ATV internet connection!"
		led_blue
		webhook "Check your ATV internet connection! RDM connection status: $rdmConnect"
		counter=$((counter+1))
		if [[ $counter -gt 4 ]];then
			log -p i -t eMagiskATVService "Critical restart threshold of $counter reached. Rebooting device..."
			reboot
			# We need to wait for the reboot to actually happen or the process might be interrupted
			sleep 60 
		fi
		sleep $((240+$RANDOM%10))
	else
		log -p i -t eMagiskATVService "RDM connection status: $rdmConnect -> Recheck in 4 minutes"
		log -p i -t eMagiskATVService "Something different went wrong..."
		led_blue
		webhook "Something different went wrong..."
		sleep $((240+$RANDOM%10))
	fi
}

autoupdate() {
	# Autoupdate this script
	# emagisk_version=$(grep -o 'versionCode=[0-9]*' /data/adb/modules/emagisk/module.prop -C0 | cut -d '=' -f 2)
	autoupdate_url="https://raw.githubusercontent.com/Astu04/eMagisk/master/custom/ATVServices.sh"
	script_path="/data/adb/modules/emagisk/ATVServices.sh"
	cd /data/local/tmp/

	# Download the updated script
	curl_output=$(curl --silent --show-error --location --insecure --max-time 3 --write-out "%{http_code}" --output updated_script.sh "$autoupdate_url")
	http_status=${curl_output:(-3)}

	# Check if the HTTP status is 200 (OK)
	if [[ $http_status -eq 200 ]]; then
	  # Check if the first line of the updated script is #!/system/bin/sh
	  first_line=$(head -n 1 updated_script.sh)
	  if [[ $first_line = '#!/system/bin/sh' ]]; then
		# Compare the content of the downloaded script with the existing script
		if ! cmp -s updated_script.sh "$script_path"; then
		  # Replace the script with the updated version
		  chmod +x updated_script.sh
		  mv updated_script.sh "$script_path"
		  
		  log -p i -t eMagiskATVService "[AUTOUPDATE] ATVServices.sh was auto updated"
		  webhook "[AUTOUPDATE] ATVServices.sh was auto updated"

		  # Run the updated script as a daemon
		  nohup "$script_path" >/dev/null 2>&1 &

		  # Kill the parent process
		  pkill -f "$0"
		else
		  log -p i -t eMagiskATVService  "[AUTOUPDATE] The downloaded script is identical to the existing script."
		  rm -f updated_script.sh
		fi
	  else
		log -p i -t eMagiskATVService  "[AUTOUPDATE] The downloaded script does not have the expected shebang."
		log -p i -t eMagiskATVService  "[AUTOUPDATE] It had: $first_line"
		webhook "[AUTOUPDATE] The downloaded script does not have the expected shebang."
	  fi
	else
	  log -p i -t eMagiskATVService  "[AUTOUPDATE] Failed to download the updated script. HTTP status code: $http_status"
	  webhook "[AUTOUPDATE] Failed to download the updated script. HTTP status code: $http_status"
	fi
}

configfile_rdm
if [ "$autoupdate" = "true" ]; then
  log -p i -t eMagiskATVService "[AUTOUPDATE] Checking for new updates"
  autoupdate
else
  log -p i -t eMagiskATVService "[AUTOUPDATE] Disabled. Skipping"
fi

# Wipe out packages we don't need in our ATV

echo "$UNINSTALLPKGS" | tr ' ' '\n' | while read -r item; do
	if ! dumpsys package "$item" | \grep -qm1 "Unable to find package"; then
		log -p i -t eMagiskATVService "Uninstalling $item..."
		pm uninstall "$item"
	fi
done

# Disable playstore alltogether (no auto updates)

# if [ "$(pm list packages -e com.android.vending)" = "package:com.android.vending" ]; then
	# log -p i -t eMagiskATVService "Disabling Play Store"
	# pm disable-user com.android.vending
# fi

# Check if the magiskhide binary exists
if type magiskhide >/dev/null 2>&1; then
    # Enable Magiskhide if not enabled
    if ! magiskhide status; then
        log -p i -t eMagiskATVService "Enabling MagiskHide"
        magiskhide enable
    fi

    # Add Pokemon Go to Magisk hide if it isn't
    if ! magiskhide ls | grep -q -m1 "$POGOPKG"; then
        log -p i -t eMagiskATVService "Adding PoGo to MagiskHide"
        magiskhide add "$POGOPKG"
    fi
fi

# Give all mitm services root permissions

# Check if magisk version is 23000 or less

if [ "$(magisk -V)" -le 23000 ]; then
    for package in "$MITMPKG" com.android.shell; do
        packageUID=$(dumpsys package "$package" | grep userId | head -n1 | cut -d= -f2)
        policy=$(sqlite3 /data/adb/magisk.db "select policy from policies where package_name='$package'")
        if [ "$policy" != 2 ]; then
            log -p i -t eMagiskATVService "$package current policy is $policy. Adding root permissions..."
            if ! sqlite3 /data/adb/magisk.db "DELETE from policies WHERE package_name='$package'" ||
                ! sqlite3 /data/adb/magisk.db "INSERT INTO policies (uid,package_name,policy,until,logging,notification) VALUES($packageUID,'$package',2,0,1,1)"; then
                log -p i -t eMagiskATVService "ERROR: Could not add $package (UID: $packageUID) to Magisk's DB."
            fi
        else
            log -p i -t eMagiskATVService "Root permissions for $package are OK!"
        fi
    done
else
    log -p i -t eMagiskATVService "Magisk version is higher than 23000. Not checking for magisk's policies."
fi

# Set mitm mock location permission as ignore

if ! appops get $MITMPKG android:mock_location | grep -qm1 'No operations'; then
	log -p i -t eMagiskATVService "Removing mock location permissions from $MITMPKG"
	appops set $MITMPKG android:mock_location 2
fi

# Disable all location providers

if ! settings get; then
	log -p i -t eMagiskATVService "Checking allowed location providers as 'shell' user"
	allowedProviders=".$(su shell -c settings get secure location_providers_allowed)"
else
	log -p i -t eMagiskATVService "Checking allowed location providers"
	allowedProviders=".$(settings get secure location_providers_allowed)"
fi

if [ "$allowedProviders" != "." ]; then
	log -p i -t eMagiskATVService "Disabling location providers..."
	if ! settings put secure location_providers_allowed -gps,-wifi,-bluetooth,-network >/dev/null; then
		log -p i -t eMagiskATVService "Running as 'shell' user"
		su shell -c 'settings put secure location_providers_allowed -gps,-wifi,-bluetooth,-network'
	fi
fi

# Make sure the device doesn't randomly turn off

if [ "$(settings get global stay_on_while_plugged_in)" != 3 ]; then
	log -p i -t eMagiskATVService "Setting Stay On While Plugged In"
	settings put global stay_on_while_plugged_in 3
fi

# Disable package verifier

if [ "$(settings get global package_verifier_enable)" != 0 ]; then
	log -p i -t eMagiskATVService "Disable package verifier"
	settings put global package_verifier_enable 0
fi
if [ "$(settings get global verifier_verify_adb_installs)" != 0 ]; then
	log -p i -t eMagiskATVService "Disable package verifier over adb"
	settings put global verifier_verify_adb_installs 0
fi

# Disable play protect

if [ "$(settings get global package_verifier_user_consent)" != -1 ]; then
	log -p i -t eMagiskATVService "Disable play protect"
	settings put global package_verifier_user_consent -1
fi

# Check if the timezone variable is set

if [ -n "$timezone" ]; then
	# Set the timezone using the variable
	setprop persist.sys.timezone "$timezone"
	log -p i -t eMagiskATVService "Timezone set to $timezone"
else
	log -p i -t eMagiskATVService "Timezone variable not set. Skipping timezone change."
fi

# Check if ADB is disabled (adb_enabled is set to 0)

adb_status=$(settings get global adb_enabled)
if [ "$adb_status" -eq 0 ]; then
	log -p i -t eMagiskATVService "ADB is currently disabled. Enabling it..."
	settings put global adb_enabled 1
fi

# Check and set permissions for adb_keys

adb_keys_file="/data/misc/adb/adb_keys"
if [ -e "$adb_keys_file" ]; then
    current_permissions=$(stat -c %a "$adb_keys_file")
    if [ "$current_permissions" -ne 640 ]; then
        log -p i -t eMagiskATVService  "Changing permissions for $adb_keys_file to 640..."
        chmod 640 "$adb_keys_file"
    fi
fi

# Download cacert to use certs instead of curl -k 

cacert_path="/data/local/tmp/cacert.pem"
if [ ! -f "$cacert_path" ]; then
	log -p i -t eMagiskATVService "Downloading cacert.pem..."
	curl -k -o "$cacert_path" https://curl.se/ca/cacert.pem
fi

# Add a heartbeat to monitor if eMagisk can't contact the server

function send_heartbeat() {
	if [ -z "$heartbeat_endpoint" ]; then
		log -p i -t eMagiskATVService "heartbeat_endpoint is null. Doing nothing."
		return
	fi

	mitmDeviceName="NO NAME"
	if [ -f "/data/local/tmp/atlas_config.json" ]; then
		mitmDeviceName=$(cat "/data/local/tmp/atlas_config.json" | awk -F\" '{print $12}')
	else
		mitmDeviceName=$(cat "/data/local/tmp/config.json" | awk -F\" '/device_name/ {print $4}')
	fi

	# Assuming heartbeat_secret is previously defined.
	json_data="{\"mitmDeviceName\":\"$mitmDeviceName\", \"secret\":\"$heartbeat_secret\"}"

	# Sending the JSON data to the endpoint using curl with the cacert.pem.
	curl --cacert "$cacert_path" -X POST -H "Content-Type: application/json" -d "$json_data" "$heartbeat_endpoint"
}

# Health Service by Emi and Bubble with a little root touch

if result=$(check_mitmpkg); then
	(
		log -p i -t eMagiskATVService "eMagisk: Astu's fork. Starting health check service in 4 minutes..."
		counter=0
		rdmDeviceID=1
		log -p i -t eMagiskATVService "Start counter at $counter"
		configfile_rdm
		webhook "Booting"
		send_heartbeat
		while :; do
			configfile_rdm	  
			sleep $((240+$RANDOM%10))
			send_heartbeat

			if [ -f /data/local/tmp/atlas_config.json ]; then
				mitmDeviceName=$(jq -r '.deviceName'  /data/local/tmp/atlas_config.json)
			elif [ -f /data/local/tmp/config.json ]; then
				mitmDeviceName=$(jq -r '.device_name' /data/local/tmp/config.json)
			else
				log -p -i -t eMagiskATVService "Couldn't find the config file"
			fi

			if tail -n 1 /data/local/tmp/atlas.log | grep -q "Could not send heartbeat"; then
				force_restart
			fi

			if [[ $counter -gt 3 ]];then
				log -p i -t eMagiskATVService "Critical restart threshold of $counter reached. Rebooting device..."
				webhook "Critical restart threshold of $counter reached. Rebooting device..."
				reboot
				# We need to wait for the reboot to actually happen or the process might be interrupted
				sleep 60 
			fi

			log -p i -t eMagiskATVService "Started health check!"
			response=$(curl -s -w "%{http_code}" --cacert "$cacert_path" -u "$rdm_user":"$rdm_password" "$rdm_backendURL/api/get_data?show_devices=true&formatted=false")
			statusCode=$(echo "$response" | tail -c 4)
			
			if [ "$statusCode" -ne 200 ]; then
				case "$statusCode" in
					401)
						message="Unauthorized. Check your credentials."
						;;
					404)
						message="Resource not found."
						;;
					500)
						message="Internal Server Error. Check the server logs."
						;;
					*)
						message="Something went wrong with the request. Status code: $statusCode."
						;;
				esac

				log -p i -t eMagiskATVService "RDM statusCode error: $message"
				continue
			fi
			
			rdmInfo=$(echo "$response" | sed '$s/...$//')
			
			devices=$(echo "$rdmInfo" | jq -r '.data.devices[].uuid' | grep "^$mitmDeviceName")
 			IFS=$'\n'
			for device in "$devices"; do
				rdmDeviceLastSeen=$(echo "$rdmInfo" | jq -r --arg device "$device" '.data.devices[] | select(.uuid == $mitmDeviceName) | .last_seen')
				if [ -z "$rdmDeviceLastSeen" ]; then
					log -p i -t eMagiskATVService "No matching device name $device found in the JSON data or the last seen is null. Check RDM's devices."
					continue # Stopping this iteration
				fi

				log -p i -t eMagiskATVService "Found our device! Checking for timestamps..."
				now="$(date +'%s')"
				calcTimeDiff=$(($now - $rdmDeviceLastSeen))

				if [[ $calcTimeDiff -gt 300 ]]; then
					log -p i -t eMagiskATVService "Last seen at RDM is greater than 5 minutes -> MITM Service will be restarting..."
					force_restart
					led_blue
					counter=$((counter+1))
					log -p i -t eMagiskATVService "Counter is now set at $counter. device will be rebooted if counter reaches 4 failed restarts."
					webhook "Counter is now set at $counter. device will be rebooted if counter reaches 4 failed restarts."
					continue
				elif [[ $calcTimeDiff -le 10 ]]; then
					log -p i -t eMagiskATVService "Our device is live!"
					counter=0
					led_red
				else
					log -p i -t eMagiskATVService "Last seen time is a bit off. Will check again later."
					counter=0
					led_red
				fi
			done
			log -p i -t eMagiskATVService "Scheduling next check in 4 minutes..."
		done
	) &
else
	log -p i -t eMagiskATVService "MITM isn't installed on this device! The daemon will stop."
fi
