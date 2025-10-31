#!/bin/bash

# Database Cloner Script
# ====================
# Multi-database cloning tool with support for PostgreSQL, MySQL, and MongoDB
# Currently implements PostgreSQL with planned support for additional databases

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_TYPE="${DB_TYPE:-postgresql}"  # Can be: postgresql, mysql, mongodb
CONFIG_FILE="${SCRIPT_DIR}/${DB_TYPE}_db_clone.conf"
LOG_FILE=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
    else
        echo -e "${timestamp} [${level}] ${message}"
    fi
}

log_info() {
    log "INFO" "${BLUE}$*${NC}"
}

log_success() {
    log "SUCCESS" "${GREEN}$*${NC}"
}

log_warning() {
    log "WARNING" "${YELLOW}$*${NC}"
}

log_error() {
    log "ERROR" "${RED}$*${NC}"
}

# Function to read configuration file
read_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi

    log_info "Reading configuration from: $CONFIG_FILE"

    # Source the configuration file
    source "$CONFIG_FILE"

    # Set log file with date format if specified in config
    if [[ -n "${LOG_FILE:-}" ]]; then
        LOG_FILE="$SCRIPT_DIR/$LOG_FILE"
    else
        local date_suffix=$(date +%d%m%y)
        LOG_FILE="$SCRIPT_DIR/${DB_TYPE}_db_cloner_$date_suffix.log"
    fi

    # Create log file directory if it doesn't exist
    mkdir -p "$(dirname "$LOG_FILE")"

    # Database-specific configuration validation
    if [[ "$DB_TYPE" == "postgresql" ]]; then
        # PostgreSQL required variables
        local required_vars=("PG_HOST" "PG_PORT" "PG_SUPERUSER" "DB_PREFIX" "DATABASES_TO_CLONE")
        for var in "${required_vars[@]}"; do
            if [[ -z "${!var:-}" ]]; then
                log_error "Required configuration variable not set: $var"
                exit 1
            fi
        done

        # Set default values for optional PostgreSQL variables
        APP_ROLE_PREFIX="${APP_ROLE_PREFIX:-r_rw_}"
        OWNER_ROLE_PREFIX="${OWNER_ROLE_PREFIX:-r_rc_}"
        SOURCE_SCHEMA_NAME="${SOURCE_SCHEMA_NAME:-public}"

    elif [[ "$DB_TYPE" == "mongodb" ]]; then
        # Hybrid approach: primary node for dump/restore, connection string for user testing
        local required_vars=("MONGO_PRIMARY_HOST" "MONGO_PRIMARY_PORT" "MONGO_ADMIN_USER" "DB_PREFIX" "DATABASES_TO_CLONE")
        for var in "${required_vars[@]}"; do
            if [[ -z "${!var:-}" ]]; then
                log_error "Required configuration variable not set: $var"
                exit 1
            fi
        done

        # Set default values for optional MongoDB variables
        MONGO_AUTH_DATABASE="${MONGO_AUTH_DATABASE:-admin}"
        MONGO_APP_USER_SUFFIX="${MONGO_APP_USER_SUFFIX:-_app_user}"
        TEST_USER_CONNECTIONS="${TEST_USER_CONNECTIONS:-true}"

        # Prompt for MongoDB admin password
        if [[ -z "${MONGO_ADMIN_PASSWORD:-}" ]]; then
            MONGO_ADMIN_PASSWORD=$(prompt_password "Enter MongoDB admin password for user '$MONGO_ADMIN_USER'")
        fi

        # Build primary node connection string for dump/restore operations
        MONGO_PRIMARY_URI="mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASSWORD}@${MONGO_PRIMARY_HOST}:${MONGO_PRIMARY_PORT}/${MONGO_AUTH_DATABASE}"

        # Log masked connection string for debugging
        local masked_uri="mongodb://${MONGO_ADMIN_USER}:****@${MONGO_PRIMARY_HOST}:${MONGO_PRIMARY_PORT}/${MONGO_AUTH_DATABASE}"
        log_info "MongoDB connection URI: $masked_uri"
        log_info "MongoDB configuration loaded - Primary node: ${MONGO_PRIMARY_HOST}:${MONGO_PRIMARY_PORT}"
        if [[ -n "${MONGO_USER_CONNSTRING_TEMPLATE:-}" ]]; then
            log_info "User connection string template configured for testing"
        else
            log_info "User connection testing will use primary node"
        fi

    else
        log_error "Unsupported database type: $DB_TYPE"
        exit 1
    fi

    log_success "Configuration loaded successfully"
}

# Function to test database connection
test_connection() {
    log_info "Testing database connection..."

    if [[ "$DB_TYPE" == "postgresql" ]]; then
        if PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
            log_success "PostgreSQL connection successful"
            return 0
        else
            log_error "Failed to connect to PostgreSQL"
            log_error "Please check your connection settings in $CONFIG_FILE"
            exit 1
        fi

    elif [[ "$DB_TYPE" == "mongodb" ]]; then
        # Try different MongoDB clients and connection methods
        log_info "Testing MongoDB connection with primary node..."

        # Try mongosh first (modern MongoDB client)
        if command -v mongosh >/dev/null 2>&1; then
            log_info "Using mongosh client"
            local masked_uri="mongodb://${MONGO_ADMIN_USER}:****@${MONGO_PRIMARY_HOST}:${MONGO_PRIMARY_PORT}/${MONGO_AUTH_DATABASE}"
            local test_cmd="mongosh --uri=\"$masked_uri\" --eval \"db.runCommand({ping: 1})\""
            log_info "Testing connection command: $test_cmd"
            local error_output=$(mongosh --uri="$MONGO_PRIMARY_URI" --eval "db.runCommand({ping: 1})" 2>&1)
            if [[ $? -eq 0 ]]; then
                log_success "MongoDB primary node connection successful"
                return 0
            else
                log_error "Connection test with mongosh failed"
                log_error "Error output: $error_output"
            fi
        # Fallback to mongo client (legacy)
        elif command -v mongo >/dev/null 2>&1; then
            log_info "Using legacy mongo client"
            local masked_uri="mongodb://${MONGO_ADMIN_USER}:****@${MONGO_PRIMARY_HOST}:${MONGO_PRIMARY_PORT}/${MONGO_AUTH_DATABASE}"
            local test_cmd="mongo \"$masked_uri\" --eval \"db.runCommand({ping: 1})\""
            log_info "Testing connection command: $test_cmd"
            local error_output=$(mongo "$MONGO_PRIMARY_URI" --eval "db.runCommand({ping: 1})" 2>&1)
            if [[ $? -eq 0 ]]; then
                log_success "MongoDB primary node connection successful"
                return 0
            else
                log_error "Connection test with mongo client failed"
                log_error "Error output: $error_output"
            fi
        else
            log_error "Neither mongosh nor mongo client found in PATH"
        fi

        log_error "Failed to connect to MongoDB primary node"
        log_error "Please check your primary node settings in $CONFIG_FILE"
        exit 1
    fi
}

# Function to create backup directory
create_backup_dir() {
    if [[ "${CREATE_BACKUP_BEFORE_CLONE:-false}" == "true" ]]; then
        BACKUP_DIR="${BACKUP_DIR:-./backups}"
        BACKUP_DIR="$SCRIPT_DIR/$BACKUP_DIR"
        mkdir -p "$BACKUP_DIR"
        log_info "Backup directory created: $BACKUP_DIR"
    fi
}

# Function to backup database
backup_database() {
    local source_db=$1
    local backup_file="$BACKUP_DIR/${source_db}_$(date +%Y%m%d_%H%M%S).sql"

    log_info "Creating backup of database: $source_db"

    if PGPASSWORD="$PG_SUPERUSER_PASSWORD" pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        --no-owner --no-privileges --verbose "$source_db" > "$backup_file" 2>> "$LOG_FILE"; then
        log_success "Backup created: $backup_file"
        return 0
    else
        log_error "Failed to create backup of database: $source_db"
        return 1
    fi
}

# Function to clone database
clone_database() {
    local source_db=$1
    local target_db="${DB_PREFIX}${source_db}"

    log_info "Cloning database: $source_db -> $target_db"

    # Check if target database already exists
    if PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$target_db'" | grep -q 1; then
        log_warning "Target database $target_db already exists, skipping..."
        return 0
    fi

    # Create backup if configured
    if [[ "${CREATE_BACKUP_BEFORE_CLONE:-false}" == "true" ]]; then
        if ! backup_database "$source_db"; then
            log_error "Backup failed, aborting clone for $source_db"
            return 1
        fi
    fi

    # Clone the database
    log_info "Creating database: $target_db"

    # Create new database using TEMPLATE
    if PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d postgres -c "CREATE DATABASE \"$target_db\" TEMPLATE \"$source_db\";" 2>> "$LOG_FILE"; then
        log_success "Database cloned successfully: $target_db"
        return 0
    else
        log_error "Failed to clone database: $source_db -> $target_db"
        return 1
    fi
}

# Function to generate random password
generate_password() {
    local length=${1:-16}
    # Generate password with letters and numbers
    local password=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c $length)
    echo "$password"
}

# Function to prompt for password
prompt_password() {
    local prompt_text="$1"
    local password

    while true; do
        read -s -p "$prompt_text: " password
        echo

        if [[ -z "$password" ]]; then
            echo -e "${RED}Error: Password cannot be empty${NC}" >&2
            continue
        fi

        read -s -p "Confirm password: " password_confirm
        echo

        if [[ "$password" != "$password_confirm" ]]; then
            echo -e "${RED}Error: Passwords do not match${NC}" >&2
            continue
        fi

        break
    done

    echo "$password"
}

# Function to create users with schema-based approach
create_users() {
    local target_db=$1

    log_info "Creating users and schema for database: $target_db"

    # Extract base database name (remove prefix if exists)
    local base_db_name="$target_db"
    if [[ "$target_db" == "$DB_PREFIX"* ]]; then
        base_db_name="${target_db#$DB_PREFIX}"
    fi

    # Generate usernames automatically
    local owner_user_name="${DB_PREFIX}${base_db_name}_user_owner"
    local app_user_name="${DB_PREFIX}${base_db_name}_user"

    # Generate passwords automatically
    local password_owner=$(generate_password 16)
    local password_app_user=$(generate_password 16)

    log_info "Processing user configuration for database: $target_db"
    log_info "Owner user: $owner_user_name, App user: $app_user_name"

    # Define role names
    local app_role_name="${APP_ROLE_PREFIX}${DB_PREFIX}${base_db_name}"
    local owner_role_name="${OWNER_ROLE_PREFIX}${DB_PREFIX}${base_db_name}"

    # Step 1: Rename source schema to owner_user_name
    log_info "Step 1: Renaming schema '$SOURCE_SCHEMA_NAME' to $owner_user_name"
    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "ALTER SCHEMA \"$SOURCE_SCHEMA_NAME\" RENAME TO $owner_user_name;" 2>> "$LOG_FILE"

    # Step 2: Set search_path to include both schemas
    log_info "Step 2: Setting search_path to $owner_user_name, $SOURCE_SCHEMA_NAME"
    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "ALTER DATABASE $target_db SET search_path TO $owner_user_name, $SOURCE_SCHEMA_NAME;" 2>> "$LOG_FILE"

    # Step 3: Create users
    log_info "Step 3: Creating users"
    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d postgres -c "CREATE USER $app_user_name WITH PASSWORD '$password_app_user';" 2>> "$LOG_FILE"

    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d postgres -c "CREATE USER $owner_user_name WITH PASSWORD '$password_owner';" 2>> "$LOG_FILE"

    # Step 4: Grant database connection to owner user
    log_info "Step 4: Granting database connection to owner user"
    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "GRANT CONNECT ON DATABASE $target_db TO $owner_user_name;" 2>> "$LOG_FILE"

    # Step 5: Revoke default privileges from $SOURCE_SCHEMA_NAME
    log_info "Step 5: Revoking default privileges from $SOURCE_SCHEMA_NAME"
    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "REVOKE ALL ON DATABASE $target_db FROM $SOURCE_SCHEMA_NAME;" 2>> "$LOG_FILE"

    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "REVOKE CREATE ON SCHEMA $owner_user_name FROM $SOURCE_SCHEMA_NAME;" 2>> "$LOG_FILE"

    # Step 6: Create and configure app role
    log_info "Step 6: Creating and configuring app role: $app_role_name"
    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "CREATE ROLE $app_role_name;" 2>> "$LOG_FILE"

    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "GRANT CONNECT ON DATABASE $target_db TO $app_role_name;" 2>> "$LOG_FILE"

    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "GRANT USAGE ON SCHEMA $owner_user_name TO $app_role_name;" 2>> "$LOG_FILE"

    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA $owner_user_name TO $app_role_name;" 2>> "$LOG_FILE"

    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "ALTER DEFAULT PRIVILEGES FOR ROLE $owner_user_name GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO $app_role_name;" 2>> "$LOG_FILE"

    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "GRANT USAGE ON ALL SEQUENCES IN SCHEMA $owner_user_name TO $app_role_name;" 2>> "$LOG_FILE"

    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "ALTER DEFAULT PRIVILEGES FOR ROLE $owner_user_name GRANT USAGE, SELECT ON SEQUENCES TO $app_role_name;" 2>> "$LOG_FILE"

    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "ALTER DEFAULT PRIVILEGES FOR ROLE $owner_user_name GRANT EXECUTE ON FUNCTIONS TO $app_role_name;" 2>> "$LOG_FILE"

    # Step 7: Create and configure owner role
    log_info "Step 7: Creating and configuring owner role: $owner_role_name"
    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "CREATE ROLE $owner_role_name;" 2>> "$LOG_FILE"

    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "GRANT CONNECT ON DATABASE $target_db TO $owner_role_name;" 2>> "$LOG_FILE"

    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "GRANT USAGE, CREATE ON SCHEMA $owner_user_name TO $owner_role_name;" 2>> "$LOG_FILE"

    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA $owner_user_name TO $owner_role_name;" 2>> "$LOG_FILE"

    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "GRANT USAGE ON ALL SEQUENCES IN SCHEMA $owner_user_name TO $owner_role_name;" 2>> "$LOG_FILE"

    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "GRANT TEMPORARY ON DATABASE $target_db TO $owner_role_name;" 2>> "$LOG_FILE"

    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "GRANT CREATE ON DATABASE $target_db TO $owner_role_name;" 2>> "$LOG_FILE"

    # Step 8: Grant roles to users
    log_info "Step 8: Granting roles to users"
    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d postgres -c "GRANT $app_role_name TO $app_user_name;" 2>> "$LOG_FILE"

    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d postgres -c "GRANT $owner_role_name TO $owner_user_name;" 2>> "$LOG_FILE"

    # Step 9: Change table and sequence ownership to match new schema owner
    log_info "Step 9: Updating table and sequence ownership to $owner_user_name"

    # Change ownership of all tables in the schema
    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "DO \$\$
        DECLARE
            r RECORD;
        BEGIN
            FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = '$owner_user_name' LOOP
                EXECUTE 'ALTER TABLE ' || quote_ident('$owner_user_name') || '.' || quote_ident(r.tablename) || ' OWNER TO $owner_user_name;';
            END LOOP;
        END \$\$;" 2>> "$LOG_FILE"

    # Change ownership of all sequences in the schema
    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "DO \$\$
        DECLARE
            r RECORD;
        BEGIN
            FOR r IN SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema = '$owner_user_name' LOOP
                EXECUTE 'ALTER SEQUENCE ' || quote_ident('$owner_user_name') || '.' || quote_ident(r.sequence_name) || ' OWNER TO $owner_user_name;';
            END LOOP;
        END \$\$;" 2>> "$LOG_FILE"

    # Change ownership of all views in the schema
    PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d "$target_db" -c "DO \$\$
        DECLARE
            r RECORD;
        BEGIN
            FOR r IN SELECT table_name FROM information_schema.views WHERE table_schema = '$owner_user_name' LOOP
                EXECUTE 'ALTER VIEW ' || quote_ident('$owner_user_name') || '.' || quote_ident(r.table_name) || ' OWNER TO $owner_user_name;';
            END LOOP;
        END \$\$;" 2>> "$LOG_FILE"

    log_success "User configuration completed for database: $target_db"
    log_info "Created users: $app_user_name (app), $owner_user_name (owner)"
    log_info "Created roles: $app_role_name (app), $owner_role_name (owner)"

    # Save passwords to a file
    local password_file="$SCRIPT_DIR/passwords_${target_db}_$(date +%d%m%y).txt"
    echo "PostgreSQL Database Cloning - Generated Passwords" > "$password_file"
    echo "Generated on: $(date)" >> "$password_file"
    echo "Database: $target_db" >> "$password_file"
    echo "===============================================" >> "$password_file"
    echo "" >> "$password_file"
    echo "App User (DML only):" >> "$password_file"
    echo "Username: $app_user_name" >> "$password_file"
    echo "Password: $password_app_user" >> "$password_file"
    echo "" >> "$password_file"
    echo "Schema Owner (DDL + DML):" >> "$password_file"
    echo "Username: $owner_user_name" >> "$password_file"
    echo "Password: $password_owner" >> "$password_file"
    echo "" >> "$password_file"
    echo "Connection Details:" >> "$password_file"
    echo "Host: $PG_HOST" >> "$password_file"
    echo "Port: $PG_PORT" >> "$password_file"
    echo "Database: $target_db" >> "$password_file"
    echo "" >> "$password_file"
    echo "Roles assigned:" >> "$password_file"
    echo "- $app_user_name -> $app_role_name" >> "$password_file"
    echo "- $owner_user_name -> $owner_role_name" >> "$password_file"

    log_success "Passwords saved to: $password_file"

    # Test user connections via load balancer
    test_user_connections "$target_db" "$base_db_name" "$password_app_user" "$password_owner"

    # Store credentials for summary file
    echo "$target_db:$owner_user_name:$password_owner:$app_user_name:$password_app_user" >> "$SCRIPT_DIR/.credentials_temp"
}

# Function to test user connections via load balancer
test_user_connections() {
    local target_db=$1
    local base_db_name="$2"
    local app_user_password="$3"
    local owner_user_password="$4"

    # Extract base database name (remove prefix if exists)
    if [[ "$target_db" == "$DB_PREFIX"* ]]; then
        base_db_name="${target_db#$DB_PREFIX}"
    fi

    local app_user_name="${DB_PREFIX}${base_db_name}_user"
    local owner_user_name="${DB_PREFIX}${base_db_name}_user_owner"

    # Skip testing if LB_HOST is not configured
    if [[ -z "${LB_HOST:-}" ]]; then
        log_info "Load balancer not configured. Skipping user connection testing."
        return 0
    fi

    log_info "Testing user connections via load balancer: $LB_HOST:$LB_PORT"

    # Test app user connection
    log_info "Testing app user connection: $app_user_name"
    if PGPASSWORD="$app_user_password" psql -h "$LB_HOST" -p "$LB_PORT" -U "$app_user_name" \
        -d "$target_db" -c "SELECT 1 as test_connection;" >/dev/null 2>> "$LOG_FILE"; then
        log_success "App user $app_user_name can connect via load balancer"

        # Test app user DML privileges
        log_info "Testing app user DML privileges"
        if PGPASSWORD="$app_user_password" psql -h "$LB_HOST" -p "$LB_PORT" -U "$app_user_name" \
            -d "$target_db" -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = '$owner_user_name';" >/dev/null 2>> "$LOG_FILE"; then
            log_success "App user $app_user_name has DML access to schema $owner_user_name"
        else
            log_warning "App user $app_user_name DML test failed - check privileges"
        fi
    else
        log_error "App user $app_user_name cannot connect via load balancer"
        return 1
    fi

    # Test owner user connection
    log_info "Testing owner user connection: $owner_user_name"
    if PGPASSWORD="$owner_user_password" psql -h "$LB_HOST" -p "$LB_PORT" -U "$owner_user_name" \
        -d "$target_db" -c "SELECT 1 as test_connection;" >/dev/null 2>> "$LOG_FILE"; then
        log_success "Owner user $owner_user_name can connect via load balancer"

        # Test owner user DDL privileges
        log_info "Testing owner user DDL privileges"
        if PGPASSWORD="$owner_user_password" psql -h "$LB_HOST" -p "$LB_PORT" -U "$owner_user_name" \
            -d "$target_db" -c "SELECT count(*) FROM information_schema.schemata WHERE schema_name = '$owner_user_name';" >/dev/null 2>> "$LOG_FILE"; then
            log_success "Owner user $owner_user_name has DDL access to schema $owner_user_name"
        else
            log_warning "Owner user $owner_user_name DDL test failed - check privileges"
        fi
    else
        log_error "Owner user $owner_user_name cannot connect via load balancer"
        return 1
    fi

    # Test search_path functionality
    log_info "Testing search_path functionality"
    if PGPASSWORD="$app_user_password" psql -h "$LB_HOST" -p "$LB_PORT" -U "$app_user_name" \
        -d "$target_db" -c "SHOW search_path;" >/dev/null 2>> "$LOG_FILE"; then
        log_success "Search path is correctly configured for $app_user_name"
    else
        log_warning "Search path test failed for $app_user_name"
    fi

    log_success "All user connection tests completed for database: $target_db"
    return 0
}

# Function to create credential summary file
create_credential_summary() {
    local temp_file="$SCRIPT_DIR/.credentials_temp"
    local summary_file="$SCRIPT_DIR/credentials_$(date +%d%m%y).txt"

    if [[ ! -f "$temp_file" ]]; then
        log_info "No credentials found to create summary file."
        return 0
    fi

    log_info "Creating credential summary file: $summary_file"

    # Create summary file header
    {
        echo "PostgreSQL Database Cloning - Credential Summary"
        echo "Generated on: $(date)"
        echo "==============================================="
        echo ""
    } > "$summary_file"

    # Process each database credentials
    while IFS=':' read -r target_db owner_user owner_password app_user app_password; do
        {
            echo "database name : $target_db"
            echo "schema: $owner_user"
            echo "app user: $app_user"
            echo "password: $app_password"
            echo "owner user: $owner_user"
            echo "password: $owner_password"
            if [[ -n "${LB_HOST:-}" ]]; then
                echo "LB: $LB_HOST:$LB_PORT"
            else
                echo "LB: Not configured"
            fi
            echo ""
        } >> "$summary_file"
    done < "$temp_file"

    # Add connection information footer
    {
        echo "==============================================="
        echo "Connection Information:"
        echo "Database Host: $PG_HOST"
        echo "Database Port: $PG_PORT"
        if [[ -n "${LB_HOST:-}" ]]; then
            echo "Load Balancer: $LB_HOST:$LB_PORT"
        fi
        echo ""
        echo "Note: Keep this file secure and delete after use."
        echo "==============================================="
    } >> "$summary_file"

    # Clean up temp file
    rm -f "$temp_file"

    log_success "Credential summary created: $summary_file"
}

# Function to validate source database exists
validate_source_database() {
    local db_name=$1

    if PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$db_name'" | grep -q 1; then
        return 0
    else
        log_error "Source database does not exist: $db_name"
        return 1
    fi
}

# Function to check for active connections
check_database_connections() {
    local db_name=$1
    local target_db="${DB_PREFIX}${db_name}"

    log_info "Checking for active connections on databases: $db_name and $target_db"

    # Check connections on source database
    local source_connections=$(PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d postgres -t -c "SELECT count(*) FROM pg_stat_activity WHERE datname = '$db_name' AND state != 'idle';" 2>/dev/null | tr -d ' ')

    # Check connections on target database (if it exists)
    local target_connections=0
    if PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
        -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$target_db'" | grep -q 1 2>/dev/null; then
        target_connections=$(PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
            -d postgres -t -c "SELECT count(*) FROM pg_stat_activity WHERE datname = '$target_db' AND state != 'idle';" 2>/dev/null | tr -d ' ')
    fi

    local total_connections=$((source_connections + target_connections))

    if [[ $total_connections -gt 0 ]]; then
        log_error "Active connections detected on databases!"
        log_error "Source database '$db_name': $source_connections active connection(s)"
        if [[ $target_connections -gt 0 ]]; then
            log_error "Target database '$target_db': $target_connections active connection(s)"
        fi

        echo ""
        log_error "DATABASE CLONING CANNOT PROCEED!"
        echo ""
        log_info "Please ask your DBA to kill all active connections using the following commands:"
        echo ""

        # Show command to kill connections on source database
        if [[ $source_connections -gt 0 ]]; then
            echo -e "${YELLOW}Source database '$db_name' connections:${NC}"
            echo "1. View active connections:"
            echo "   SELECT pid, usename, application_name, state, query_start"
            echo "   FROM pg_stat_activity"
            echo "   WHERE datname = '$db_name' AND state != 'idle';"
            echo ""
            echo "2. Kill connections (run as superuser):"
            echo "   SELECT pg_terminate_backend(pid)"
            echo "   FROM pg_stat_activity"
            echo "   WHERE datname = '$db_name' AND state != 'idle'"
            echo "   AND pid != pg_backend_pid();"
            echo ""
        fi

        # Show command to kill connections on target database
        if [[ $target_connections -gt 0 ]]; then
            echo -e "${YELLOW}Target database '$target_db' connections:${NC}"
            echo "1. View active connections:"
            echo "   SELECT pid, usename, application_name, state, query_start"
            echo "   FROM pg_stat_activity"
            echo "   WHERE datname = '$target_db' AND state != 'idle';"
            echo ""
            echo "2. Kill connections (run as superuser):"
            echo "   SELECT pg_terminate_backend(pid)"
            echo "   FROM pg_stat_activity"
            echo "   WHERE datname = '$target_db' AND state != 'idle'"
            echo "   AND pid != pg_backend_pid();"
            echo ""
        fi

        echo -e "${BLUE}Alternative single command to kill all connections:${NC}"
        echo "SELECT pg_terminate_backend(pid)"
        echo "FROM pg_stat_activity"
        echo "WHERE datname IN ('$db_name'"
        if [[ $target_connections -gt 0 ]]; then
            echo "                 , '$target_db'"
        fi
        echo "  ) AND state != 'idle'"
        echo "  AND pid != pg_backend_pid();"
        echo ""

        log_info "After killing connections, please wait 30 seconds and run this script again."

        return 1
    else
        log_success "No active connections found on databases: $db_name and $target_db"
        return 0
    fi
}

# ============================================================================
# MONGODB-SPECIFIC FUNCTIONS
# ============================================================================

# Function to validate source MongoDB database exists
validate_mongo_database() {
    local db_name=$1

    log_info "Checking if database '$db_name' exists..."

    local check_result=""

    # Try mongosh first (modern MongoDB client)
    if command -v mongosh >/dev/null 2>&1; then
        log_info "Using mongosh client for database validation"
        log_info "Database check command: mongosh --uri=\"mongodb://****:****@****:****/****\" --eval \"use $db_name; db.runCommand({listCollections: 1, limit: 1})\""
        check_result=$(mongosh --uri="$MONGO_PRIMARY_URI" --eval "use $db_name; db.runCommand({listCollections: 1, limit: 1})" 2>>"$LOG_FILE")
    # Fallback to mongo client (legacy)
    elif command -v mongo >/dev/null 2>&1; then
        log_info "Using legacy mongo client for database validation"
        log_info "Database check command: mongo \"mongodb://****:****@****:****/****\" --eval \"use $db_name; db.runCommand({listCollections: 1, limit: 1})\""
        check_result=$(mongo "$MONGO_PRIMARY_URI" --eval "use $db_name; db.runCommand({listCollections: 1, limit: 1})" 2>>"$LOG_FILE")
    else
        log_error "Neither mongosh nor mongo client found in PATH"
        return 1
    fi

    log_info "Database check result: $check_result"

    if echo "$check_result" | grep -q "ok.*1" 2>/dev/null; then
        log_info "Database '$db_name' exists and is accessible"
        return 0
    else
        log_error "Source MongoDB database does not exist or is not accessible: $db_name"
        return 1
    fi
}

# Function to backup MongoDB database
backup_mongo_database() {
    local source_db=$1
    local backup_file="$BACKUP_DIR/${source_db}_$(date +%Y%m%d_%H%M%S)"

    log_info "Creating backup of MongoDB database: $source_db using primary node"

    if mongodump --uri="$MONGO_PRIMARY_URI" --db="$source_db" --out="$backup_file" 2>> "$LOG_FILE"; then
        log_success "MongoDB backup created: $backup_file"
        return 0
    else
        log_error "Failed to create backup of MongoDB database: $source_db"
        return 1
    fi
}

# Function to clone MongoDB database
clone_mongo_database() {
    local source_db=$1
    local target_db="${DB_PREFIX}${source_db}"

    log_info "Cloning MongoDB database: $source_db -> $target_db using primary node"

    # Check if target database already exists
    if mongosh --uri="$MONGO_PRIMARY_URI" --eval "db.getSiblingDB('$target_db').runCommand({ping: 1})" 2>>"$LOG_FILE" | grep -q "ok" 2>/dev/null; then
        log_warning "Target MongoDB database $target_db already exists, skipping..."
        return 0
    fi

    # Create backup if configured
    if [[ "${CREATE_BACKUP_BEFORE_CLONE:-false}" == "true" ]]; then
        if ! backup_mongo_database "$source_db"; then
            log_error "Backup failed, aborting clone for $source_db"
            return 1
        fi
    fi

    # Create temporary directory for the dump
    local temp_dump_dir=$(mktemp -d)
    trap "rm -rf $temp_dump_dir" EXIT

    # Dump the source database
    log_info "Dumping source database: $source_db from primary node"
    if ! mongodump --uri="$MONGO_PRIMARY_URI" --db="$source_db" --out="$temp_dump_dir" 2>> "$LOG_FILE"; then
        log_error "Failed to dump source database: $source_db"
        return 1
    fi

    # Restore to new database with namespace transformation
    log_info "Restoring to target database: $target_db to primary node"
    if mongorestore --uri="$MONGO_PRIMARY_URI" --nsFrom="${source_db}.*" --nsTo="${target_db}.*" \
        --drop "$temp_dump_dir/${source_db}" 2>> "$LOG_FILE"; then
        log_success "MongoDB database cloned successfully: $target_db"
        return 0
    else
        log_error "Failed to clone MongoDB database: $source_db -> $target_db"
        return 1
    fi
}

# Function to create MongoDB users and roles
create_mongo_users() {
    local target_db=$1

    log_info "Creating app user for MongoDB database: $target_db"

    # Extract base database name (remove prefix if exists)
    local base_db_name="$target_db"
    if [[ "$target_db" == "$DB_PREFIX"* ]]; then
        base_db_name="${target_db#$DB_PREFIX}"
    fi

    # Generate app username and password
    local app_user_name="${base_db_name}${MONGO_APP_USER_SUFFIX}"
    local password_app_user=$(generate_password 16)

    log_info "Processing user configuration for database: $target_db"
    log_info "App user: $app_user_name"

    # Create app user with readWrite role
    log_info "Creating app user with readWrite privileges on primary node"
    mongosh --uri="$MONGO_PRIMARY_URI" --eval "
        db = db.getSiblingDB('$target_db');
        db.createUser({
            user: '$app_user_name',
            pwd: '$password_app_user',
            roles: [{ role: 'readWrite', db: '$target_db' }]
        });
    " 2>> "$LOG_FILE"

    log_success "User configuration completed for MongoDB database: $target_db"
    log_info "Created app user: $app_user_name (readWrite)"

    # Save passwords to a file
    local password_file="$SCRIPT_DIR/passwords_${target_db}_$(date +%d%m%y).txt"
    echo "MongoDB Database Cloning - Generated Passwords" > "$password_file"
    echo "Generated on: $(date)" >> "$password_file"
    echo "Database: $target_db" >> "$password_file"
    echo "===============================================" >> "$password_file"
    echo "" >> "$password_file"
    echo "App User (Read/Write):" >> "$password_file"
    echo "Username: $app_user_name" >> "$password_file"
    echo "Password: $password_app_user" >> "$password_file"
    echo "" >> "$password_file"
    echo "Connection String Template:" >> "$password_file"
    echo "mongodb://<<USERNAME>>:<<PASSWORD>>@<<HOSTS>>/$target_db?<<OPTIONS>>" >> "$password_file"
    echo "" >> "$password_file"
    echo "Role assigned:" >> "$password_file"
    echo "- $app_user_name -> readWrite" >> "$password_file"

    log_success "Passwords saved to: $password_file"

    # Test user connections if configured
    if [[ "${TEST_USER_CONNECTIONS:-true}" == "true" ]]; then
        test_mongo_app_user_connection "$target_db" "$base_db_name" "$password_app_user"
    else
        log_info "User connection testing skipped (TEST_USER_CONNECTIONS=false)"
    fi

    # Store credentials for summary file
    echo "$target_db:$app_user_name:$password_app_user" >> "$SCRIPT_DIR/.credentials_temp"
}

# Function to test MongoDB app user connection using connection string template or primary node
test_mongo_app_user_connection() {
    local target_db=$1
    local base_db_name="$2"
    local app_user_password="$3"

    # Extract base database name (remove prefix if exists)
    if [[ "$target_db" == "$DB_PREFIX"* ]]; then
        base_db_name="${target_db#$DB_PREFIX}"
    fi

    local app_user_name="${base_db_name}${MONGO_APP_USER_SUFFIX}"

    # Check if connection string template is configured, otherwise use primary node
    if [[ -n "${MONGO_USER_CONNSTRING_TEMPLATE:-}" ]]; then
        log_info "Testing MongoDB app user connection using connection string template"

        # Build user connection string from template
        local app_connstring=$(echo "$MONGO_USER_CONNSTRING_TEMPLATE" | sed "s/<<USERNAME>>/$app_user_name/g" | sed "s/<<PASSWORD>>/$app_user_password/g" | sed "s/<<DB_NAME>>/$target_db/g")
        local connection_method="connection string"
    else
        log_info "Testing MongoDB app user connection using primary node"

        # Build connection string for primary node
        local app_connstring="mongodb://${app_user_name}:${app_user_password}@${MONGO_PRIMARY_HOST}:${MONGO_PRIMARY_PORT}/${target_db}"
        local connection_method="primary node"
    fi

    # Test app user connection
    log_info "Testing app user connection: $app_user_name using $connection_method"
    if mongosh --uri="$app_connstring" --eval "db.runCommand({ping: 1})" >/dev/null 2>> "$LOG_FILE"; then
        log_success "App user $app_user_name can connect using $connection_method"

        # Test app user read privileges
        log_info "Testing app user read privileges"
        if mongosh --uri="$app_connstring" --eval "db.getCollectionNames()" >/dev/null 2>> "$LOG_FILE"; then
            log_success "App user $app_user_name has read access to database $target_db"
        else
            log_warning "App user $app_user_name read test failed - check privileges"
        fi

        # Test app user write privileges
        log_info "Testing app user write privileges"
        if mongosh --uri="$app_connstring" --eval "
            db = db.getSiblingDB('$target_db');
            db.test_collection.insertOne({test: 1});
            db.test_collection.deleteOne({test: 1});
        " >/dev/null 2>> "$LOG_FILE"; then
            log_success "App user $app_user_name has write access to database $target_db"
        else
            log_warning "App user $app_user_name write test failed - check privileges"
        fi
    else
        log_error "App user $app_user_name cannot connect using $connection_method"
        return 1
    fi

    log_success "MongoDB app user connection tests completed for database: $target_db"
    return 0
}

# Function to create MongoDB credential summary file
create_mongo_credential_summary() {
    local temp_file="$SCRIPT_DIR/.credentials_temp"
    local summary_file="$SCRIPT_DIR/credentials_$(date +%d%m%y).txt"

    if [[ ! -f "$temp_file" ]]; then
        log_info "No MongoDB credentials found to create summary file."
        return 0
    fi

    log_info "Creating MongoDB credential summary file: $summary_file"

    # Create summary file header
    {
        echo "MongoDB Database Cloning - Credential Summary"
        echo "Generated on: $(date)"
        echo "==============================================="
        echo ""
    } > "$summary_file"

    # Process each database credentials (now only app user)
    while IFS=':' read -r target_db app_user app_password; do
        {
            echo "database name : $target_db"
            echo "app user: $app_user"
            echo "password: $app_password"
            if [[ -n "${MONGO_USER_CONNSTRING_TEMPLATE:-}" ]]; then
                echo "connection method: replica set connection string"
            else
                echo "connection method: primary node"
            fi
            echo ""
        } >> "$summary_file"
    done < "$temp_file"

    # Add connection information footer
    {
        echo "==============================================="
        echo "Connection Information:"
        echo "Primary Node: ${MONGO_PRIMARY_HOST}:${MONGO_PRIMARY_PORT}"
        if [[ -n "${MONGO_USER_CONNSTRING_TEMPLATE:-}" ]]; then
            echo ""
            echo "User Connection String Template:"
            echo "$MONGO_USER_CONNSTRING_TEMPLATE"
        fi
        echo ""
        echo "Note: Keep this file secure and delete after use."
        echo "==============================================="
    } >> "$summary_file"

    # Clean up temp file
    rm -f "$temp_file"

    log_success "MongoDB credential summary created: $summary_file"
}

# Main execution function
main() {
    log_info "Starting database cloning process for $DB_TYPE"
    log_info "Script directory: $SCRIPT_DIR"

    # Clean up any existing temp credentials file
    rm -f "$SCRIPT_DIR/.credentials_temp"

    # Read configuration
    read_config

    # Test connection
    test_connection

    # Create backup directory
    create_backup_dir

    # Process each database
    IFS=',' read -ra DATABASES <<< "$DATABASES_TO_CLONE"
    local success_count=0
    local total_count=${#DATABASES[@]}

    for source_db in "${DATABASES[@]}"; do
        source_db=$(echo "$source_db" | xargs)  # Trim whitespace

        log_info "Processing database: $source_db"

        if [[ "$DB_TYPE" == "postgresql" ]]; then
            # PostgreSQL-specific processing
            # Validate source database exists
            if ! validate_source_database "$source_db"; then
                log_warning "Skipping database: $source_db (does not exist)"
                continue
            fi

            # Check for active connections on both source and target databases
            if ! check_database_connections "$source_db"; then
                log_error "Skipping database: $source_db (active connections detected)"
                continue
            fi

            # Clone database
            if clone_database "$source_db"; then
                local target_db="${DB_PREFIX}${source_db}"

                # Create users and schema for the cloned database
                create_users "$target_db"

                ((success_count++))
                log_success "Successfully processed database: $source_db"
            else
                log_error "Failed to process database: $source_db"
            fi

        elif [[ "$DB_TYPE" == "mongodb" ]]; then
            # MongoDB-specific processing
            # Validate source database exists
            if ! validate_mongo_database "$source_db"; then
                log_warning "Skipping database: $source_db (does not exist)"
                continue
            fi

            # Clone database
            if clone_mongo_database "$source_db"; then
                local target_db="${DB_PREFIX}${source_db}"

                # Create users for the cloned database
                create_mongo_users "$target_db"

                ((success_count++))
                log_success "Successfully processed database: $source_db"
            else
                log_error "Failed to process database: $source_db"
            fi
        fi

        echo "----------------------------------------"
    done

    # Create credential summary file
    if [[ "$DB_TYPE" == "postgresql" ]]; then
        create_credential_summary
    elif [[ "$DB_TYPE" == "mongodb" ]]; then
        create_mongo_credential_summary
    fi

    # Summary
    log_info "Cloning process completed"
    log_info "Successfully processed: $success_count/$total_count databases"

    if [[ $success_count -eq $total_count ]]; then
        log_success "All databases cloned successfully!"
        exit 0
    else
        log_warning "Some databases failed to clone. Check the log for details: $LOG_FILE"
        exit 1
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Check if configuration file exists
    if [[ ! -f "$CONFIG_FILE" ]]; then
        example_config="${SCRIPT_DIR}/${DB_TYPE}_db_clone.conf.example"
        echo -e "${RED}Error: Configuration file not found: $CONFIG_FILE${NC}"
        echo -e "${YELLOW}Please copy the example configuration file and modify it:${NC}"
        echo -e "${BLUE}cp ${DB_TYPE}_db_clone.conf.example ${DB_TYPE}_db_clone.conf${NC}"
        exit 1
    fi

    main "$@"
fi