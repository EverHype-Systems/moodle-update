# Moodle Updater v1.1

[![GitHub Release](https://img.shields.io/github/v/release/EverHype-Systems/moodle-update)](https://github.com/EverHype-Systems/moodle-update/releases)
[![License](https://img.shields.io/github/license/EverHype-Systems/moodle-update)](https://github.com/EverHype-Systems/moodle-update/blob/main/LICENSE)
[![GitHub Issues](https://img.shields.io/github/issues/EverHype-Systems/moodle-update)](https://github.com/EverHype-Systems/moodle-update/issues)
[![GitHub Stars](https://img.shields.io/github/stars/EverHype-Systems/moodle-update)](https://github.com/EverHype-Systems/moodle-update/stargazers)

Automated Moodle update script with comprehensive backup, security checks, and maintenance mode handling.

## Features

- **Automated Updates**: Download and install any Moodle version from GitHub releases
- **Stable/Dev Resolution**: Stable versions use `vX.Y.Z` tags; unreleased/dev targets require `--allow-unstable`
- **Smart Backup System**: Automatic backup of code, database, and critical data
- **PHP Compatibility**: Automatic PHP version checking and upgrade support
- **Non-interactive Runs**: `--yes` supports unattended runs after pre-flight validation
- **Public Webroot Handling**: Updates Apache/Nginx roots to Moodle `public/` when needed
- **Version Validation**: Prevents downgrades and validates target versions
- **Maintenance Mode**: Automatic maintenance mode during updates
- **Database Support**: MySQL, MariaDB, and PostgreSQL backup support
- **Security Focused**: Proper permissions and security hardening
- **Progress Tracking**: Real-time progress with colored output
- **Web Server Integration**: Automatic web server restart after updates

## Requirements

- **Operating System**: Ubuntu/Debian (preferred), CentOS/RHEL compatible
- **Privileges**: Root access (sudo) required
- **PHP**: Version compatible with the target Moodle release. Moodle 5.2+ requires PHP 8.3+
- **Database**: MySQL/MariaDB or PostgreSQL
- **Web Server**: Apache2 or Nginx
- **Tools**: curl, tar, sed, grep, systemctl

## Installation

### Quick Install
```bash
# Download directly from GitHub
curl -o updater.sh https://raw.githubusercontent.com/EverHype-Systems/moodle-update/main/updater.sh
chmod +x updater.sh
```

### Clone Repository
```bash
# Clone the repository
git clone https://github.com/EverHype-Systems/moodle-update.git
cd moodle-update
chmod +x updater.sh
```

### Verify Download
```bash
# Check script integrity
sha256sum updater.sh
# Compare with hash from GitHub releases
```

## Usage

### Basic Usage
```bash
# Interactive mode - will prompt for version
sudo ./updater.sh /var/www/html/moodle /var/www/moodledata

# Specify target version
sudo ./updater.sh /var/www/html/moodle /var/www/moodledata 5.2.0

# Update to latest available version
sudo ./updater.sh /var/www/html/moodle /var/www/moodledata latest

# Non-interactive run, only when all requirements already pass
sudo ./updater.sh --yes /var/www/html/moodle /var/www/moodledata latest

# Permit unattended PHP/database package changes as well
sudo ./updater.sh --yes --allow-system-changes /var/www/html/moodle /var/www/moodledata 5.2.0

# Install an unreleased/dev target such as 5.3dev from main (staging only)
sudo ./updater.sh --allow-unstable /var/www/html/moodle /var/www/moodledata 5.3
```

### Options

```bash
-y, --yes                 Run non-interactively and answer yes to updater prompts
    --allow-unstable      Allow beta, RC, or dev targets such as 5.3dev
    --allow-system-changes
                          Permit unattended PHP/database package upgrades with --yes
    --skip-webroot-update Do not update Apache/Nginx DocumentRoot to /public
    --no-restart          Do not restart Apache/Nginx at the end
```

### Examples

**Standard Moodle Installation:**
```bash
sudo ./updater.sh /var/www/html/moodle /var/www/moodledata
```

**Custom Paths:**
```bash
sudo ./updater.sh /opt/moodle /opt/moodledata 4.4.2
```

**Development/Testing Environment:**
```bash
sudo ./updater.sh --allow-unstable /home/user/moodle /home/user/moodledata 5.3
```

## Directory Structure

The script expects the following structure:
```
/var/www/html/moodle/          # Moodle code directory
├── admin/                     # Moodle admin directory
├── config.php                 # Moodle configuration
├── version.php                # Version information
└── ...                        # Other Moodle files

/var/www/moodledata/           # Moodle data directory
├── cache/                     # Cache files
├── sessions/                  # Session data
├── temp/                      # Temporary files
└── ...                        # Other data files
```

## Security Features

### Backup System
- **Automatic Backups**: Created before any changes
- **Multiple Backup Types**: Code, database, and configuration
- **Timestamp Naming**: Easy identification of backup versions
- **Safe Location**: Stored in `/tmp/moodle_backup_YYYYMMDD_HHMMSS/`

### Permission Management
- **Secure Defaults**: Proper file and directory permissions
- **Web Server User**: Automatic detection of web server user (www-data, apache, nginx)
- **Config Protection**: Secured config.php with restricted access
- **Maintenance Mode**: Automatic activation during updates

### Version Validation
- **Downgrade Prevention**: Blocks dangerous downgrades
- **PHP Compatibility**: Validates PHP version requirements
- **Version Comparison**: Intelligent semantic version comparison

## Troubleshooting

### Common Issues

**Permission Denied:**
```bash
# Ensure script has execute permissions
chmod +x updater.sh

# Run with sudo
sudo ./updater.sh [paths]
```

**PHP Version Too Old:**
```bash
# Script will prompt to auto-upgrade PHP
# Or manually upgrade PHP first:
sudo apt-get update
sudo apt-get install php8.3
```

**Download Failures:**
```bash
# Check internet connection
curl -I https://github.com

# Verify GitHub access
curl -s https://api.github.com/repos/moodle/moodle/tags | head
```

**Moodle 5.3 Is Not Listed As Stable:**
```bash
# Moodle 5.3 is currently resolved from the main branch as 5.3dev.
# Use this only in staging/testing:
sudo ./updater.sh --allow-unstable /var/www/html/moodle /var/www/moodledata 5.3
```

**Moodle 5.1+ Shows The Wrong Web Directory:**
```bash
# Moodle now ships a public/ webroot. The updater attempts to update Apache/Nginx.
# If skipped or not detected, set your site root manually to:
/var/www/html/moodle/public
```

**Database Backup Issues:**
```bash
# Ensure database tools are installed
sudo apt-get install mysql-client    # For MySQL/MariaDB
sudo apt-get install postgresql-client  # For PostgreSQL

# Verify database credentials in config.php
```

### Debug Mode

The script automatically enables debug mode during updates. To manually enable:

```php
// In config.php
$CFG->debug = 32767;
$CFG->debugdisplay = 1;
```

### Log Files

Check these locations for detailed error information:
- Web server logs: `/var/log/apache2/error.log` or `/var/log/nginx/error.log`
- PHP logs: `/var/log/php/error.log`
- Moodle logs: Via Admin → Reports → Logs in Moodle interface

## Update Process Flow

1. **Pre-flight Checks**
   - Validate paths and permissions
   - Check current Moodle version
   - Verify PHP compatibility
   - Fetch available versions

2. **Backup Phase**
   - Create timestamped backup directory
   - Backup Moodle code
   - Backup database
   - Backup configuration files

3. **Maintenance Mode**
   - Enable maintenance mode
   - Display maintenance message to users

4. **Update Phase**
   - Download target Moodle version
   - Extract and install new files
   - Preserve existing configuration
   - Set proper permissions

5. **Upgrade Process**
   - Run Moodle CLI upgrade script
   - Update database schema
   - Clear caches

6. **Finalization**
   - Disable maintenance mode
   - Restart web server
   - Verify installation
   - Display success status

## Recovery Process

If an update fails, recovery steps:

1. **Automatic Recovery:**
   ```bash
   # Restore from automatic backup
   BACKUP_DIR="/tmp/moodle_backup_YYYYMMDD_HHMMSS"
   sudo cp -r $BACKUP_DIR/moodle_code/* /var/www/html/moodle/
   sudo cp $BACKUP_DIR/config.php.backup /var/www/html/moodle/config.php
   ```

2. **Database Recovery:**
   ```bash
   # Restore database from backup
   mysql -u username -p database_name < $BACKUP_DIR/database_backup.sql
   ```

3. **Manual Maintenance Mode Disable:**
   ```bash
   # If maintenance mode is stuck
   sudo sed -i '/maintenance_enabled.*true/d' /var/www/html/moodle/config.php
   ```

## Advanced Configuration

### Custom PHP Paths
```bash
# If PHP is in non-standard location
export PATH="/opt/php8.3/bin:$PATH"
./updater.sh [paths]
```

### Custom Web Server User
```bash
# The script auto-detects, but you can modify the script:
# Edit line: WEB_USER="${3:-www-data}"
# Change www-data to your web server user
```

### Firewall Considerations
```bash
# Ensure outbound HTTPS is allowed
sudo ufw allow out 443
sudo ufw allow out 80
```

## Support

### Before Seeking Help

1. **Check Requirements**: Ensure all prerequisites are met
2. **Review Logs**: Check web server and PHP error logs
3. **Test Manually**: Verify Moodle works after update
4. **Backup Status**: Confirm backups were created successfully

### Getting Help

- **GitHub Issues**: [Report bugs or request features](https://github.com/EverHype-Systems/moodle-update/issues)
- **GitHub Discussions**: [Community support and questions](https://github.com/EverHype-Systems/moodle-update/discussions)
- **Moodle Community**: [moodle.org/support](https://moodle.org/support)
- **Documentation**: [docs.moodle.org](https://docs.moodle.org)

### Contributing

We welcome contributions! Please see our [Contributing Guidelines](https://github.com/EverHype-Systems/moodle-update/blob/main/CONTRIBUTING.md).

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

### Reporting Issues

When [reporting issues](https://github.com/EverHype-Systems/moodle-update/issues/new), include:
- Operating system and version
- Current Moodle version
- Target Moodle version
- PHP version
- Error messages
- Relevant log excerpts

## Security Notice

**Important Security Considerations:**

- Always test updates in a staging environment first
- Ensure you have complete system backups before major updates
- Review Moodle security announcements before updating
- Keep PHP and web server software updated
- Monitor file permissions after updates
- Verify database integrity after updates

## License

This script is provided as-is for educational and operational purposes. Use at your own risk and always maintain proper backups.

## Changelog

### v1.1 (Current)
- Fixed Moodle 5.1+ `public/` webroot handling
- Added explicit stable/dev target resolution for versions such as 5.3dev
- Fixed database backup config parsing by defining `CLI_SCRIPT`
- Fixed polluted backup path output during command substitution
- Updated PHP requirements for Moodle 5.2+
- Added `--yes`, `--allow-unstable`, `--allow-system-changes`, and restart/webroot controls

### v1.0
- Initial release
- Automated Moodle updates with backup
- PHP compatibility checking
- Database backup support
- Maintenance mode handling
- Multi-platform support
- Comprehensive error handling

---

**Happy Updating!**

For the latest version and updates, visit: https://github.com/EverHype-Systems/moodle-update
