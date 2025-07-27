#!/bin/bash

# Moodle Update Script
# Updates Moodle to the desired version with security checks

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

# Check and recommend PHP version
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
    
    # Extract DB configuration from config.php
    local db_type=$(grep '$CFG->dbtype' "$moodle_path/config.php" | sed "s/.*'\([^']*\)'.*/\1/" 2>/dev/null || echo "")
    local db_host=$(grep '$CFG->dbhost' "$moodle_path/config.php" | sed "s/.*'\([^']*\)'.*/\1/" 2>/dev/null || echo "localhost")
    local db_name=$(grep '$CFG->dbname' "$moodle_path/config.php" | sed "s/.*'\([^']*\)'.*/\1/" 2>/dev/null || echo "")
    local db_user=$(grep '$CFG->dbuser' "$moodle_path/config.php" | sed "s/.*'\([^']*\)'.*/\1/" 2>/dev/null || echo "")
    local db_pass=$(grep '$CFG->dbpass' "$moodle_path/config.php" | sed "s/.*'\([^']*\)'.*/\1/" 2>/dev/null || echo "")
    
    if [[ -z "$db_name" || -z "$db_user" ]]; then
        warning "Database settings incomplete - backup skipped"
        return
    fi
    
    if [[ "$db_type" == "mysqli" || "$db_type" == "mariadb" ]]; then
        if command -v mysqldump &> /dev/null; then
            if mysqldump -h"$db_host" -u"$db_user" -p"$db_pass" "$db_name" > "$backup_dir/database_backup.sql" 2>/dev/null; then
                success "MySQL/MariaDB backup created"
            else
                warning "MySQL backup failed - possibly wrong credentials"
            fi
        else
            warning "mysqldump not found - MySQL backup skipped"
        fi
    elif [[ "$db_type" == "pgsql" ]]; then
        if command -v pg_dump &> /dev/null; then
            if PGPASSWORD="$db_pass" pg_dump -h "$db_host" -U "$db_user" "$db_name" > "$backup_dir/database_backup.sql" 2>/dev/null; then
                success "PostgreSQL backup created"
            else
                warning "PostgreSQL backup failed - possibly wrong credentials"
            fi
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

# Run Moodle upgrade
run_moodle_upgrade() {
    local moodle_path=$1
    
    log "Running Moodle upgrade..."
    
    if [[ -f "$moodle_path/admin/cli/upgrade.php" ]]; then
        cd "$moodle_path"
        php admin/cli/upgrade.php --non-interactive --allow-unstable
        success "Moodle upgrade completed"
    else
        error "Upgrade script not found"
        exit 1
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
    echo "    Moodle Update Script v1.0"
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
    success "Maintenance mode: DISABLED ✅"
    
    log "Please test your Moodle installation thoroughly."
    
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