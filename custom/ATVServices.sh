#!/system/bin/sh

# Base stuff we need
POGOPKG=com.nianticlabs.pokemongo
UNINSTALLPKGS="com.ionitech.airscreen cm.aptoidetv.pt com.netflix.mediaclient org.xbmc.kodi com.google.android.youtube.tv"
CONFIGFILE='/data/local/tmp/emagisk.config'

autoupdate() {
	# Autoupdate this script
	# emagisk_version=$(grep -o 'versionCode=[0-9]*' /data/adb/modules/emagisk/module.prop -C0 | cut -d '=' -f 2)
	autoupdate_url="https://raw.githubusercontent.com/Astu04/eMagisk/master/custom/ATVServices.sh"
	script_path="/data/adb/modules/emagisk/ATVServices.sh"
	cd /data/local/tmp/

	# Download the updated script
	curl_output=$(curl --silent --show-error --location --insecure --write-out "%{http_code}" --output updated_script.sh "$autoupdate_url")
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
		  
		  log -p i -t eMagiskATVService "ATVServices.sh was auto updated"

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
	  fi
	else
	  log -p i -t eMagiskATVService  "[AUTOUPDATE] Failed to download the updated script. HTTP status code: $http_status"
	fi
}

# Check if this is a beta or production device

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
	echo 0 > /sys/class/leds/led-sys/brightness
}

led_blue(){
	echo 1 > /sys/class/leds/led-sys/brightness
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
		am startservice $MITMPKG/com.pokemod.atlas.services.MappingService
	fi
	log -p i -t eMagiskATVService "Services were restarted!"
}

# Recheck if $CONFIGFILE exists and has data. Repulls data and checks the RDM connection status.

configfile_rdm() {
    if [[ -s $CONFIGFILE ]]; then
        log -p i -t eMagiskATVService "$CONFIGFILE exists and has data. Data will be pulled."
        source $CONFIGFILE
        export rdm_user rdm_password rdm_backendURL timezone autoupdate
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
        sleep $((240+$RANDOM%10))
    elif [[ $rdmConnect = "Internal" ]]; then
        log -p i -t eMagiskATVService "RDM connection status: $rdmConnect -> Recheck in 4 minutes"
        log -p i -t eMagiskATVService "The RDM Server couldn't response properly to eMagisk!"
        led_red
        sleep $((240+$RANDOM%10))

    elif [[ -z $rdmConnect ]]; then
        log -p i -t eMagiskATVService "RDM connection status: $rdmConnect -> Recheck in 4 minutes"
        log -p i -t eMagiskATVService "Check your ATV internet connection!"
        led_blue
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
        sleep $((240+$RANDOM%10))
    fi
}

# Adjust the script depending on MITM, Atlas production, Atlas beta or GC

check_mitmpkg

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

# Enable Magiskhide if not enabled

if ! magiskhide status; then
	log -p i -t eMagiskATVService "Enabling MagiskHide"
	magiskhide enable
fi

# Add pokemon go to Magisk hide if it isn't

if ! magiskhide ls | grep -m1 $POGOPKG; then
	log -p i -t eMagiskATVService "Adding PoGo to MagiskHide"
	magiskhide add $POGOPKG
fi

# Give all mitm services root permissions

for package in $MITMPKG com.android.shell; do
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

# Check if the timezone variable is set
if [ -n "$timezone" ]; then
    # Set the timezone using the variable
    setprop persist.sys.timezone "$timezone"
    echo "Timezone set to $timezone"
else
    echo "Timezone variable not set. Skipping timezone change."
fi

# Health Service by Emi and Bubble with a little root touch

if [ "$(pm list packages $MITMPKG)" = "package:$MITMPKG" ]; then
    (
        log -p i -t eMagiskATVService "eMagisk v$(cat "$MODDIR/version_lock"). Starting health check service in 4 minutes..."
        counter=0
        rdmDeviceID=1
        log -p i -t eMagiskATVService "Start counter at $counter"
        while :; do
            configfile_rdm
	    if [ "$autoupdate" = "true" ]; then
              autoupdate()
	    fi			  
            sleep $((240+$RANDOM%10))        

            if [[ $counter -gt 3 ]];then
            log -p i -t eMagiskATVService "Critical restart threshold of $counter reached. Rebooting device..."
            reboot
            # We need to wait for the reboot to actually happen or the process might be interrupted
            sleep 60 
            fi

            log -p i -t eMagiskATVService "Started health check!"
			if [ -f /data/local/tmp/atlas_config.json ]; then
				mitmDeviceName=$(cat /data/local/tmp/atlas_config.json | awk -F\" '{print $12}')
			else
				mitmDeviceName=$(cat /data/local/tmp/config.json | awk -F\" '/device_name/ {print $4}')
			fi
	        rdmDeviceInfo=$(curl -s -k -u $rdm_user:$rdm_password "$rdm_backendURL/api/get_data?show_devices=true&formatted=true"  | awk -F\[ '{print $2}' | awk -F\}\,\{\" '{print $'$rdmDeviceID'}')
            rdmDeviceName=$(curl -s -k -u $rdm_user:$rdm_password "$rdm_backendURL/api/get_data?show_devices=true&formatted=true" | awk -F\[ '{print $2}' | awk -F\}\,\{\" '{print $'$rdmDeviceID'}' | awk -Fuuid\"\:\" '{print $2}' | awk -F\" '{print $1}')
	
	        until [[ $rdmDeviceName = $mitmDeviceName ]]
	        do
		        $((rdmDeviceID++))
		        rdmDeviceInfo=$(curl -s -k -u $rdm_user:$rdm_password "$rdm_backendURL/api/get_data?show_devices=true&formatted=true" | awk -F\[ '{print $2}' | awk -F\}\,\{\" '{print $'$rdmDeviceID'}')
		        rdmDeviceName=$(curl -s -k -u $rdm_user:$rdm_password "$rdm_backendURL/api/get_data?show_devices=true&formatted=true" | awk -F\[ '{print $2}' | awk -F\}\,\{\" '{print $'$rdmDeviceID'}' | awk -Fuuid\"\:\" '{print $2}' | awk -F\" '{print $1}')
		
		        if [[ -z $rdmDeviceInfo ]]; then
                    log -p i -t eMagiskATVService "Probably reached end of device list or encountered a different issue!"
                    log -p i -t eMagiskATVService "Set RDM Device ID to 1, recheck RDM connection and repull $CONFIGFILE"
			        rdmDeviceID=1
                    #repull rdm values + recheck rdm connection
                    configfile_rdm
			        rdmDeviceName=$(curl -s -k -u $rdm_user:$rdm_password "$rdm_backendURL/api/get_data?show_devices=true&formatted=true" | awk -F\[ '{print $2}' | awk -F\}\,\{\" '{print $'$rdmDeviceID'}' | awk -Fuuid\"\:\" '{print $2}' | awk -F\" '{print $1}')
		        fi	
	        done
	
	        log -p i -t eMagiskATVService "Found our device! Checking for timestamps..."
	        rdmDeviceLastseen=$(curl -s -k -u $rdm_user:$rdm_password "$rdm_backendURL/api/get_data?show_devices=true&formatted=true" | awk -F\[ '{print $2}' | awk -F\}\,\{\" '{print $'$rdmDeviceID'}' | awk -Flast_seen\"\:\{\" '{print $2}' | awk -Ftimestamp\"\: '{print $2}' | awk -F\, '{print $1}' | sed 's/}//g')
		if [[ -z $rdmDeviceLastseen ]]; then
			log -p i -t eMagiskATVService "The device last seen status is empty!"
		else
	        	now="$(date +'%s')"
	        	calcTimeDiff=$(($now - $rdmDeviceLastseen))
	
	        	if [[ $calcTimeDiff -gt 300 ]]; then
		        	log -p i -t eMagiskATVService "Last seen at RDM is greater than 5 minutes -> MITM Service will be restarting..."
		        	force_restart
					led_blue
					counter=$((counter+1))
					log -p i -t eMagiskATVService "Counter is now set at $counter. device will be rebooted if counter reaches 4 failed restarts."
	        	elif [[ $calcTimeDiff -le 10 ]]; then
		        	log -p i -t eMagiskATVService "Our device is live!"
                		counter=0
                		led_red
	        	else
		        	log -p i -t eMagiskATVService "Last seen time is a bit off. Will check again later."
                	counter=0
                	led_red
	        	fi
		fi
            log -p i -t eMagiskATVService "Scheduling next check in 4 minutes..."
        done
    ) &
else
    log -p i -t eMagiskATVService "MITM isn't installed on this device! The daemon will stop."
fi
