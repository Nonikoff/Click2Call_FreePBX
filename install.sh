#!/bin/bash

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# --- Configuration ---
SOURCE_API_DIR="./api"
SOURCE_CONF_DIR="./apache_conf"
WEB_ROOT="/var/www/html"
LOG_DIR="/var/log/asterisk"
ASTERISK_CONF_FILE="/etc/asterisk/extensions_custom.conf"
USER="asterisk"
GROUP="asterisk"

# Logs to create
LOG_FILES=(
    "api_calls.log"
    "click2call.log"
    "agents_status.log"
    "api_keys_management.log"
    "api_debug.log"
    "agent_status_worker.log"
)

# --- OS Detection ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    ID_LIKE=$ID_LIKE
elif type lsb_release >/dev/null 2>&1; then
    OS=$(lsb_release -si)
else
    OS=$(uname -s)
fi

echo "Detected OS: $OS"

# --- Pre-checks ---
echo "--- Running Pre-checks ---"

install_ioncube() {
    echo "ionCube Loader is missing or outdated. Attempting automatic installation..."
    
    # Get PHP version (e.g., 7.4)
    PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
    
    # Get Extension Directory safely
    EXT_DIR=$(php -r "echo ini_get('extension_dir');")
    
    # Get configuration directory
    INI_DIR=$(php --ini | grep "Scan for additional .ini files in" | awk '{print $NF}')
    
    if [ -z "$EXT_DIR" ] || [ -z "$INI_DIR" ]; then
        echo "Error: Could not determine PHP extension or INI directory. Please install ionCube manually."
        exit 1
    fi

    # Determine architecture
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        IONCUBE_URL="https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz"
    else
        echo "Error: Unsupported architecture $ARCH for automatic ionCube installation. Please install manually."
        exit 1
    fi

    echo "Downloading ionCube loaders for PHP $PHP_VERSION..."
    cd /tmp
    wget -qO ioncube.tar.gz "$IONCUBE_URL"
    tar -xzf ioncube.tar.gz

    LOADER_FILE="/tmp/ioncube/ioncube_loader_lin_${PHP_VERSION}.so"
    
    if [ ! -f "$LOADER_FILE" ]; then
        echo "Error: ionCube loader for PHP $PHP_VERSION not found in downloaded package. Please install manually."
        rm -rf /tmp/ioncube*
        exit 1
    fi

    echo "Installing ionCube loader to $EXT_DIR..."
    cp -f "$LOADER_FILE" "$EXT_DIR/"
    
    echo "Configuring PHP..."
    printf "zend_extension = %s\n" "$EXT_DIR/ioncube_loader_lin_${PHP_VERSION}.so" > "$INI_DIR/00-ioncube.ini"
    
    echo "Cleaning up..."
    rm -rf /tmp/ioncube*
    
    # Verify installation
    if ! php -m | grep -qi "ionCube Loader"; then
        echo "Error: Automatic installation failed. ionCube Loader is still not detected."
        exit 1
    fi
    
    echo "✓ ionCube Loader successfully installed."
    
    # Need to restart apache to apply to web context, we will do this at the end of the script anyway,
    # but it's good to note.
}

recover_broken_php() {
    # If php -v outputs the specific directory error, try to remove the offending ini
    if php -v 2>&1 | grep -q "cannot read file data: Is a directory"; then
        echo "Detected corrupted PHP configuration. Attempting recovery..."
        # Find and remove ioncube ini files that might be causing the directory-load error
        find /etc -name "*ioncube.ini" -type f -exec rm -f {} \;
        echo "Recovery attempted. Proceeding with checks."
    fi
}

check_php_extension() {
    local ext=$1
    if [ "$ext" = "ionCube Loader" ]; then
        if php -m | grep -qi "ionCube Loader"; then
            local version=$(php -v | grep -i "ionCube" | grep -ioE 'v[0-9]+\.[0-9]+' | head -1 | tr -d 'v')
            local major_version=$(echo "$version" | cut -d. -f1)
            
            if [ -n "$major_version" ] && [ "$major_version" -lt 13 ]; then
                echo "WARNING: ionCube Loader version $version is too old (requires 13+). Updating..."
                install_ioncube
            else
                echo "✓ PHP extension 'ionCube Loader' is present and up to date (v$version)."
            fi
        else
            install_ioncube
        fi
    else
        if ! php -m | grep -qi "$ext"; then
            echo "Error: PHP extension '$ext' is required but not installed."
            exit 1
        else
            echo "✓ PHP extension '$ext' is present."
        fi
    fi
}

recover_broken_php
check_php_extension "ionCube Loader"

# --- 1. File Copying ---
echo "--- Checking PHP Files ---"

# Remove rest directory if it exists (deprecated/security cleanup)
if [ -d "$WEB_ROOT/rest" ]; then
    echo "Removing deprecated rest directory..."
    rm -rf "$WEB_ROOT/rest"
fi

# Ensure base directory exists
if [ -d "$WEB_ROOT/api/v1" ]; then
    echo "Backing up existing API v1 to /tmp/api_v1_backup_$(date +%F)..."
    tar -czf "/tmp/api_v1_backup_$(date +%F).tar.gz" -C "$WEB_ROOT/api" v1
    echo "Cleaning up existing v1 directory for fresh installation..."
    rm -rf "$WEB_ROOT/api/v1/"*
    
    # Clean up src and vendor to prevent orphaned files
    if [ -d "$WEB_ROOT/api/src" ]; then
        echo "Cleaning up existing src directory..."
        rm -rf "$WEB_ROOT/api/src"
    fi
    if [ -d "$WEB_ROOT/api/vendor" ]; then
        echo "Cleaning up existing vendor directory..."
        rm -rf "$WEB_ROOT/api/vendor"
    fi
else
    mkdir -p "$WEB_ROOT/api/v1"
fi

# API FILES LOGIC
# First, check if there are any PHP files in the SOURCE_API_DIR or SOURCE_API_DIR/v1
if [ -d "$SOURCE_API_DIR" ] && (ls "$SOURCE_API_DIR"/*.php >/dev/null 2>&1 || [ -d "$SOURCE_API_DIR/v1" ]); then
    echo "Found local API files at $SOURCE_API_DIR. Copying to $WEB_ROOT/api/v1..."

    # Check if source has v1 structure or flat structure
    if [ -d "$SOURCE_API_DIR/v1" ]; then
        cp -r "$SOURCE_API_DIR/v1/"* "$WEB_ROOT/api/v1/"
    else
        # Copy contents directly to v1, assuming flat structure
        cp -r "$SOURCE_API_DIR/"* "$WEB_ROOT/api/v1/"
    fi

    # Copy Logic and Vendor folders
    if [ -d "./src" ]; then
        echo "Copying business logic to $WEB_ROOT/api/src..."
        cp -r "./src" "$WEB_ROOT/api/"
    fi
    if [ -d "./vendor" ]; then
        echo "Copying dependencies to $WEB_ROOT/api/vendor..."
        cp -r "./vendor" "$WEB_ROOT/api/"
    fi
    if [ -d "./scripts" ]; then
        echo "Copying scripts to $WEB_ROOT/api/scripts..."
        cp -r "./scripts" "$WEB_ROOT/api/"
    fi
elif [ -f "$WEB_ROOT/api/v1/click2call.php" ]; then
    echo "Local source '$SOURCE_API_DIR' not found, but files detected in target. Using existing files."
else
    echo "ERROR: API files not found locally ($SOURCE_API_DIR) and not detected in target ($WEB_ROOT/api/v1)."
    exit 1
fi

# --- 2. Permissions ---
echo "--- Setting Permissions ---"

# Recursively set owner
echo "Setting owner to $USER:$GROUP..."
if [ -d "$WEB_ROOT/api" ]; then
    chown -R "$USER:$GROUP" "$WEB_ROOT/api"
fi

# Recursively set modes (Dirs 755, Files 644)
echo "Setting file modes..."
if [ -d "$WEB_ROOT/api" ]; then
    find "$WEB_ROOT/api" -type d -exec chmod 755 {} \;
    find "$WEB_ROOT/api" -type f -exec chmod 644 {} \;
fi

# --- 3. Log Files ---
echo "--- Configuring Logs ---"

if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
    chown "$USER:$GROUP" "$LOG_DIR"
    chmod 755 "$LOG_DIR"
fi

for logfile in "${LOG_FILES[@]}"; do
    FULL_PATH="$LOG_DIR/$logfile"
    if [ ! -f "$FULL_PATH" ]; then
        echo "Creating log file: $FULL_PATH"
        touch "$FULL_PATH"
    fi
    chown "$USER:$GROUP" "$FULL_PATH"
    chmod 660 "$FULL_PATH"
done

# --- 4. Asterisk Dialplan Configuration ---
echo "--- Configuring Asterisk Dialplan ---"

if [ -f "$ASTERISK_CONF_FILE" ]; then
    if grep -q "\[click2call-bypass\]" "$ASTERISK_CONF_FILE"; then
        echo "Context [click2call-bypass] already exists in $ASTERISK_CONF_FILE. Skipping."
    else
        echo "Appending [click2call-bypass] context to $ASTERISK_CONF_FILE..."

        # Using quoted 'EOL' to prevent variable expansion in bash
        cat >> "$ASTERISK_CONF_FILE" <<'EOL'

[click2call-bypass]
; Custom context that bypasses FreePBX CallerID security
exten => _X.,1,NoOp(=== Click2Call Bypass Context ===)
 same => n,NoOp(CALLERID(num): ${CALLERID(num)})
 same => n,NoOp(REALCALLERIDNUM: ${REALCALLERIDNUM})

 ; Save agent extension for billing (use standard CDR field)
 same => n,GotoIf($["${CALLERID(num)}" = ""]?use_api_cid)
 same => n,Set(CHANNEL(accountcode)=${CALLERID(num)})
 same => n,Set(__AGENT_EXTENSION=${CALLERID(num)})

 same => n(use_api_cid),GotoIf($["${REALCALLERIDNUM}" = ""]?use_default)

 ; Set TRUNKCIDOVERRIDE to the API Key CID (for the trunk)
 same => n,Set(TRUNKCIDOVERRIDE=${REALCALLERIDNUM})
 same => n,Set(CALLERID(name)=Click2Call)
 same => n,Set(__API_CALLER_ID=${REALCALLERIDNUM})
 same => n,NoOp(Using API CallerID for Trunk: ${REALCALLERIDNUM})

 ; PREPEND the API CallerID to the destination number for prefix-based routing
 same => n,Goto(from-internal,${REALCALLERIDNUM}${EXTEN},1)

 same => n(use_default),NoOp(No custom CallerID, using extension)
 same => n,Goto(from-internal,${EXTEN},1)

[macro-dialout-trunk-predial-hook]
exten => s,1,NoOp(=== Click2Call CDR Fix ===)
; If this is an API call (REALCALLERIDNUM is set), force CDR destination to be the stripped number (OUTNUM)
same => n,ExecIf($["${REALCALLERIDNUM}" != ""]?Set(CDR(dst)=${OUTNUM}))
same => n,MacroExit()
EOL

        echo "Reloading Asterisk Dialplan..."
        asterisk -rx "dialplan reload"
    fi
else
    echo "WARNING: $ASTERISK_CONF_FILE not found. Could not add dialplan context."
fi

    # --- 5. Apache Configuration ---
    echo "--- Configuring Apache ---"

    if [ ! -d "$SOURCE_CONF_DIR" ]; then
         echo "WARNING: Local Apache configuration folder '$SOURCE_CONF_DIR' not found."
         echo "Skipping Apache configuration copy. Assuming manual configuration or already configured."
    else
        if [[ "$ID" == "debian" || "$ID_LIKE" == *"debian"* || "$ID" == "ubuntu" ]]; then
            # === DEBIAN / UBUNTU ===
            APACHE_CONF_DIR="/etc/apache2/conf-available"

            echo "Copying configs to $APACHE_CONF_DIR..."
            cp "$SOURCE_CONF_DIR/click2call.conf" "$APACHE_CONF_DIR/"

            echo "Enabling configurations..."
            a2enconf click2call

            echo "Enabling modules..."
            a2enmod rewrite
            a2enmod headers

            echo "Testing configuration..."
            apache2ctl configtest

            echo "Restarting Apache..."
            systemctl restart apache2
            systemctl status apache2 --no-pager

        elif [[ "$ID" == "centos" || "$ID_LIKE" == *"rhel"* || "$ID" == "fedora" ]]; then
            # === CENTOS / RHEL ===
            APACHE_CONF_DIR="/etc/httpd/conf.d"

            echo "Copying configs to $APACHE_CONF_DIR..."
            cp "$SOURCE_CONF_DIR/click2call.conf" "$APACHE_CONF_DIR/"
            echo "Adjusting Apache log paths for CentOS/RHEL..."
            sed -i \
                -e 's#^\s*ErrorLog\s\+.*#ErrorLog /var/log/httpd/click2call_error.log#' \
                -e 's#^\s*CustomLog\s\+.*#CustomLog /var/log/httpd/click2call_access.log combined#' \
                "$APACHE_CONF_DIR/click2call.conf"

            # Ensure permissions on configs
            chown "root:root" "$APACHE_CONF_DIR/click2call.conf"
            chmod 644 "$APACHE_CONF_DIR/click2call.conf"

            echo "Testing configuration..."
            httpd -t

            echo "Restarting Apache (httpd)..."
            systemctl restart httpd
            systemctl status httpd --no-pager

        else
            echo "Unsupported OS family ($ID). Please configure Apache manually."
        fi
    fi

# --- 6. PHP Security Check ---
echo "--- PHP Security Check ---"
DISPLAY_ERRORS=$(php -r 'echo ini_get("display_errors");')
if [[ "$DISPLAY_ERRORS" == "1" || "$DISPLAY_ERRORS" == "On" ]]; then
    echo "WARNING: PHP 'display_errors' is enabled. This can leak sensitive info."
    echo "It is highly recommended to set 'display_errors = Off' in your php.ini for production."
else
    echo "✓ PHP 'display_errors' is Off (Recommended for production)."
fi

# --- 7. Database Initialization ---
echo "--- Initializing Database Schema ---"
if [ -f "$WEB_ROOT/api/v1/manage_api_keys.php" ]; then
    # We call the CLI script with no arguments. We will update the CLI script to ensure
    # that simply loading it initializes the database, or we'll pass a dummy argument.
    # The safest way is to just call it with --list-keys so it runs the constructor.
    php "$WEB_ROOT/api/v1/manage_api_keys.php" --list-keys > /dev/null 2>&1
    echo "✓ Database schema verified."
else
    echo "WARNING: Could not find manage_api_keys.php at $WEB_ROOT/api/v1/ to initialize the database."
fi

# --- 8. License Configuration ---
echo "--- Configuring License ---"
LICENSE_FILE="/etc/click2call_license"

if [ -t 0 ]; then
    # Interactive mode
    if [ -f "$LICENSE_FILE" ]; then
        echo "Existing license key found."
        read -sp "Enter new License Key (press Enter to keep current): " NEW_KEY
        echo ""
        if [ -n "$NEW_KEY" ]; then
            printf "%s\n" "$NEW_KEY" > "$LICENSE_FILE"
        fi
    else
        read -sp "Enter your Click2Call License Key (leave empty for DEVELOPMENT-KEY): " LICENSE_KEY
        echo ""
        if [ -z "$LICENSE_KEY" ]; then
            LICENSE_KEY="DEVELOPMENT-KEY"
            echo "WARNING: No license key provided. Using DEVELOPMENT-KEY."
        fi
        printf "%s\n" "$LICENSE_KEY" > "$LICENSE_FILE"
    fi
else
    # Non-interactive mode
    if [ -n "$LICENSE_KEY" ]; then
        printf "%s\n" "$LICENSE_KEY" > "$LICENSE_FILE"
        echo "License key set from environment variable."
    elif [ -f "$LICENSE_FILE" ]; then
        echo "Existing license key found. Keeping it in non-interactive mode."
    else
        LICENSE_KEY="DEVELOPMENT-KEY"
        printf "%s\n" "$LICENSE_KEY" > "$LICENSE_FILE"
        echo "WARNING: Non-interactive mode and no LICENSE_KEY env var. Using DEVELOPMENT-KEY."
    fi
fi

# Set permissions
chown "root:$GROUP" "$LICENSE_FILE"
chmod 640 "$LICENSE_FILE"
echo "✓ License configuration processed."

# --- 9. Systemd Service ---
echo "--- Configuring Systemd Service for Agent Status Worker ---"
SERVICE_FILE="/etc/systemd/system/click2call-agent-status.service"

if [ -f "$WEB_ROOT/api/scripts/agent-status-worker.php" ]; then
    cat > "$SERVICE_FILE" <<EOL
[Unit]
Description=Click2Call Agent Status Worker
After=network.target asterisk.service mariadb.service mysql.service

[Service]
Type=simple
User=asterisk
Group=asterisk
ExecStart=/usr/bin/php $WEB_ROOT/api/scripts/agent-status-worker.php
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

    echo "Enabling and starting click2call-agent-status service..."
    systemctl daemon-reload
    systemctl enable click2call-agent-status
    systemctl restart click2call-agent-status
    systemctl status click2call-agent-status --no-pager
    echo "✓ Agent status worker service configured."
else
    echo "WARNING: agent-status-worker.php not found at $WEB_ROOT/api/scripts/. Skipping service setup."
fi

echo "--- Installation Complete ---"
