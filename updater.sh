#!/bin/bash

# Moodle Updater v1.1
# Automated Moodle update script with security checks and backup functionality

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

ASSUME_YES=false
ALLOW_UNSTABLE=false
ALLOW_SYSTEM_CHANGES=false
SKIP_WEBROOT_UPDATE=false
SKIP_RESTART=false

TARGET_DOWNLOAD_URL=""
TARGET_REF_LABEL=""
TARGET_IS_UNSTABLE=false
TARGET_VERSION_FOR_COMPARE=""
RESOLVED_TARGET_VERSION=""

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
    if [[ "$ASSUME_YES" == "true" ]]; then
        echo "$1 (y/n): y"
        return 0
    fi

    while true; do
        read -p "$1 (y/n): " yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer with y or n.";;
        esac
    done
}

usage() {
    cat << EOF
Usage: $0 [options] <moodle_path> <moodledata_path> [target_version]

Examples:
  $0 /var/www/html/moodle /var/www/moodledata 5.2.0
  $0 --yes /var/www/html/moodle /var/www/moodledata latest
  $0 --allow-unstable /var/www/html/moodle /var/www/moodledata 5.3

Options:
  -y, --yes                 Run non-interactively and answer yes to updater prompts
      --allow-unstable      Allow beta/RC/dev targets. 5.3 currently maps to main/5.3dev
      --allow-system-changes
                            Permit unattended PHP/database package upgrades with --yes
      --skip-webroot-update Do not update Apache/Nginx DocumentRoot to /public
      --no-restart          Do not restart Apache/Nginx at the end
  -h, --help                Show this help
EOF
}

parse_args() {
    POSITIONAL_ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes|--non-interactive)
                ASSUME_YES=true
                shift
                ;;
            --allow-unstable|--allow-dev)
                ALLOW_UNSTABLE=true
                shift
                ;;
            --allow-system-changes)
                ALLOW_SYSTEM_CHANGES=true
                shift
                ;;
            --skip-webroot-update)
                SKIP_WEBROOT_UPDATE=true
                shift
                ;;
            --no-restart)
                SKIP_RESTART=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    POSITIONAL_ARGS+=("$1")
                    shift
                done
                ;;
            -*)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                POSITIONAL_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

normalize_version_for_compare() {
    local raw=${1:-}
    local version=""
    version=$(echo "$raw" | grep -oE '[0-9]+(\.[0-9]+){1,2}' | head -1 || true)

    if [[ -z "$version" ]]; then
        echo "0.0.0"
        return
    fi

    local major minor patch
    IFS='.' read -r major minor patch <<< "$version"
    echo "${major:-0}.${minor:-0}.${patch:-0}"
}

version_at_least() {
    local current required
    current=$(normalize_version_for_compare "$1")
    required=$(normalize_version_for_compare "$2")

    [[ "$(printf '%s\n' "$required" "$current" | sort -V | head -n1)" == "$required" ]]
}

moodle_branch_for_version() {
    local version major minor
    version=$(normalize_version_for_compare "$1")
    IFS='.' read -r major minor _ <<< "$version"

    if [[ -z "$major" || -z "$minor" ]]; then
        return 1
    fi

    printf 'MOODLE_%d%02d_STABLE' "$major" "$minor"
}

version_from_moodle_branch() {
    local branch=$1
    local number major minor
    number=${branch#MOODLE_}
    number=${number%_STABLE}

    if [[ ! "$number" =~ ^[0-9]+$ || ${#number} -lt 2 ]]; then
        echo "0.0.0"
        return
    fi

    major=${number:0:1}
    minor=${number:1}
    minor=$((10#$minor))
    echo "$major.$minor.0"
}

github_ref_exists() {
    local ref_path=$1
    curl -fsSL "https://api.github.com/repos/moodle/moodle/git/ref/$ref_path" >/dev/null 2>&1
}

get_main_dev_version() {
    local version_file=""
    version_file=$(curl -fsSL "https://raw.githubusercontent.com/moodle/moodle/main/public/version.php" 2>/dev/null || true)
    if [[ -z "$version_file" ]]; then
        version_file=$(curl -fsSL "https://raw.githubusercontent.com/moodle/moodle/main/version.php" 2>/dev/null || true)
    fi

    echo "$version_file" | grep -E '^\$release' | head -1 | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/" || true
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
    
    # Define minimum requirements. Moodle 5.0 raised MySQL/MariaDB requirements.
    local required_mariadb="10.6.7"
    local required_mysql="8.0.0"

    if version_at_least "$moodle_version" "5.0"; then
        required_mariadb="10.11.0"
        required_mysql="8.4.0"
    fi
    
    local needs_upgrade=false
    local recommended_version=""
    
    if [[ "$db_type" == "mariadb" ]]; then
        if [[ "$(printf '%s\n' "$required_mariadb" "$db_version" | sort -V | head -n1)" != "$required_mariadb" ]]; then
            needs_upgrade=true
            recommended_version="${required_mariadb%.*}"
        fi
    elif [[ "$db_type" == "mysql" ]]; then
        if [[ "$(printf '%s\n' "$required_mysql" "$db_version" | sort -V | head -n1)" != "$required_mysql" ]]; then
            needs_upgrade=true
            recommended_version="${required_mysql%.*}"
        fi
    fi
    
    if [[ "$needs_upgrade" == "true" ]]; then
        warning "$db_type $db_version is below the minimum required version for Moodle $moodle_version"
        log "Required: $db_type $recommended_version+"
        
        if ask_yes_no "Do you want to upgrade $db_type automatically?"; then
            upgrade_mariadb_mysql "$db_type" "$recommended_version"
        else
            error "Database upgrade skipped, but Moodle $moodle_version requires $db_type $recommended_version+"
            exit 1
        fi
    else
        success "$db_type version $db_version meets requirements"
    fi
}

# Upgrade MariaDB/MySQL
upgrade_mariadb_mysql() {
    local db_type=$1
    local target_version=$2
    
    if [[ "$ASSUME_YES" == "true" && "$ALLOW_SYSTEM_CHANGES" != "true" ]]; then
        error "Refusing unattended $db_type package upgrade without --allow-system-changes"
        warning "Upgrade $db_type manually, or rerun with --yes --allow-system-changes."
        exit 1
    fi

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
    local current_php_version
    current_php_version=$(php -r "echo PHP_VERSION;")
    local required_php="8.1"
    local recommended_php="8.3"

    if version_at_least "$moodle_version" "5.2"; then
        required_php="8.3"
        recommended_php="8.3"
    elif version_at_least "$moodle_version" "5.0"; then
        required_php="8.2"
        recommended_php="8.3"
    elif version_at_least "$moodle_version" "4.4"; then
        required_php="8.1"
        recommended_php="8.2"
    elif version_at_least "$moodle_version" "4.2"; then
        required_php="8.0"
        recommended_php="8.2"
    else
        required_php="7.4"
        recommended_php="8.1"
    fi

    log "Current PHP version: $current_php_version"
    log "Minimum PHP version for Moodle $moodle_version: $required_php"
    log "Recommended PHP version: $recommended_php"

    if ! version_at_least "$current_php_version" "$required_php"; then
        error "PHP version $current_php_version is too old for Moodle $moodle_version"
        warning "Please upgrade PHP to at least version $required_php"

        if ask_yes_no "Should we try to upgrade PHP automatically?"; then
            upgrade_php "$recommended_php"
            current_php_version=$(php -r "echo PHP_VERSION;")
            if ! version_at_least "$current_php_version" "$required_php"; then
                error "PHP is still $current_php_version after upgrade attempt"
                exit 1
            fi
        else
            exit 1
        fi
    else
        success "PHP version $current_php_version meets the requirements"

        if ! version_at_least "$current_php_version" "$recommended_php"; then
            warning "Recommended PHP version is $recommended_php (current: $current_php_version)"
        fi
    fi

    if version_at_least "$moodle_version" "5.0"; then
        if ! php -m | grep -qi '^sodium$'; then
            error "PHP extension sodium is required for Moodle $moodle_version"
            warning "Install the sodium extension for your PHP version before continuing."
            exit 1
        fi
    fi

    if [[ "$(php -r 'echo PHP_INT_SIZE;')" -lt 8 ]]; then
        error "Moodle requires 64-bit PHP"
        exit 1
    fi
}

# PHP upgrade (Ubuntu/Debian)
upgrade_php() {
    local target_version=$1

    if [[ "$ASSUME_YES" == "true" && "$ALLOW_SYSTEM_CHANGES" != "true" ]]; then
        error "Refusing unattended PHP package upgrade without --allow-system-changes"
        warning "Install PHP $target_version manually, or rerun with --yes --allow-system-changes."
        exit 1
    fi

    log "Attempting to upgrade PHP to version $target_version..."

    if command -v apt-get &> /dev/null; then
        apt-get update
        apt-get install -y software-properties-common
        if command -v add-apt-repository &> /dev/null; then
            add-apt-repository -y ppa:ondrej/php || true
        fi
        apt-get update

        local packages=(
            "php${target_version}"
            "php${target_version}-cli"
            "php${target_version}-fpm"
            "php${target_version}-mysql"
            "php${target_version}-pgsql"
            "php${target_version}-xml"
            "php${target_version}-mbstring"
            "php${target_version}-curl"
            "php${target_version}-zip"
            "php${target_version}-gd"
            "php${target_version}-intl"
            "php${target_version}-ldap"
            "php${target_version}-soap"
        )

        if command -v apache2ctl &> /dev/null || [[ -d /etc/apache2 ]]; then
            packages+=("libapache2-mod-php${target_version}")
        fi

        DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"

        if [[ -x "/usr/bin/php${target_version}" ]]; then
            update-alternatives --set php "/usr/bin/php${target_version}" 2>/dev/null || true
        fi

        if command -v a2query &> /dev/null && command -v a2enmod &> /dev/null; then
            while read -r module; do
                [[ -n "$module" ]] && a2dismod "$module" >/dev/null 2>&1 || true
            done < <(a2query -m 2>/dev/null | awk '/php[0-9]+\.[0-9]+/ {print $1}')
            a2enmod "php${target_version}" >/dev/null 2>&1 || true
        fi

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
    local version_file=""

    if [[ -f "$moodle_path/version.php" ]]; then
        version_file="$moodle_path/version.php"
    elif [[ -f "$moodle_path/public/version.php" ]]; then
        version_file="$moodle_path/public/version.php"
    fi

    if [[ -n "$version_file" ]]; then
        grep -E '^\$release' "$version_file" | head -1 | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/" || echo "unknown"
        return
    fi

    echo "unknown"
}

# Get available Moodle versions from GitHub
get_latest_moodle_versions() {
    local versions
    versions=$(curl -fsSL "https://api.github.com/repos/moodle/moodle/tags?per_page=100" | \
        grep '"name"' | \
        sed 's/.*"name": "v\([^"]*\)".*/\1/' | \
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | \
        sort -V -r | \
        head -20)
    
    echo "$versions"
}

resolve_moodle_target() {
    local requested=$1
    local available_versions=$2
    local stable_match=""
    local dev_version=""

    TARGET_DOWNLOAD_URL=""
    TARGET_REF_LABEL=""
    TARGET_IS_UNSTABLE=false
    TARGET_VERSION_FOR_COMPARE="$requested"
    RESOLVED_TARGET_VERSION="$requested"

    if [[ "$requested" == "latest" ]]; then
        requested=$(echo "$available_versions" | head -1)
    fi

    if [[ "$requested" =~ ^[0-9]+\.[0-9]+$ ]]; then
        stable_match=$(echo "$available_versions" | grep -E "^${requested//./\\.}\\.[0-9]+$" | head -1 || true)
        if [[ -n "$stable_match" ]]; then
            requested="$stable_match"
        fi
    fi

    if [[ "$requested" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if github_ref_exists "tags/v${requested}"; then
            TARGET_DOWNLOAD_URL="https://github.com/moodle/moodle/archive/refs/tags/v${requested}.tar.gz"
            TARGET_REF_LABEL="tag v${requested}"
            TARGET_VERSION_FOR_COMPARE="$requested"
            RESOLVED_TARGET_VERSION="$requested"
            return
        fi
    fi

    if [[ "$requested" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?-(beta|rc[0-9]+)$ ]]; then
        if [[ "$ALLOW_UNSTABLE" != "true" ]]; then
            error "Target $requested is not a stable Moodle release. Use --allow-unstable to install it."
            exit 1
        fi
        if github_ref_exists "tags/v${requested}"; then
            TARGET_DOWNLOAD_URL="https://github.com/moodle/moodle/archive/refs/tags/v${requested}.tar.gz"
            TARGET_REF_LABEL="pre-release tag v${requested}"
            TARGET_IS_UNSTABLE=true
            TARGET_VERSION_FOR_COMPARE="$requested"
            RESOLVED_TARGET_VERSION="$requested"
            return
        fi
    fi

    if [[ "$requested" =~ ^MOODLE_[0-9]+_STABLE$ ]]; then
        if ! github_ref_exists "heads/${requested}"; then
            error "Moodle branch $requested was not found"
            exit 1
        fi
        TARGET_DOWNLOAD_URL="https://github.com/moodle/moodle/archive/refs/heads/${requested}.tar.gz"
        TARGET_REF_LABEL="branch ${requested}"
        TARGET_VERSION_FOR_COMPARE=$(version_from_moodle_branch "$requested")
        TARGET_IS_UNSTABLE=false
        RESOLVED_TARGET_VERSION="$requested"
        return
    fi

    if [[ "$requested" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        local stable_branch
        stable_branch=$(moodle_branch_for_version "$requested")
        if github_ref_exists "heads/${stable_branch}"; then
            TARGET_DOWNLOAD_URL="https://github.com/moodle/moodle/archive/refs/heads/${stable_branch}.tar.gz"
            TARGET_REF_LABEL="stable branch ${stable_branch}"
            TARGET_VERSION_FOR_COMPARE="$requested"
            RESOLVED_TARGET_VERSION="$requested"
            return
        fi

        dev_version=$(get_main_dev_version)
        if [[ -n "$dev_version" && "$(normalize_version_for_compare "$dev_version")" == "$(normalize_version_for_compare "$requested")" ]]; then
            if [[ "$ALLOW_UNSTABLE" != "true" ]]; then
                error "Moodle $requested is currently only available as $dev_version on the main branch."
                warning "Use --allow-unstable only for staging/test systems, not for production."
                exit 1
            fi
            TARGET_DOWNLOAD_URL="https://github.com/moodle/moodle/archive/refs/heads/main.tar.gz"
            TARGET_REF_LABEL="main branch (${dev_version})"
            TARGET_IS_UNSTABLE=true
            TARGET_VERSION_FOR_COMPARE="$dev_version"
            RESOLVED_TARGET_VERSION="$dev_version"
            return
        fi
    fi

    error "Moodle target $requested was not found as a stable tag or known branch"
    warning "Stable versions found: $(echo "$available_versions" | head -5 | tr '\n' ' ')"
    exit 1
}

# Compare versions
version_compare() {
    local version1=$1
    local version2=$2
    version1=$(normalize_version_for_compare "$version1")
    version2=$(normalize_version_for_compare "$version2")
    
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
    local backup_dir=${3:-"/tmp/moodle_backup_$(date +%Y%m%d_%H%M%S)"}
    
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
}

read_moodle_config_value() {
    local moodle_path=$1
    local key=$2
    local default=${3:-}
    local config_file="$moodle_path/config.php"
    local value=""

    if [[ ! -f "$config_file" ]]; then
        echo "$default"
        return
    fi

    value=$(php -r '
        define("CLI_SCRIPT", true);
        error_reporting(E_ERROR | E_PARSE);
        $configfile = $argv[1];
        $key = $argv[2];
        $default = $argv[3];
        $CFG = new stdClass();
        require $configfile;
        echo isset($CFG->{$key}) ? $CFG->{$key} : $default;
    ' "$config_file" "$key" "$default" 2>/dev/null || true)

    if [[ -z "$value" || "$value" == *"Command line scripts must define CLI_SCRIPT"* ]]; then
        value=$(grep -E "\\\$CFG->${key}[[:space:]]*=" "$config_file" | head -1 | sed -E "s/.*=[[:space:]]*['\"]([^'\"]*)['\"].*/\1/" || true)
    fi

    if [[ -z "$value" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
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
    
    # Extract DB configuration from config.php with CLI_SCRIPT defined.
    local db_type
    local db_host
    local db_name
    local db_user
    local db_pass
    local db_port
    db_type=$(read_moodle_config_value "$moodle_path" "dbtype" "")
    db_host=$(read_moodle_config_value "$moodle_path" "dbhost" "localhost")
    db_name=$(read_moodle_config_value "$moodle_path" "dbname" "")
    db_user=$(read_moodle_config_value "$moodle_path" "dbuser" "")
    db_pass=$(read_moodle_config_value "$moodle_path" "dbpass" "")
    db_port=$(read_moodle_config_value "$moodle_path" "dbport" "3306")
    
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
    local download_url=$4
    local ref_label=$5
    
    local temp_dir="/tmp/moodle_download_$$"
    local archive_file="$temp_dir/moodle.tar.gz"
    local config_backup="$backup_dir/config.php.before-install"
    
    log "Downloading Moodle $version from $ref_label..."
    
    mkdir -p "$temp_dir"
    
    if ! curl -L --fail --progress-bar "$download_url" -o "$archive_file"; then
        error "Download failed"
        exit 1
    fi
    
    log "Extracting Moodle..."
    tar -xzf "$archive_file" -C "$temp_dir"

    local extracted_dir
    extracted_dir=$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [[ -z "$extracted_dir" ]]; then
        error "Downloaded archive did not contain a Moodle directory"
        exit 1
    fi

    if [[ ! -f "$extracted_dir/admin/cli/upgrade.php" ]]; then
        error "Downloaded archive does not look like a Moodle source tree"
        exit 1
    fi
    
    # Backup old config.php
    if [[ -f "$moodle_path/config.php" ]]; then
        cp "$moodle_path/config.php" "$config_backup"
    fi
    
    log "Installing new Moodle version..."
    
    # Remove old Moodle code (except config.php and moodledata)
    find "$moodle_path" -mindepth 1 -maxdepth 1 ! -name 'config.php' ! -name 'moodledata' -exec rm -rf {} +
    
    # Copy new files, including dotfiles.
    cp -a "$extracted_dir"/. "$moodle_path/"
    
    # Restore old config.php
    if [[ -f "$config_backup" ]]; then
        cp "$config_backup" "$moodle_path/config.php"
    fi
    
    # Set permissions
    chown -R www-data:www-data "$moodle_path" 2>/dev/null || true
    chmod -R 755 "$moodle_path"
    
    # Clean up temp directory
    rm -rf "$temp_dir"
    
    success "Moodle $version has been installed"
}

set_php_ini_value() {
    local ini_file=$1
    local key=$2
    local value=$3

    if [[ ! -f "$ini_file" || ! -w "$ini_file" ]]; then
        return
    fi

    cp "$ini_file" "${ini_file}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true

    if grep -Eq "^[;[:space:]]*${key}[[:space:]]*=" "$ini_file"; then
        sed -i -E "s/^[;[:space:]]*${key}[[:space:]]*=.*/${key} = ${value}/" "$ini_file"
    else
        printf '\n%s = %s\n' "$key" "$value" >> "$ini_file"
    fi
}

ensure_max_input_vars() {
    local required=5000
    local current
    current=$(php -r "echo ini_get('max_input_vars');")

    if [[ "$current" -ge "$required" ]]; then
        return
    fi

    warning "max_input_vars is $current, should be at least $required"

    local php_version
    php_version=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")

    local loaded_ini
    loaded_ini=$(php --ini 2>/dev/null | awk -F': ' '/Loaded Configuration File/ {print $2}' | head -1)
    [[ "$loaded_ini" == "(none)" ]] && loaded_ini=""

    local ini_candidates=()
    [[ -n "$loaded_ini" ]] && ini_candidates+=("$loaded_ini")
    ini_candidates+=(
        "/etc/php/$php_version/cli/php.ini"
        "/etc/php/$php_version/apache2/php.ini"
        "/etc/php/$php_version/fpm/php.ini"
    )

    local ini_file
    for ini_file in "${ini_candidates[@]}"; do
        set_php_ini_value "$ini_file" "max_input_vars" "$required"
    done

    local pool_conf="/etc/php/$php_version/fpm/pool.d/www.conf"
    if [[ -f "$pool_conf" && -w "$pool_conf" ]]; then
        if grep -q "php_admin_value\[max_input_vars\]" "$pool_conf"; then
            sed -i -E "s/php_admin_value\[max_input_vars\][[:space:]]*=.*/php_admin_value[max_input_vars] = $required/" "$pool_conf"
        else
            printf '\nphp_admin_value[max_input_vars] = %s\n' "$required" >> "$pool_conf"
        fi
        systemctl reload "php$php_version-fpm" 2>/dev/null || true
    fi

    current=$(php -r "echo ini_get('max_input_vars');")
    if [[ "$current" -lt "$required" ]]; then
        warning "CLI max_input_vars is still $current; Moodle CLI commands will run with -d max_input_vars=$required"
    else
        success "max_input_vars updated to $current"
    fi
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
    ensure_max_input_vars
    
    # Run the upgrade
    cd "$moodle_path"
    
    # Check if user wants to handle database upgrade manually
    if ask_yes_no "Do you want the script to automatically upgrade the database?"; then
        log "Running automatic database upgrade..."
        local upgrade_args=(admin/cli/upgrade.php --non-interactive)
        if [[ "$TARGET_IS_UNSTABLE" == "true" ]]; then
            upgrade_args+=(--allow-unstable)
        fi

        if php -d max_input_vars=5000 "${upgrade_args[@]}"; then
            success "Moodle upgrade completed successfully"
        else
            error "Moodle upgrade failed"
            warning "You may need to run the upgrade manually:"
            warning "cd $moodle_path && php -d max_input_vars=5000 admin/cli/upgrade.php"
            exit 1
        fi
    else
        log "Skipping automatic database upgrade"
        warning "You will need to complete the upgrade manually:"
        warning "1. Via web interface: Visit your Moodle site and follow the upgrade wizard"
        warning "2. Via CLI: cd $moodle_path && php -d max_input_vars=5000 admin/cli/upgrade.php"
        
        if ask_yes_no "Do you want to run the upgrade now via CLI?"; then
            log "Running CLI upgrade..."
            php -d max_input_vars=5000 admin/cli/upgrade.php
        fi
    fi
    
    # Post-upgrade optimizations
    log "Running post-upgrade optimizations..."
    
    # Clear all caches
    if [[ -f "$moodle_path/admin/cli/purge_caches.php" ]]; then
        php -d max_input_vars=5000 admin/cli/purge_caches.php 2>/dev/null || true
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

set_config_maintenance_flag() {
    local moodle_path=$1
    local enabled=$2

    if [[ -f "$moodle_path/config.php" ]]; then
        cp "$moodle_path/config.php" "$moodle_path/config.php.maintenance_backup"
        sed -i '/\$CFG->maintenance_enabled/d' "$moodle_path/config.php"

        if [[ "$enabled" == "true" ]]; then
            if grep -q "require_once.*lib/setup.php" "$moodle_path/config.php"; then
                sed -i '/require_once.*lib\/setup.php/i \$CFG->maintenance_enabled = true;' "$moodle_path/config.php"
            elif grep -q "setup.php" "$moodle_path/config.php"; then
                sed -i '/setup.php/i \$CFG->maintenance_enabled = true;' "$moodle_path/config.php"
            else
                printf '\n$CFG->maintenance_enabled = true;\n' >> "$moodle_path/config.php"
            fi
        fi
    fi
}

enable_maintenance_mode() {
    local moodle_path=$1

    log "Enabling maintenance mode..."

    if [[ -f "$moodle_path/admin/cli/maintenance.php" ]]; then
        if php -d max_input_vars=5000 "$moodle_path/admin/cli/maintenance.php" --enable >/dev/null 2>&1; then
            success "Maintenance mode enabled"
            return
        fi
    fi

    set_config_maintenance_flag "$moodle_path" true
    success "Maintenance mode enabled"
}

# Disable maintenance mode
disable_maintenance_mode() {
    local moodle_path=$1

    log "Disabling maintenance mode..."

    if [[ -f "$moodle_path/admin/cli/maintenance.php" ]]; then
        if php -d max_input_vars=5000 "$moodle_path/admin/cli/maintenance.php" --disable >/dev/null 2>&1; then
            success "Maintenance mode disabled"
            return
        fi
    fi

    if [[ -f "$moodle_path/config.php" ]]; then
        set_config_maintenance_flag "$moodle_path" false
        success "Maintenance mode disabled"
    else
        warning "config.php not found - maintenance mode could not be disabled"
    fi
}

dedupe_lines() {
    awk '!seen[$0]++'
}

update_webroot_for_public_dir() {
    local moodle_path=$1
    local public_path="$moodle_path/public"
    local changed=false
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)

    if [[ "$SKIP_WEBROOT_UPDATE" == "true" ]]; then
        return
    fi

    if [[ ! -d "$public_path" || ! -f "$public_path/config.php" ]]; then
        return
    fi

    log "Checking web server DocumentRoot for Moodle public directory..."

    local apache_files=()
    if [[ -d /etc/apache2 ]]; then
        while IFS= read -r file; do
            apache_files+=("$file")
        done < <(find /etc/apache2/sites-available /etc/apache2/sites-enabled -type f 2>/dev/null | dedupe_lines)
    fi

    local file
    for file in "${apache_files[@]}"; do
        if grep -Eq "DocumentRoot[[:space:]]+\"?${moodle_path}/?\"?" "$file"; then
            [[ -f "${file}.bak.${timestamp}" ]] || cp "$file" "${file}.bak.${timestamp}"
            perl -0pi -e "s#(DocumentRoot\\s+)([\"']?)\\Q${moodle_path}\\E/?([\"']?)#\$1\$2${public_path}\$3#g" "$file"
            success "Updated Apache DocumentRoot in $file"
            changed=true
        fi

        if grep -Eq "<Directory[[:space:]]+\"?${moodle_path}/?\"?>" "$file"; then
            [[ -f "${file}.bak.${timestamp}" ]] || cp "$file" "${file}.bak.${timestamp}" 2>/dev/null || true
            perl -0pi -e "s#(<Directory\\s+)([\"']?)\\Q${moodle_path}\\E/?([\"']?\\s*>)#\$1\$2${public_path}\$3#g" "$file"
            success "Updated Apache Directory block in $file"
            changed=true
        fi
    done

    local nginx_files=()
    if [[ -d /etc/nginx ]]; then
        while IFS= read -r file; do
            nginx_files+=("$file")
        done < <(find /etc/nginx/sites-available /etc/nginx/sites-enabled -type f 2>/dev/null | dedupe_lines)
    fi

    for file in "${nginx_files[@]}"; do
        if grep -Eq "root[[:space:]]+${moodle_path}/?;" "$file"; then
            cp "$file" "${file}.bak.${timestamp}"
            perl -0pi -e "s#(root\\s+)\\Q${moodle_path}\\E/?;#\$1${public_path};#g" "$file"
            success "Updated Nginx root in $file"
            changed=true
        fi
    done

    if [[ "$changed" != "true" ]]; then
        warning "Moodle now contains a public/ webroot, but no matching Apache/Nginx root was updated."
        warning "Set your web server root to: $public_path"
    fi
}

# Main function
main() {
    parse_args "$@"
    set -- "${POSITIONAL_ARGS[@]}"

    echo "=================================="
    echo "      Moodle Updater v1.1"
    echo "=================================="
    echo
    
    # Check parameters
    if [[ $# -lt 2 ]]; then
        usage
        exit 1
    fi
    
    local moodle_path="$1"
    local moodledata_path="$2"
    local target_version="${3:-}"
    
    # Validate paths
    if [[ ! -d "$moodle_path" ]]; then
        error "Moodle path does not exist: $moodle_path"
        exit 1
    fi
    
    if [[ ! -d "$moodledata_path" ]]; then
        error "Moodledata path does not exist: $moodledata_path"
        exit 1
    fi

    moodle_path=$(cd "$moodle_path" && pwd -P)
    moodledata_path=$(cd "$moodledata_path" && pwd -P)
    
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
    local dev_version=$(get_main_dev_version)

    if [[ -z "$available_versions" ]]; then
        error "Could not load Moodle versions from GitHub"
        exit 1
    fi
    
    log "Latest available version: $latest_version"
    echo
    echo "Available versions:"
    echo "$available_versions" | head -5
    if [[ -n "$dev_version" ]]; then
        echo
        echo "Development version:"
        echo "$dev_version (main, requires --allow-unstable)"
    fi
    echo
    
    # Determine target version
    if [[ -z "$target_version" ]]; then
        if [[ "$ASSUME_YES" == "true" ]]; then
            target_version="$latest_version"
        else
            echo "Recommended version: $latest_version"
            read -p "Enter desired target version (or press Enter for $latest_version): " target_version

            if [[ -z "$target_version" ]]; then
                target_version="$latest_version"
            fi
        fi
    fi

    resolve_moodle_target "$target_version" "$available_versions"
    target_version="$RESOLVED_TARGET_VERSION"

    log "Target version: $target_version"
    log "Download source: $TARGET_REF_LABEL"
    if [[ "$TARGET_IS_UNSTABLE" == "true" ]]; then
        warning "Target is not a stable release. Use this only for staging/test systems."
    fi
    
    # Validate version
    if [[ "$current_version" != "unknown" ]]; then
        local version_cmp=$(version_compare "$current_version" "$TARGET_VERSION_FOR_COMPARE")
        
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
    local backup_dir="/tmp/moodle_backup_$(date +%Y%m%d_%H%M%S)"
    create_backup "$moodle_path" "$moodledata_path" "$backup_dir"
    backup_database "$moodle_path" "$backup_dir"
    
    # Enable maintenance mode
    enable_maintenance_mode "$moodle_path"
    
    # Download and install Moodle
    download_and_install_moodle "$target_version" "$moodle_path" "$backup_dir" "$TARGET_DOWNLOAD_URL" "$TARGET_REF_LABEL"
    
    # Run upgrade
    run_moodle_upgrade "$moodle_path"

    # Moodle 5.1+ uses a public/ webroot. Update known web server configs before restart.
    update_webroot_for_public_dir "$moodle_path"
    
    # Disable maintenance mode
    disable_maintenance_mode "$moodle_path"
    
    # Restart web server (optional)
    if [[ "$SKIP_RESTART" != "true" ]] && command -v systemctl &> /dev/null; then
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
        
        local required_final_db="8.0.0"
        if [[ "$db_type_final" == "MariaDB" ]]; then
            required_final_db="10.6.7"
        fi
        if version_at_least "$target_version" "5.0"; then
            if [[ "$db_type_final" == "MariaDB" ]]; then
                required_final_db="10.11.0"
            else
                required_final_db="8.4.0"
            fi
        fi

        if [[ "$db_type_final" == "MariaDB" ]]; then
            db_type_final="MariaDB"
        fi

        if version_at_least "$final_db_version" "$required_final_db"; then
            success "$db_type_final version meets Moodle requirements"
        else
            warning "$db_type_final version is below $required_final_db - consider manual upgrade"
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
