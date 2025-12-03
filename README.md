# PostgreSQL Remote Backup Script

A simple, reliable Bash script for backing up PostgreSQL databases and transferring them to a remote server via SSH/SCP. Designed to work with Hetzner Storage Box and other SSH-accessible backup targets.

## Features

- **Complete Database Backup**: Uses `pg_dumpall` to backup all PostgreSQL databases, roles, and settings
- **Automatic Compression**: Compresses backups with gzip to save space
- **Secure Transfer**: Uses SSH/SCP with key-based authentication
- **Retention Management**: Automatically removes old backups from both local and remote locations
- **Comprehensive Logging**: Logs all operations with timestamps
- **Error Handling**: Validates each step and reports failures

## Requirements

- PostgreSQL client tools (`pg_dumpall`)
- SSH/SCP client
- Bash shell
- Sufficient disk space for temporary local backups

## Installation & Setup

### 1. Clone or Download the Script

```bash
cd /opt
git clone <repository-url> postgres-backup
cd postgres-backup
chmod +x pgbackup.sh
```

### 2. Set Up SSH Key for Remote Access

Generate an SSH key pair for automated backups (if you don't already have one):

```bash
# Generate SSH key (as root or the user who will run the backup)
ssh-keygen -t ed25519 -f /root/.ssh/backup_key -C "postgres-backup" -N ""
```

Copy the public key to your remote backup server:

```bash
# For Hetzner Storage Box or standard SSH servers
ssh-copy-id -i /root/.ssh/backup_key.pub -p 23 backupuser@backup.example.com
```

Test the SSH connection:

```bash
ssh -i /root/.ssh/backup_key -p 23 backupuser@backup.example.com
```

### 3. Configure PostgreSQL Password File

Create a `.pgpass` file for passwordless PostgreSQL authentication:

```bash
# Create .pgpass file in the home directory of the user running the backup
# Format: hostname:port:database:username:password
echo "127.0.0.1:5432:*:dbadmin:your_password_here" > ~/.pgpass
```

**Important**: Set correct permissions (PostgreSQL will refuse to use the file otherwise):

```bash
chmod 600 ~/.pgpass
```

Verify the format:
- `hostname`: PostgreSQL server hostname (e.g., `127.0.0.1`)
- `port`: PostgreSQL port (e.g., `5432`)
- `database`: Use `*` for all databases
- `username`: PostgreSQL username with dump privileges
- `password`: The actual password

### 4. Configure the Backup Script

Edit `pgbackup.sh` and update the configuration section at the top:

```bash
# PostgreSQL Connection
PG_HOST="127.0.0.1"              # Your PostgreSQL host
PG_PORT="5432"                   # Your PostgreSQL port
PG_USER="dbadmin"                # PostgreSQL user with backup privileges

# Local Backup Settings
LOCAL_BACKUP_DIR="/var/backups/postgres"
BACKUP_PREFIX="postgres_backup"

# Remote Server Settings
REMOTE_HOST="backup.example.com"  # Your Hetzner Storage Box or backup server
REMOTE_PORT="23"                  # SSH port (23 for Hetzner, 22 for standard)
REMOTE_USER="backupuser"          # SSH username
REMOTE_DIR="/backups/postgres"    # Remote directory path
SSH_KEY_PATH="/root/.ssh/backup_key"

# Retention Settings (in days)
RETENTION_DAYS="14"               # Keep backups for 14 days

# Logging
LOG_FILE="/var/log/postgres-backup.log"
```

### 5. Test the Script

Run the script manually to ensure everything works:

```bash
./pgbackup.sh
```

Check the log file:

```bash
tail -f /var/log/postgres-backup.log
```

### 6. Set Up Automated Backups with Cron

#### Option A: Using /etc/cron.d (Recommended for system-wide backups)

Create a cron file for automated backups:

```bash
# Create cron file
sudo nano /etc/cron.d/postgres-backup
```

Add the following content for backups every 6 hours:

```
# PostgreSQL Backup - Runs every 6 hours at minute 0
# m h dom mon dow user command
0 */6 * * * root /opt/postgres-backup/pgbackup.sh >/dev/null 2>&1
```

Alternative schedules:

```
# Every day at 2 AM
0 2 * * * root /opt/postgres-backup/pgbackup.sh >/dev/null 2>&1

# Every 12 hours (midnight and noon)
0 0,12 * * * root /opt/postgres-backup/pgbackup.sh >/dev/null 2>&1

# Every Sunday at 3 AM
0 3 * * 0 root /opt/postgres-backup/pgbackup.sh >/dev/null 2>&1
```

Set correct permissions:

```bash
sudo chmod 644 /etc/cron.d/postgres-backup
```

Verify the cron job is loaded:

```bash
sudo systemctl restart cron  # Debian/Ubuntu
# or
sudo systemctl restart crond # RHEL/CentOS
```

#### Option B: Using User Crontab

Alternatively, add to root's crontab:

```bash
sudo crontab -e
```

Add this line for backups every 6 hours:

```
0 */6 * * * /opt/postgres-backup/pgbackup.sh >/dev/null 2>&1
```

## Usage

### Manual Backup

```bash
./pgbackup.sh
```

### View Logs

```bash
# View entire log
cat /var/log/postgres-backup.log

# Follow log in real-time
tail -f /var/log/postgres-backup.log

# View recent backups
ls -lh /var/backups/postgres/
```

### Restore from Backup

To restore a backup:

```bash
# Download from remote server (if needed)
scp -P 23 -i /root/.ssh/backup_key \
  backupuser@backup.example.com:/backups/postgres/postgres_backup_2024-01-15_020000.sql.gz \
  /tmp/

# Decompress and restore
gunzip < /tmp/postgres_backup_2024-01-15_020000.sql.gz | psql -U postgres
```

## Troubleshooting

### Permission Denied for .pgpass

```bash
# Ensure correct permissions
chmod 600 ~/.pgpass
chown root:root ~/.pgpass  # If running as root
```

### SSH Connection Issues

```bash
# Test SSH connection manually
ssh -i /root/.ssh/backup_key -p 23 backupuser@backup.example.com

# Check SSH key permissions
chmod 600 /root/.ssh/backup_key
chmod 644 /root/.ssh/backup_key.pub
```

### pg_dumpall: Command Not Found

```bash
# Install PostgreSQL client tools
# Debian/Ubuntu
apt-get install postgresql-client

# RHEL/CentOS
yum install postgresql
```

### Insufficient Privileges

Ensure the PostgreSQL user has appropriate permissions:

```sql
-- Connect as postgres superuser
GRANT pg_read_all_data TO dbadmin;
ALTER USER dbadmin WITH SUPERUSER;  -- For full pg_dumpall
```

### Disk Space Issues

Monitor disk usage:

```bash
# Check local backup directory
df -h /var/backups/postgres

# Check backup sizes
du -sh /var/backups/postgres/*
```

Consider reducing `RETENTION_DAYS` or increasing available disk space.

## File Structure

```
postgres_backup_YYYY-MM-DD_HHMMSS.sql.gz
```

Each backup file includes:
- Date and time of backup
- Compressed SQL dump of all databases

## Security Considerations

- **SSH Keys**: Keep private keys secure with `chmod 600`
- **Password File**: Never commit `.pgpass` to version control
- **File Permissions**: Backup files contain sensitive data; ensure proper permissions
- **Network**: Consider using VPN or encrypted connections for transfers
- **Retention**: Balance retention period with compliance and storage requirements

## Support

For issues specific to:
- **Hetzner Storage Box**: Check [Hetzner documentation](https://docs.hetzner.com/robot/storage-box/)
- **PostgreSQL**: Check [PostgreSQL documentation](https://www.postgresql.org/docs/)

## License

MIT License - Feel free to modify and use as needed.
