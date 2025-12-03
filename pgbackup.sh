#!/bin/bash
#
# PostgreSQL Backup Script
# Dumps all databases, compresses, transfers via SCP, and manages retention
#

# ==============================================================================
# CONFIGURATION - Modify these variables for each server
# ==============================================================================

# PostgreSQL Connection
PG_HOST="127.0.0.1"
PG_PORT="5432"
PG_USER="dbadmin"

# Local Backup Settings
LOCAL_BACKUP_DIR="/var/backups/postgres"
TIMESTAMP_FORMAT="%Y-%m-%d_%H%M%S"
BACKUP_PREFIX="postgres_backup"

# Remote Server Settings
REMOTE_HOST="backup.example.com"
REMOTE_PORT="23"
REMOTE_USER="backupuser"
REMOTE_DIR="/backups/postgres"
SSH_KEY_PATH="/root/.ssh/backup_key"

# Retention Settings (in days)
RETENTION_DAYS="14"

# Logging
LOG_FILE="/var/log/postgres-backup.log"

# ==============================================================================
# DO NOT MODIFY BELOW THIS LINE
# ==============================================================================

# Generate timestamp
TIMESTAMP=$(date +"${TIMESTAMP_FORMAT}")
BACKUP_FILENAME="${BACKUP_PREFIX}_${TIMESTAMP}.sql.gz"
LOCAL_BACKUP_PATH="${LOCAL_BACKUP_DIR}/${BACKUP_FILENAME}"

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

# Error handling function
error_exit() {
    log "ERROR: $1"
    exit 1
}

# ==============================================================================
# MAIN SCRIPT
# ==============================================================================

log "=== Starting PostgreSQL backup process ==="
log "Backup file: ${BACKUP_FILENAME}"

# Check if local backup directory exists, create if not
if [ ! -d "${LOCAL_BACKUP_DIR}" ]; then
    log "Creating local backup directory: ${LOCAL_BACKUP_DIR}"
    mkdir -p "${LOCAL_BACKUP_DIR}" || error_exit "Failed to create local backup directory"
fi

# Check if log directory exists, create if not
LOG_DIR=$(dirname "${LOG_FILE}")
if [ ! -d "${LOG_DIR}" ]; then
    mkdir -p "${LOG_DIR}" || error_exit "Failed to create log directory"
fi

# Step 1: Run pg_dumpall and compress
log "Step 1: Running pg_dumpall and compressing..."
PGPASSFILE="${HOME}/.pgpass" pg_dumpall -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" | gzip > "${LOCAL_BACKUP_PATH}"
PIPE_STATUS=("${PIPESTATUS[@]}")

if [ ${PIPE_STATUS[0]} -ne 0 ]; then
    error_exit "pg_dumpall failed"
fi

if [ ${PIPE_STATUS[1]} -ne 0 ]; then
    error_exit "gzip compression failed"
fi

if [ ! -f "${LOCAL_BACKUP_PATH}" ]; then
    error_exit "Backup file was not created"
fi

BACKUP_SIZE=$(du -h "${LOCAL_BACKUP_PATH}" | cut -f1)
log "Backup created successfully (${BACKUP_SIZE})"

# Step 2: Ensure remote directory exists
log "Step 2: Ensuring remote directory exists..."
ssh -p "${REMOTE_PORT}" -i "${SSH_KEY_PATH}" "${REMOTE_USER}@${REMOTE_HOST}" \
    "mkdir -p ${REMOTE_DIR}" 2>&1 | tee -a "${LOG_FILE}"

if [ $? -ne 0 ]; then
    error_exit "Failed to create remote directory"
fi

log "Remote directory confirmed"

# Step 3: Transfer to remote server via SCP
log "Step 3: Transferring backup to remote server..."
scp -P "${REMOTE_PORT}" -i "${SSH_KEY_PATH}" "${LOCAL_BACKUP_PATH}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/" >> "${LOG_FILE}" 2>&1

if [ $? -ne 0 ]; then
    error_exit "SCP transfer failed"
fi

log "Transfer completed successfully"

# Step 4: Clean up old local backups
log "Step 4: Cleaning up local backups older than ${RETENTION_DAYS} days..."
DELETED_LOCAL=$(find "${LOCAL_BACKUP_DIR}" -name "${BACKUP_PREFIX}_*.sql.gz" -type f -mtime +${RETENTION_DAYS} -print -delete 2>&1 | tee -a "${LOG_FILE}" | wc -l)
log "Deleted ${DELETED_LOCAL} old local backup(s)"

# Step 5: Clean up old remote backups
log "Step 5: Cleaning up remote backups older than ${RETENTION_DAYS} days..."

# Get list of remote files and their timestamps, then delete old ones locally via multiple SSH commands
# Calculate cutoff timestamp (seconds since epoch)
CUTOFF_TIMESTAMP=$(date -d "${RETENTION_DAYS} days ago" +%s 2>/dev/null || date -v-${RETENTION_DAYS}d +%s 2>/dev/null)

if [ -z "${CUTOFF_TIMESTAMP}" ]; then
    log "WARNING: Could not calculate cutoff date for remote cleanup"
else
    # Get file list from remote and process locally
    REMOTE_FILES=$(ssh -p "${REMOTE_PORT}" -i "${SSH_KEY_PATH}" "${REMOTE_USER}@${REMOTE_HOST}" \
        "ls -1 ${REMOTE_DIR}/${BACKUP_PREFIX}_*.sql.gz 2>/dev/null" 2>&1)
    
    if [ $? -eq 0 ] && [ -n "${REMOTE_FILES}" ]; then
        DELETED_COUNT=0
        while IFS= read -r filepath; do
            # Extract just the filename from the full path
            filename=$(basename "${filepath}")
            
            # Get file modification time via stat
            FILE_TIMESTAMP=$(ssh -p "${REMOTE_PORT}" -i "${SSH_KEY_PATH}" "${REMOTE_USER}@${REMOTE_HOST}" \
                "stat -c %Y ${filepath} 2>/dev/null || stat -f %m ${filepath} 2>/dev/null" 2>&1)
            
            # Check if file is older than retention period
            if [ -n "${FILE_TIMESTAMP}" ] && [ "${FILE_TIMESTAMP}" -lt "${CUTOFF_TIMESTAMP}" ]; then
                ssh -p "${REMOTE_PORT}" -i "${SSH_KEY_PATH}" "${REMOTE_USER}@${REMOTE_HOST}" \
                    "rm ${filepath}" >> "${LOG_FILE}" 2>&1
                if [ $? -eq 0 ]; then
                    DELETED_COUNT=$((DELETED_COUNT + 1))
                    log "Deleted remote file: ${filename}"
                fi
            fi
        done <<< "${REMOTE_FILES}"
        log "Deleted ${DELETED_COUNT} old remote backup(s)"
    else
        log "No remote backups found or unable to list remote directory"
    fi
fi

log "=== Backup process completed successfully ==="
log ""

exit 0
