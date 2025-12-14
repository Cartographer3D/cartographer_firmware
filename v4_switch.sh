echo "-------------------------------------------------------------"
echo "Cartographer V4 Firmware Switch"
echo "-------------------------------------------------------------"
echo ""
echo "Please confirm that your probe is a Cartographer V4:"
echo ""
cat << 'EOF'
                                                                                               
       ................................::::::::::::::::::::-------------=============.         
    .:+++#%*+*#+=+#*#*%%*+*%#++#%%*-=====+++++++++++++++=:#%%%%%##%#%%%%#*##+%#==*%+-=#:.      
    .##+=#%*++%%%%%%%%#%%#%%#%%%%%#-======++++**++++++++=-#%%%%%%%%%#*%%%+*#+#%#*%%#*#%=.      
    :#%%%%%%%%%%%%%%#%%%%%%%%%%%#*#--==++=+++++++++++++==:#%%%%%%%%#%%%%%*#%%%%##%%#*+=-.      
    :*+#%%%%%%%%%%%%%%%%%%%%%%%##*#--=+++++++++++*++++++=:#%%%%%%%%%*%%%#%%%%%%%%#%%#+=-.      
    :###%%%%%#%%%#%#%%%%%%%%%%%#%%#-==--==============-==:##%#%%%%#%%%%#%%#%#%%%%#%%*==-.      
    :#%%%%%%%%%%%%%%%%##%%%%%%%%%%#---:=++##%######***:--:*%%%*%%%%%%%%%%%%%#%%%##%###*=.      
    :#%##%%%##%###*#%%%#%%%%%%%+#**#%%%%%%%%@%@@@@%@@%%%%%%%%%%%%%%%%%%%%%%%*%%%%%%*##*+.      
    :#%#####%%#%%%%%%%%%%%%%%%%%#**%%%%###%%%#%%%@%#####%%%##*#%%##%#%%%%%#%#%%%%%%###*+.      
    :##*==##**+#%%%#*##%%#%%%%%%##*%%%%%#***%#%%#**#%%%%%%%%##%%%%%%%%%%%%#%**#%#%%%#%%+.      
    :###########%#%**#%**%%%%%%%%%%%%%%#%#%#%=#*###++%%%%%%%%%%%%%%%%%%%%%%%%%%%##%%%%%+.      
    .##*++##***#%#%*#*#*##***%*%*%***%%#####%%%%%*###%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%+.      
    .##*++#%***#%%#**+*++*%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%+.      
    .#%%%#*##%%%%%%##***+*%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%+.      
    .*%%%%%%%%%%%%%%*+%%%%%%%%%%%%%%%%%%%%%%%%%*-:-#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%+.      
    .*%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%#*+*%%#+:-*%*--#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%+.      
    .*%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%=:=+=:::-#%%%%%+:-%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%+.      
    .*%%%#*++*#%%%%%%%%%%%%%%%%%%%%=:=#%%%%%#++*#%%%%%-:+%%%%%%%%%%%%%%%%%%%%#++=-=+*%%+.      
    .*#+-=====+=+%%%%%%%%%%%%%%%#+-=#+====--=+++=::=*%%*-:+#%%%%%%%%%%%%%%%#+:==---=-=**.      
    .*+==......=++%%######%##+=-:=#=:=#####%%%%%%%#+-:-*%#=:-=*##########%%++=... ..-===.      
    .+--:.    .:-=#*----------=#*-:-%#=::::::+##%#***#*-::=*#+=----------*#--:.    .:::-.      
    .++=-.    .-=+%*:::::::::::-=++=:-+#%%%%#+=--=++=-:-+*+=---::::::::::+%*+=... ..-=++..     
    .*#=:=--:-=-=#%*-----------::-=*#%%#*+==------==+#%#+-:::------------+%%*-==--==-=#*.      
    .+%%#++--=+#%%%#----=====---:::::::-=*#%%%%%%%%*=-:::::--============*%%%%#++=+*%%%*.      
     :*%%%%%%%%%%%%#+++++++++***#%%%%%%%%%%%%%%%%%%%%%%%%%%%###**++++++++#%%%%%%%%%%%%*..      
     ..=#%%%%%%%%%%%*+++#%%%%%%%+%%%%%%%%%%%%%%%%%%%%=#%%%%%%%%%%#=-*+-=+%%%%%%%%%%#=:.        
       ...:+#%%%%%%*=%%%#=+=-=**-+=*-+=*-==+==*-+-#++=+++=+*==*%%%*-+++%=+%%%%%%+:....         
            ..:+#%%#=+*=+=*===##-*=+-*=+-==#+-+-*-+=*=##++=+++*%%*=-++--=%%#*-...              
                ..:=*#%%%%%%%%%%%%%%%%+++#%%%%%%%+%%%%%%%%%%%%%%%%%%%%%#+-...                  
                   ...:=*%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%*-..                       
                         .:=#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%#=..                           
                            ..:=*#%%%%%%%%%%%%%%%%%%%%%%%%%%*=:..                              
                                ..:-*#%%%%%%%%%%%%%%%%%%*=:....                                
                                     ..-*%%%%%%%%%%%#=....                                     
                                         ...........                                           
EOF
echo ""
read -p "Can you confirm this is a Cartographer V4 probe? (y/n): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Exiting. Please run this script only with a Cartographer V4 probe."
    exit 1
fi
clear
echo ""
echo "-------------------------------------------------------------"
echo "Switching your Cartographer v4 to CAN (1,000,000) firmware..."
echo "-------------------------------------------------------------"
test -e ~/katapult && (cd ~/katapult && git pull) || (cd ~ && git clone https://github.com/Arksine/katapult) ; cd ~

echo "-------------------------------------------------------------"
echo "Detecting your Cartographer device..."
echo "-------------------------------------------------------------"

CARTOGRAPHER_DEVICE=$(ls /dev/serial/by-id/usb-Cartographer_stm32g431xx_* 2>/dev/null | head -n1)

if [ -z "$CARTOGRAPHER_DEVICE" ]; then
    clear
    echo "ERROR: Cartographer V4 device not found on USB ports!"
    echo "-------------------------------------------------------------"
    echo "Is the device connected via USB?"
    echo "Is this a Cartographer v4 device?"
    echo "-------------------------------------------------------------"
    read -p "Press Enter to exit..."
    exit 1
fi

echo "Your Cartographer device is: $CARTOGRAPHER_DEVICE"
echo "-------------------------------------------------------------"

# Extract device name from full path and query API for device UUID
DEVICE_NAME=$(basename "$CARTOGRAPHER_DEVICE")
echo "Querying API for device UUID..."
API_RESPONSE=$(curl -s "https://api.cartographer3d.com/q/device_name/$DEVICE_NAME")

# Extract device_uuid from JSON response
if command -v jq &> /dev/null; then
    DEVICE_UUID=$(echo "$API_RESPONSE" | jq -r '.device_uuid' 2>/dev/null)
else
    DEVICE_UUID=$(echo "$API_RESPONSE" | grep -o '"device_uuid"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"device_uuid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
fi

if [ -z "$DEVICE_UUID" ] || [ "$DEVICE_UUID" = "null" ]; then
    echo "WARNING: Could not retrieve device UUID from API"
    DEVICE_UUID=""
else
    echo "Device UUID: $DEVICE_UUID"
fi
echo "-------------------------------------------------------------"

cd ~/klipper/scripts
sleep 5
~/klippy-env/bin/python -c "import flash_usb as u; u.enter_bootloader('$CARTOGRAPHER_DEVICE')"

echo "Waiting for device to enter bootloader mode..."
KATAPULT_DEVICE=""
for i in {1..10}; do
    sleep 1
    KATAPULT_DEVICE=$(ls /dev/serial/by-id/*katapult* 2>/dev/null | head -n1)
    if [ -n "$KATAPULT_DEVICE" ]; then
        break
    fi
done

if [ -z "$KATAPULT_DEVICE" ]; then
    echo "ERROR: Katapult device not found after entering bootloader mode!"
    echo "-------------------------------------------------------------"
    echo "Please check if the device entered bootloader mode correctly."
    echo "-------------------------------------------------------------"
    read -p "Press Enter to exit..."
    exit 1
fi

echo "Your Katapult device is: $KATAPULT_DEVICE"
cd ~/cartographer_firmware/firmware/v4/katapult-deployer/
pwd
echo "-------------------------------------------------------------"

~/klippy-env/bin/python ~/klipper/lib/canboot/flash_can.py -f katapult_deployer_v4_CAN_1M.bin -d "$KATAPULT_DEVICE"
clear
echo -e "\033[1;31mPlease unplug the USB probe and re-install it in CAN mode.\033[0m"
echo ""
echo "Select firmware version:"
echo "  [1] Full firmware (default)"
echo "  [2] Lite firmware (recommended for weaker MCUs or SBCs)"
read -p "Enter your choice (1 or 2): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[2]$ ]]; then
    FIRMWARE_FILE="CartographerV4_6.0.0_CAN_1M_lite_8kib_offset.bin"
    echo "Lite firmware selected."
else
    FIRMWARE_FILE="CartographerV4_6.0.0_CAN_1M_full_8kib_offset.bin"
    echo "Full firmware selected."
fi
echo ""
echo "Copy this into your Clipboard and once you have plugged your probe in via CAN run:"
echo ""
echo ""
echo -e "\033[0;32mcd ~/cartographer_firmware/firmware/v4/firmware/6.0.0/\033[0m"
echo -e "\033[0;32mpython3 ~/katapult/scripts/flash_can.py -i can0 -f $FIRMWARE_FILE -u $DEVICE_UUID\033[0m"
echo ""
echo ""You can also run the commands automatically if you are not rebooting the printer.
echo "-------------------------------------------------------------"

# Check if device is already on CAN and offer to run commands automatically
if [ -n "$DEVICE_UUID" ]; then
    echo "Checking if device is available on CAN..."
    
    # Check if can0 interface exists and is up
    if ip link show can0 &>/dev/null && ip link show can0 | grep -q "state UP"; then
        echo "CAN interface (can0) is up. Checking for device..."
        
        # Try to query the device on CAN
        cd ~/cartographer_firmware/firmware/v4/firmware/6.0.0/ 2>/dev/null
        if [ -f "$FIRMWARE_FILE" ]; then
            read -p "Would you like to automatically flash the firmware now? (y/n): " -n 1 -r
            echo ""
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                echo "Flashing firmware via CAN..."
                python3 ~/katapult/scripts/flash_can.py -i can0 -f "$FIRMWARE_FILE" -u "$DEVICE_UUID"
                echo ""
                echo "-------------------------------------------------------------"
                echo "Flash complete!"
                echo "-------------------------------------------------------------"
            else
                echo "You can run the commands manually when ready."
            fi
        else
            echo "Firmware file not found. Please run the commands manually."
        fi
    else
        echo "CAN interface (can0) is not up. Please connect the device via CAN first."
        echo "You can run the commands manually once the device is connected."
    fi
else
    echo "Device UUID not available. Please run the commands manually with your device UUID."
fi



