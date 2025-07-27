#!/bin/bash

# Moodle Updater v1.0
# Automated Moodle update script with security checks and backup functionality

set -e  # Exit script on errors

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Helper function for user queries
ask_yes_no() {
    while true; do
        read -p "$1 (y/n): " yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer with y or n.";;
        esac
    done
}

# Check and upgrade MariaDB/MySQL version
check_and_upgrade_mariadb() {
    local moodle_version=$1
    
    # Get current MariaDB/MySQL version
    local db_version=""
    if command -v mysql &> /dev/null; then
        db_version=$(mysql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        local db_type=$(mysql --version 2>/dev/null | grep -i mariadb &>/dev/null && echo "mariadb" || echo "mysql")
    else
        warning "MySQL/MariaDB client not found"
        return
    fi
    
    if [[ -z "$db_version" ]]; then
        warning "Could not determine database version"
        return
    fi
    
    log "Current database: $db_type $db_version"
    
    # Define minimum requirements
    local required_mariadb="10.11.0"
    local required_mysql="8.0.0"
    
    local needs_upgrade=false
    local recommended_version=""
    
    if [[ "$db_type" == "mariadb" ]]; then
        if [[ "$(printf '%s\n' "$required_mariadb" "$db_version" | sort -V | head -n1)" != "$required_mariadb" ]]; then
            needs_upgrade=true
            recommended_version="10.11"
        fi
    elif [[ "$db_type" == "mysql" ]]; then
        if [[ "$(printf '%s\n' "$required_mysql" "$db_version" | sort -V | head -n1)" != "$required_mysql" ]]; then
            needs_upgrade=true
            recommended_version="8.0"
        fi
    fi
    
    if [[ "$needs_upgrade" == "true" ]]; then
        warning "$db_type $db_version is below recommended version"
        log "Recommended: $db_type $recommended_version+"
        
        if ask_yes_no "Do you want to upgrade $db_type automatically?"; then
            upgrade_mariadb_mysql "$db_type" "$recommended_version"
        else
            warning "Database upgrade skipped - some Moodle features may not work optimally"
        fi
    else
        success "$db_type version $db_version meets requirements"
    fi
}

# Upgrade MariaDB/MySQL
upgrade_mariadb_mysql() {
    local db_type=$1
    local target_version=$2
    
    log "Upgrading $db_type to version $target_version..."
    
    # Create database backup before upgrade
    if ask_yes_no "Create database backup before upgrade? (HIGHLY RECOMMENDED)"; then
        create_emergency_db_backup
    fi
    
    # Stop database service
    log "Stopping database service..."
    systemctl stop mysql 2>/dev/null || systemctl stop mariadb 2>/dev/null || true
    
    if [[ "$db_type" == "mariadb" ]]; then
        upgrade_mariadb "$target_version"
    else
        upgrade_mysql "$target_version"
    fi
    
    # Start database service
    log "Starting database service..."
    systemctl start mysql 2>/dev/null || systemctl start mariadb 2>/dev/null || true
    
    # Wait for service to be ready
    for i in {1..30}; do
        if mysqladmin ping &>/dev/null; then
            break
        fi
        sleep 1
    done
    
    # Run mysql_upgrade
    log "Running database upgrade process..."
    mysql_upgrade 2>/dev/null || true
    
    # Restart service to ensure clean state
    systemctl restart mysql 2>/dev/null || systemctl restart mariadb 2>/dev/null || true
    
    # Verify upgrade
    local new_version=$(mysql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    success "$db_type upgraded to version $new_version"
}

# Upgrade MariaDB
upgrade_mariadb() {
    local target_version=$1
    
    log "Upgrading MariaDB to $target_version..."
    
    if command -v apt-get &> /dev/null; then
        # Ubuntu/Debian
        log "Adding MariaDB repository..."
        
        # Install prerequisites
        apt-get update
        apt-get install -y software-properties-common dirmngr apt-transport-https
        
        # Add MariaDB repository key
        curl -sS https://mariadb.org/mariadb_release_signing_key.asc | apt-key add -
        
        # Add repository based on target version
        local ubuntu_codename=$(lsb_release -cs)
        echo "deb [arch=amd64] https://mirror.mariadb.org/repo/$target_version/ubuntu $ubuntu_codename main" > /etc/apt/sources.list.d/mariadb.list
        
        # Update package list
        apt-get update
        
        # Upgrade MariaDB
        log "Installing MariaDB $target_version..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            mariadb-server \
            mariadb-client \
            mariadb-common \
            mariadb-server-core
            
    elif command -v yum &> /dev/null; then
        # CentOS/RHEL
        log "Adding MariaDB repository for CentOS/RHEL..."
        
        cat > /etc/yum.repos.d/MariaDB.repo << EOF
[mariadb]
name = MariaDB
baseurl = https://mirror.mariadb.org/yum/$target_version/centos7-amd64
gpgkey = https://mirror.mariadb.org/yum/RPM-GPG-KEY-MariaDB
gpgcheck = 1
EOF
        
        yum update -y
        yum install -y MariaDB-server MariaDB-client
        
    else
        error "Unsupported package manager for MariaDB upgrade"
        return 1
    fi
}

# Upgrade MySQL
upgrade_mysql() {
    local target_version=$1
    
    log "Upgrading MySQL to $target_version..."
    
    if command -v apt-get &> /dev/null; then
        # Ubuntu/Debian
        log "Adding MySQL repository..."
        
        # Download and install MySQL APT repository
        wget -O /tmp/mysql-apt-config.deb https://dev.mysql.com/get/mysql-apt-config_0.8.24-1_all.deb
        DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/mysql-apt-config.deb
        
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server mysql-client
        
    elif command -v yum &> /dev/null; then
        # CentOS/RHEL
        log "Adding MySQL repository for CentOS/RHEL..."
        
        yum install -y https://dev.mysql.com/get/mysql80-community-release-el7-3.noarch.rpm
        yum update -y
        yum install -y mysql-community-server mysql-community-client
        
    else
        error "Unsupported package manager for MySQL upgrade"
        return 1
    fi
}

# Create emergency database backup
create_emergency_db_backup() {
    local emergency_backup_dir="/tmp/emergency_db_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$emergency_backup_dir"
    
    log "Creating emergency database backup in $emergency_backup_dir..."
    
    # Get all databases
    local databases=$(mysql -e "SHOW DATABASES;" | grep -Ev "(Database|information_schema|performance_schema|mysql|sys)")
    
    for db in $databases; do
        if [[ -n "$db" ]]; then
            log "Backing up database: $db"
            mysqldump --single-transaction --routines --triggers "$db" > "$emergency_backup_dir/${db}.sql" 2>/dev/null || true
        fi
    done
    
    success "Emergency backup created in: $emergency_backup_dir"
    echo "$emergency_backup_dir" > /tmp/last_emergency_backup_path
}
check_php_requirements() {
    local moodle_version=$1
    local current_php_version=$(php -r "echo PHP_VERSION;")
    local required_php=""
    local recommended_php=""
    
    # PHP requirements based on Moodle version
    case $moodle_version in
        5.0*|4.5*|4.4*)
            required_php="8.1"
            recommended_php="8.3"
            ;;
        4.3*|4.2*)
            required_php="8.0"
            recommended_php="8.2"
            ;;
        4.1*|4.0*)
            required_php="7.4"
            recommended_php="8.1"
            ;;
        *)
            required_php="8.1"
            recommended_php="8.3"
            ;;
    esac
    
    log "Current PHP version: $current_php_version"
    log "Minimum PHP version for Moodle $moodle_version: $required_php"
    log "Recommended PHP version: $recommended_php"
    
    # Correct version comparison
    if [[ "$(printf '%s\n' "$required_php" "$current_php_version" | sort -V | head -n1)" != "$required_php" ]]; then
        error "PHP version $current_php_version is too old for Moodle $moodle_version"
        warning "Please upgrade PHP to at least version $required_php"
        
        if ask_yes_no "Should we try to upgrade PHP automatically?"; then
            upgrade_php $recommended_php
        else
            exit 1
        fi
    else
        success "PHP version $current_php_version meets the requirements"
        
        # Give recommendation if not optimal
        if [[ "$(printf '%s\n' "$recommended_php" "$current_php_version" | sort -V | head -n1)" != "$recommended_php" ]]; then
            warning "Recommended PHP version is $recommended_php (current: $current_php_version)"
        fi
    fi
}

# PHP upgrade (Ubuntu/Debian)
upgrade_php() {
    local target_version=$1
    
    log "Attempting to upgrade PHP to version $target_version..."
    
    # Add Ondrej PPA (for Ubuntu/Debian)
    if command -v apt-get &> /dev/null; then
        sudo apt-get update
        sudo apt-get install -y software-properties-common
        sudo add-apt-repository -y ppa:ondrej/php
        sudo apt-get update
        
        # Install PHP
        sudo apt-get install -y "php${target_version}" \
            "php${target_version}-cli" \
            "php${target_version}-fpm" \
            "php${target_version}-mysql" \
            "php${target_version}-pgsql" \
            "php${target_version}-xml" \
            "php${target_version}-mbstring" \
            "php${target_version}-curl" \
            "php${target_version}-zip" \
            "php${target_version}-gd" \
            "php${target_version}-intl" \
            "php${target_version}-ldap" \
            "php${target_version}-soap" \
            "php${target_version}-xmlrpc"
        
        # Switch PHP version
        sudo update-alternatives --set php "/usr/bin/php${target_version}"
        
        success "PHP has been upgraded to version $target_version"
    else
        warning "Automatic PHP upgrade is only supported on Ubuntu/Debian"
        error "Please upgrade PHP manually"
        exit 1
    fi
}

# Get current Moodle version
get_current_moodle_version() {
    local moodle_path=$1
    
    if [[ -f "$moodle_path/version.php" ]]; then
        local version=$(grep '$release' "$moodle_path/version.php" | head -1 | sed "s/.*'\([^']*\)'.*/\1/")
        echo $version
    else
        echo "unknown"
    fi
}

# Get available Moodle versions from GitHub
get_latest_moodle_versions() {
    # Use GitHub API to fetch tags
    local versions=$(curl -s "https://api.github.com/repos/moodle/moodle/tags" | \
        grep '"name"' | \
        sed 's/.*"name": "v\([^"]*\)".*/\1/' | \
        grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' | \
        sort -V -r | \
        head -10)
    
    echo "$versions"
}

# Compare versions
version_compare() {
    local version1=$1
    local version2=$2
    
    if [[ "$version1" == "$version2" ]]; then
        echo "0"
    elif printf '%s\n%s' "$version1" "$version2" | sort -V -C; then
        echo "-1"  # version1 < version2
    else
        echo "1"   # version1 > version2
    fi
}

# Create backup
create_backup() {
    local moodle_path=$1
    local moodledata_path=$2
    local backup_dir="/tmp/moodle_backup_$(date +%Y%m%d_%H%M%S)"
    
    log "Creating backup in $backup_dir..."
    
    mkdir -p "$backup_dir"
    
    # Moodle code backup
    log "Backing up Moodle code..."
    cp -r "$moodle_path" "$backup_dir/moodle_code"
    
    # Backup config.php separately
    if [[ -f "$moodle_path/config.php" ]]; then
        cp "$moodle_path/config.php" "$backup_dir/config.php.backup"
    fi
    
    # Moodledata backup (only config and important files)
    log "Backing up important Moodledata files..."
    mkdir -p "$backup_dir/moodledata_essential"
    
    if [[ -d "$moodledata_path" ]]; then
        # Only backup important directories (not all files)
        for dir in cache sessions temp trashdir; do
            if [[ -d "$moodledata_path/$dir" ]]; then
                cp -r "$moodledata_path/$dir" "$backup_dir/moodledata_essential/" 2>/dev/null || true
            fi
        done
    fi
    
    success "Backup created: $backup_dir"
    echo "$backup_dir"
}

# Database backup
backup_database() {
    local moodle_path=$1
    local backup_dir=$2
    
    if [[ ! -f "$moodle_path/config.php" ]]; then
        warning "No config.php found - database backup skipped"
        return
    fi
    
    log "Creating database backup..."
    
    # Extract DB configuration from config.php using more robust parsing
    local db_type=$(php -r "
        include '$moodle_path/config.php';
        echo isset(\$CFG->dbtype) ? \$CFG->dbtype : '';
    " 2>/dev/null || echo "")
    
    local db_host=$(php -r "
        include '$moodle_path/config.php';
        echo isset(\$CFG->dbhost) ? \$CFG->dbhost : 'localhost';
    " 2>/dev/null || echo "localhost")
    
    local db_name=$(php -r "
        include '$moodle_path/config.php';
        echo isset(\$CFG->dbname) ? \$CFG->dbname : '';
    " 2>/dev/null || echo "")
    
    local db_user=$(php -r "
        include '$moodle_path/config.php';
        echo isset(\$CFG->dbuser) ? \$CFG->dbuser : '';
    " 2>/dev/null || echo "")
    
    local db_pass=$(php -r "
        include '$moodle_path/config.php';
        echo isset(\$CFG->dbpass) ? \$CFG->dbpass : '';
    " 2>/dev/null || echo "")
    
    local db_port=$(php -r "
        include '$moodle_path/config.php';
        echo isset(\$CFG->dbport) ? \$CFG->dbport : '3306';
    " 2>/dev/null || echo "3306")
    
    log "Database type: $db_type"
    log "Database host: $db_host"
    log "Database name: $db_name"
    
    if [[ -z "$db_name" || -z "$db_user" ]]; then
        warning "Database settings incomplete - backup skipped"
        return
    fi
    
    if [[ "$db_type" == "mysqli" || "$db_type" == "mariadb" ]]; then
        if command -v mysqldump &> /dev/null; then
            log "Creating MySQL/MariaDB backup..."
            
            # Create MySQL options file for security
            local mysql_opts_file="$backup_dir/.mysql_opts"
            cat > "$mysql_opts_file" << EOF
[client]
host=$db_host
port=$db_port
user=$db_user
password=$db_pass
EOF
            chmod 600 "$mysql_opts_file"
            
            if mysqldump --defaults-file="$mysql_opts_file" \
                --single-transaction \
                --routines \
                --triggers \
                --quick \
                --add-drop-table \
                "$db_name" > "$backup_dir/database_backup.sql" 2>/dev/null; then
                success "MySQL/MariaDB backup created ($(du -h "$backup_dir/database_backup.sql" | cut -f1))"
            else
                warning "MySQL backup failed - check credentials and permissions"
                log "Trying alternative backup method..."
                if mysql --defaults-file="$mysql_opts_file" -e "USE $db_name; SHOW TABLES;" &>/dev/null; then
                    mysqldump --defaults-file="$mysql_opts_file" --no-data "$db_name" > "$backup_dir/database_structure.sql" 2>/dev/null || true
                    warning "Only database structure backed up"
                else
                    error "Cannot connect to database"
                fi
            fi
            
            # Clean up credentials file
            rm -f "$mysql_opts_file"
        else
            warning "mysqldump not found - MySQL backup skipped"
        fi
    elif [[ "$db_type" == "pgsql" ]]; then
        if command -v pg_dump &> /dev/null; then
            log "Creating PostgreSQL backup..."
            export PGPASSWORD="$db_pass"
            if pg_dump -h "$db_host" -p "$db_port" -U "$db_user" \
                --no-password \
                --clean \
                --create \
                "$db_name" > "$backup_dir/database_backup.sql" 2>/dev/null; then
                success "PostgreSQL backup created ($(du -h "$backup_dir/database_backup.sql" | cut -f1))"
            else
                warning "PostgreSQL backup failed - check credentials and permissions"
            fi
            unset PGPASSWORD
        else
            warning "pg_dump not found - PostgreSQL backup skipped"
        fi
    else
        warning "Unknown database type: $db_type - backup skipped"
    fi
}

# Download and install Moodle
download_and_install_moodle() {
    local version=$1
    local moodle_path=$2
    local backup_dir=$3
    
    local temp_dir="/tmp/moodle_download_$$"
    local download_url="https://github.com/moodle/moodle/archive/v${version}.tar.gz"
    
    log "Downloading Moodle version $version..."
    
    mkdir -p "$temp_dir"
    cd "$temp_dir"
    
    # Download with progress
    if ! curl -L --progress-bar "$download_url" -o "moodle-${version}.tar.gz"; then
        error "Download failed"
        exit 1
    fi
    
    log "Extracting Moodle..."
    tar -xzf "moodle-${version}.tar.gz"
    
    # Backup old config.php
    local old_config=""
    if [[ -f "$moodle_path/config.php" ]]; then
        old_config=$(cat "$moodle_path/config.php")
    fi
    
    log "Installing new Moodle version..."
    
    # Remove old Moodle code (except config.php and moodledata)
    find "$moodle_path" -mindepth 1 -maxdepth 1 ! -name 'config.php' ! -name 'moodledata' -exec rm -rf {} +
    
    # Copy new files
    cp -r "moodle-${version}/"* "$moodle_path/"
    
    # Restore old config.php
    if [[ -n "$old_config" ]]; then
        echo "$old_config" > "$moodle_path/config.php"
    fi
    
    # Set permissions
    chown -R www-data:www-data "$moodle_path" 2>/dev/null || true
    chmod -R 755 "$moodle_path"
    
    # Clean up temp directory
    rm -rf "$temp_dir"
    
    success "Moodle $version has been installed"
}

# Run Moodle upgrade with environment fixes
run_moodle_upgrade() {
    local moodle_path=$1
    
    log "Running Moodle upgrade..."
    
    if [[ ! -f "$moodle_path/admin/cli/upgrade.php" ]]; then
        error "Upgrade script not found"
        exit 1
    fi
    
    # Pre-upgrade environment checks and fixes
    log "Checking and fixing environment issues..."
    
    # Fix max_input_vars if needed
    local current_max_vars=$(php -r "echo ini_get('max_input_vars');")
    if [[ "$current_max_vars" -lt 5000 ]]; then
        warning "max_input_vars is $current_max_vars, should be at least 5000"
        
        # Try to fix via PHP-FPM pool config
        if [[ -f "/etc/php/$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")/fpm/pool.d/www.conf" ]]; then
            local php_version=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
            local pool_conf="/etc/php/$php_version/fpm/pool.d/www.conf"
            
            if ! grep -q "php_admin_value\[max_input_vars\]" "$pool_conf"; then
                echo "php_admin_value[max_input_vars] = 5000" >> "$pool_conf"
                systemctl reload "php$php_version-fpm" 2>/dev/null || true
                log "Updated max_input_vars in PHP-FPM pool config"
            fi
        fi
        
        # Also try via .htaccess for Apache
        if [[ -f "$moodle_path/.htaccess" ]]; then
            if ! grep -q "php_value max_input_vars" "$moodle_path/.htaccess"; then
                echo "php_value max_input_vars 5000" >> "$moodle_path/.htaccess"
            fi
        fi
    fi
    
    # Run the upgrade
    cd "$moodle_path"
    
    # Check if user wants to handle database upgrade manually
    if ask_yes_no "Do you want the script to automatically upgrade the database?"; then
        log "Running automatic database upgrade..."
        if php admin/cli/upgrade.php --non-interactive --allow-unstable; then
            success "Moodle upgrade completed successfully"
        else
            error "Moodle upgrade failed"
            warning "You may need to run the upgrade manually:"
            warning "cd $moodle_path && php admin/cli/upgrade.php"
            exit 1
        fi
    else
        log "Skipping automatic database upgrade"
        warning "You will need to complete the upgrade manually:"
        warning "1. Via web interface: Visit your Moodle site and follow the upgrade wizard"
        warning "2. Via CLI: cd $moodle_path && php admin/cli/upgrade.php"
        
        if ask_yes_no "Do you want to run the upgrade now via CLI?"; then
            log "Running CLI upgrade..."
            php admin/cli/upgrade.php
        fi
    fi
    
    # Post-upgrade optimizations
    log "Running post-upgrade optimizations..."
    
    # Clear all caches
    if [[ -f "$moodle_path/admin/cli/purge_caches.php" ]]; then
        php admin/cli/purge_caches.php 2>/dev/null || true
        log "Caches purged"
    fi
    
    # Fix file permissions after upgrade
    if [[ -d "$moodle_path" ]]; then
        chown -R www-data:www-data "$moodle_path" 2>/dev/null || true
        find "$moodle_path" -type d -exec chmod 755 {} + 2>/dev/null || true
        find "$moodle_path" -type f -exec chmod 644 {} + 2>/dev/null || true
        chmod 600 "$moodle_path/config.php" 2>/dev/null || true
        log "File permissions fixed"
    fi
}

# Disable maintenance mode
disable_maintenance_mode() {
    local moodle_path=$1
    
    log "Disabling maintenance mode..."
    
    if [[ -f "$moodle_path/config.php" ]]; then
        # Backup config.php before changes
        cp "$moodle_path/config.php" "$moodle_path/config.php.maintenance_backup"
        
        # Remove all maintenance_enabled lines
        sed -i '/\$CFG->maintenance_enabled/d' "$moodle_path/config.php"
        
        # Ensure maintenance mode is really off
        if ! grep -q "maintenance_enabled.*false" "$moodle_path/config.php"; then
            # Explicitly set to false before require_once
            if grep -q "require_once.*config.php" "$moodle_path/config.php"; then
                sed -i '/require_once.*config.php/i \$CFG->maintenance_enabled = false;' "$moodle_path/config.php"
            fi
        fi
        
        success "Maintenance mode disabled"
    else
        warning "config.php not found - maintenance mode could not be disabled"
    fi
}

# Main function
main() {
    echo "=================================="
    echo "      Moodle Updater v1.0"
    echo "=================================="
    echo
    
    # Check parameters
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 <moodle_path> <moodledata_path> [target_version]"
        echo
        echo "Example: $0 /var/www/html/moodle /var/www/moodledata 4.4.1"
        exit 1
    fi
    
    local moodle_path="$1"
    local moodledata_path="$2"
    local target_version="$3"
    
    # Validate paths
    if [[ ! -d "$moodle_path" ]]; then
        error "Moodle path does not exist: $moodle_path"
        exit 1
    fi
    
    if [[ ! -d "$moodledata_path" ]]; then
        error "Moodledata path does not exist: $moodledata_path"
        exit 1
    fi
    
    # Check root permissions
    if [[ $EUID -ne 0 ]]; then
        warning "Script is not running as root. Some operations might fail."
    fi
    
    # Get current version
    local current_version=$(get_current_moodle_version "$moodle_path")
    log "Current Moodle version: $current_version"
    
    # Get available versions
    log "Loading available Moodle versions..."
    local available_versions=$(get_latest_moodle_versions)
    local latest_version=$(echo "$available_versions" | head -1)
    
    log "Latest available version: $latest_version"
    echo
    echo "Available versions:"
    echo "$available_versions" | head -5
    echo
    
    # Determine target version
    if [[ -z "$target_version" ]]; then
        echo "Recommended version: $latest_version"
        read -p "Enter desired target version (or press Enter for $latest_version): " target_version
        
        if [[ -z "$target_version" ]]; then
            target_version="$latest_version"
        fi
    fi
    
    log "Target version: $target_version"
    
    # Validate version
    if [[ "$current_version" != "unknown" ]]; then
        local version_cmp=$(version_compare "$current_version" "$target_version")
        
        if [[ "$version_cmp" == "0" ]]; then
            warning "Target version is identical to current version"
            if ! ask_yes_no "Continue anyway?"; then
                exit 0
            fi
        elif [[ "$version_cmp" == "1" ]]; then
            error "Downgrade from $current_version to $target_version not allowed"
            exit 1
        fi
    fi
    
    # Check PHP requirements
    check_php_requirements "$target_version"
    
    # Check and upgrade MariaDB/MySQL if needed
    check_and_upgrade_mariadb "$target_version"
    
    # Get confirmation
    echo
    warning "WARNING: Backup will be created automatically, but please ensure"
    warning "you have a complete system backup!"
    echo
    
    if ! ask_yes_no "Update Moodle from $current_version to $target_version?"; then
        log "Update cancelled"
        exit 0
    fi
    
    # Create backup
    local backup_dir=$(create_backup "$moodle_path" "$moodledata_path")
    backup_database "$moodle_path" "$backup_dir"
    
    # Enable maintenance mode
    if [[ -f "$moodle_path/config.php" ]]; then
        log "Enabling maintenance mode..."
        sed -i '/\$CFG->maintenance_enabled/d' "$moodle_path/config.php"
        echo "\$CFG->maintenance_enabled = true;" >> "$moodle_path/config.php"
    fi
    
    # Download and install Moodle
    download_and_install_moodle "$target_version" "$moodle_path" "$backup_dir"
    
    # Run upgrade
    run_moodle_upgrade "$moodle_path"
    
    # Disable maintenance mode
    disable_maintenance_mode "$moodle_path"
    
    # Restart web server (optional)
    if command -v systemctl &> /dev/null; then
        if ask_yes_no "Restart web server?"; then
            systemctl restart apache2 2>/dev/null || systemctl restart nginx 2>/dev/null || true
        fi
    fi
    
    success "Moodle update completed successfully!"
    success "New version: $target_version"
    success "Backup saved in: $backup_dir"
    success "Maintenance mode: DISABLED"
    
    # Show important post-upgrade information
    echo
    log "=== POST-UPGRADE CHECKLIST ==="
    log "1. Test your Moodle installation thoroughly"
    log "2. Check Admin → Server → Environment for any warnings"
    log "3. Review Admin → Reports → Config changes"
    log "4. Verify user permissions and course access"
    log "5. Test email functionality"
    log "6. Check that plugins are working correctly"
    
    # Environment status check
    echo
    log "=== ENVIRONMENT STATUS ==="
    
    # Check MariaDB version after potential upgrade
    local final_db_version=$(mysql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
    local db_type_final=$(mysql --version 2>/dev/null | grep -i mariadb &>/dev/null && echo "MariaDB" || echo "MySQL")
    
    if [[ "$final_db_version" != "unknown" ]]; then
        success "$db_type_final version: $final_db_version"
        
        # Check if version meets requirements
        if [[ "$db_type_final" == "MariaDB" ]]; then
            if [[ "$(printf '%s\n' "10.11.0" "$final_db_version" | sort -V | head -n1)" == "10.11.0" ]]; then
                success "MariaDB version meets Moodle requirements"
            else
                warning "MariaDB version still below 10.11.0 - consider manual upgrade"
            fi
        fi
    fi
    
    local current_max_vars=$(php -r "echo ini_get('max_input_vars');")
    if [[ "$current_max_vars" -ge 5000 ]]; then
        success "max_input_vars: $current_max_vars (sufficient)"
    else
        warning "max_input_vars is still $current_max_vars - should be 5000+"
        log "Add this to your PHP configuration:"
        log "max_input_vars = 5000"
    fi
    
    # Check if emergency backup was created
    if [[ -f "/tmp/last_emergency_backup_path" ]]; then
        local emergency_path=$(cat /tmp/last_emergency_backup_path)
        log "Emergency database backup available at: $emergency_path"
    fi
    
    log "For asynchronous backups, see: Admin → Server → Asynchronous backups"
    
    # Final status check
    if grep -q "maintenance_enabled.*true" "$moodle_path/config.php" 2>/dev/null; then
        warning "WARNING: Maintenance mode appears to still be active!"
        warning "Manually disable with: sed -i '/maintenance_enabled.*true/d' $moodle_path/config.php"
    else
        success "Maintenance mode successfully disabled - site is online!"
    fi
}

# Execute script
main "$@"
