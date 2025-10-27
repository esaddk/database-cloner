# Database Cloner

A comprehensive shell script tool to clone databases with custom prefixes and create users with different privilege levels. Currently supports PostgreSQL with planned support for MySQL and MongoDB.

## Features

- **Multi-Database Support**: Extensible architecture for multiple database types
  - **PostgreSQL**: Currently implemented with full feature set
  - **MySQL**: Planned support
  - **MongoDB**: Planned support
- **Schema-based security approach**:
  - Renames default schema to owner name
  - Creates two types of users for each cloned database:
    - **App Users**: DML only (SELECT, INSERT, UPDATE, DELETE)
    - **Owner Users**: Full privileges (DDL + DML)
  - Uses role-based privilege management
- **Automatic backup before cloning** (optional)
- **Active connection checking** before operations
- **Load balancer connection testing** (optional)
- **Comprehensive logging and error handling**
- **Configurable through database-specific `.conf` files**

## Requirements

### General Requirements
- Bash shell
- Git (for cloning the repository)

### Database-Specific Requirements

#### PostgreSQL (Currently Supported)
- PostgreSQL client tools (`psql`, `createdb`, `pg_dump`)
- Superuser access to PostgreSQL server

#### MySQL (Planned)
- MySQL client tools (`mysql`, `mysqldump`)
- Superuser access to MySQL server

#### MongoDB (Planned)
- MongoDB client tools (`mongodump`, `mongorestore`, `mongo`/`mongosh`)
- Admin user access to MongoDB server

## Installation

1. Clone or download this repository
2. Copy the database-specific example configuration file:
   ```bash
   # For PostgreSQL
   cp postgresql_db_clone.conf.example postgresql_db_clone.conf

   # For MySQL (when available)
   cp mysql_db_clone.conf.example mysql_db_clone.conf

   # For MongoDB (when available)
   cp mongodb_db_clone.conf.example mongodb_db_clone.conf
   ```
3. Edit the configuration file with your database settings
4. Make the script executable:
   ```bash
   chmod +x clone_databases.sh
   ```

## Usage

### Basic Usage
```bash
./clone_databases.sh
```

### Usage with Specific Database Type
```bash
# Set database type via environment variable
DB_TYPE=postgresql ./clone_databases.sh
DB_TYPE=mysql ./clone_databases.sh      # Future support
DB_TYPE=mongodb ./clone_databases.sh    # Future support
```

The script will:
1. Detect database type from configuration or environment variable
2. Read configuration from appropriate `.conf` file
3. Test database connection
4. Clone each specified database with the prefix
5. Create users with appropriate privileges
6. Test user connections via load balancer (if configured)
7. Generate a log file with all operations
8. Create credential summary file

## Configuration

Configuration files are database-specific and follow the naming pattern: `{db_type}_db_clone.conf`

### PostgreSQL Configuration (`postgresql_db_clone.conf`)

#### Database Connection
- `PG_HOST`: PostgreSQL server host
- `PG_PORT`: PostgreSQL server port
- `PG_SUPERUSER`: Superuser username
- `PG_SUPERUSER_PASSWORD`: Superuser password

#### Load Balancer Configuration (Optional)
- `LB_HOST`: Load balancer host for connection testing (leave empty to skip)
- `LB_PORT`: Load balancer port (default: 5432)

#### Database Settings
- `DB_PREFIX`: Prefix for cloned databases (default: `preprod_`)
- `DATABASES_TO_CLONE`: Comma-separated list of databases to clone

#### User Configuration
Users are automatically created for all databases in `DATABASES_TO_CLONE`:
- Auto-generates usernames based on database name:
  - App user: `{database_name}_user`
  - Owner user: `{database_name}_owner`
  - Passwords are auto-generated (16 characters with letters and numbers)
- `APP_ROLE_PREFIX`: Prefix for app user roles (default: `r_rw_` - read-write)
- `OWNER_ROLE_PREFIX`: Prefix for owner user roles (default: `r_rc_` - read-create)

#### Additional Options
- `CREATE_BACKUP_BEFORE_CLONE`: Create backup before cloning (true/false)
- `BACKUP_DIR`: Directory for backups
- `LOG_FILE`: Custom log file name (optional)

### Future Database Configurations

#### MySQL Configuration (`mysql_db_clone.conf`) - Planned
```bash
# Database connection
MYSQL_HOST=localhost
MYSQL_PORT=3306
MYSQL_ROOT_USER=root
MYSQL_ROOT_PASSWORD=your_password

# Database prefix and cloning settings
DB_PREFIX=preprod_
DATABASES_TO_CLONE=myapp_db,analytics_db

# User settings
MYSQL_APP_USER_PREFIX=_app_user
MYSQL_OWNER_USER_PREFIX=_owner_user
```

#### MongoDB Configuration (`mongodb_db_clone.conf`) - Planned
```bash
# Database connection
MONGO_HOST=localhost
MONGO_PORT=27017
MONGO_ADMIN_USER=admin
MONGO_ADMIN_PASSWORD=your_password

# Database prefix and cloning settings
DB_PREFIX=preprod_
DATABASES_TO_CLONE=myapp,analytics

# User settings
MONGO_APP_USER_SUFFIX=_app_user
MONGO_OWNER_USER_SUFFIX=_owner_user
```

## Examples

### PostgreSQL Example

If you have a database `superapp_db` and configure:
```bash
DB_PREFIX=preprod_
DATABASES_TO_CLONE=superapp_db
LB_HOST=postgres-lb.company.com
```

The script will create:
- Database: `preprod_superapp_db` (clone of `superapp_db`)
- Schema: `superapp_db_owner` (renamed from `public`)
- Users:
  - `superapp_db_user` (app user with auto-generated password, DML privileges)
  - `superapp_db_owner` (owner user with auto-generated password, full privileges)
- Roles:
  - `r_rw_superapp_db` (app role with DML privileges - read-write)
  - `r_rc_superapp_db` (owner role with full privileges - read-create)

## Database-Specific Features

### PostgreSQL (Current Implementation)

#### Schema-Based Security Approach
The script implements a comprehensive security model:

1. **Renames public schema** to the owner user name
2. **Sets search_path** to prioritize the new schema
3. **Revokes default privileges** from public

#### User Creation
- **App User**: `{database_name}_user` (auto-generated) - DML operations only
- **Owner User**: `{database_name}_owner` (auto-generated) - Full privileges on schema
- **Auto-generated usernames and passwords** for enhanced security

#### Role-Based Privileges
- **App Role** (`r_rw_{database_name}` - read-write):
  - CONNECT on database
  - USAGE on schema
  - SELECT, INSERT, UPDATE, DELETE on all tables
  - USAGE on all sequences
  - EXECUTE on functions
  - Default privileges for future objects

- **Owner Role** (`r_rc_{database_name}` - read-create):
  - All app role privileges
  - CREATE on schema and database
  - TEMPORARY on database
  - Full DDL capabilities

#### Load Balancer Connection Testing
When `LB_HOST` is configured, the script automatically tests user connections through the load balancer to verify:
- User authentication works via load balancer
- Proper privilege assignment
- Search path configuration
- Database accessibility

### MySQL (Planned Implementation)
- Database-based user management
- Privilege separation for read/write vs admin users
- Load balancer testing support
- Logical backup/restore cloning method

### MongoDB (Planned Implementation)
- Collection-based user management
- Role-based access control (RBAC)
- Load balancer testing support
- BSON backup/restore cloning method

## Password Management

- **Auto-generated passwords** (16 characters, letters + numbers)
- **Individual password files**: `passwords_{database}_{DDMMYY}.txt`
- **Credential summary file**: `credentials_{DDMMYY}.txt` (consolidated format)
- **Secure storage**: All password files excluded from git (see .gitignore)
- **Complete connection info**: Includes usernames, passwords, and connection details

## Credential Summary File

### Overview
At the end of the cloning process, the script generates a consolidated credential summary file `credentials_{DDMMYY}.txt` with all database credentials in a clean, readable format.

### File Format
```
Database Type: PostgreSQL
Generated on: Mon Oct 27 12:00:00 UTC 2025
===============================================

database name : preprod_superapp_db
schema: superapp_db_owner
app user: superapp_db_user
password: AbC123xYz456DeF
owner user: superapp_db_owner
password: GhI789jKl012MnO
LB: postgres-lb.company.com:5432

database name : preprod_analytics_db
schema: analytics_db_owner
app user: analytics_db_user
password: PqR345sTu678VwX
owner user: analytics_db_owner
password: YzA901bCd234EfG
LB: postgres-lb.company.com:5432

===============================================
Connection Information:
Database Host: localhost
Database Port: 5432
Load Balancer: postgres-lb.company.com:5432

Note: Keep this file secure and delete after use.
===============================================
```

## Safety Features

- **Source database validation** - Confirms databases exist before cloning
- **Active connection checking** - Blocks cloning if connections are detected
- **Target database existence check** - Skips if database already exists
- **Optional backup creation** - Safety net before cloning operations
- **Comprehensive error handling** - Detailed logging and graceful failures
- **Rollback-safe operations** - Atomic operations where possible
- **DBA-friendly error messages** - Provides exact SQL commands for issue resolution

## Logging

All operations are logged to:
- Console output (with colors)
- Log file: `postgre_db_cloner_DDMMYY.log` (auto-generated with date)

## Troubleshooting

1. **Configuration file not found**: Copy the appropriate example configuration file
2. **Connection failed**: Check your database connection settings in the config file
3. **Permission denied**: Ensure your superuser has sufficient privileges
4. **Active connections detected**: Kill connections using provided SQL commands
5. **Check logs**: Review the log file for detailed error information

## File Structure

```
database-cloner/
├── clone_databases.sh              # Main script (database-agnostic)
├── postgresql_db_clone.conf.example  # PostgreSQL configuration template
├── mysql_db_clone.conf.example        # MySQL configuration template (planned)
├── mongodb_db_clone.conf.example      # MongoDB configuration template (planned)
├── .gitignore                       # Git ignore file
└── README.md                        # This documentation
```

## Development Roadmap

### Phase 1: PostgreSQL (✅ Complete)
- [x] Database cloning with TEMPLATE method
- [x] Schema-based security
- [x] User and role management
- [x] Load balancer testing
- [x] Connection checking
- [x] Credential management

### Phase 2: MySQL (📋 Planned)
- [ ] Database cloning configuration
- [ ] User privilege management
- [ ] Load balancer support
- [ ] Backup/restore integration
- [ ] Connection testing

### Phase 3: MongoDB (📋 Planned)
- [ ] Database cloning configuration
- [ ] Role-based access control
- [ ] Load balancer support
- [ ] BSON backup/restore
- [ ] Connection testing

### Phase 4: Enhancements (📋 Planned)
- [ ] Web interface for configuration
- [ ] Database migration support
- [ ] Automated scheduling
- [ ] Multi-region support
- [ ] Monitoring and alerting

## Contributing

When adding support for new database types:

1. Create new configuration file: `{db_type}_db_clone.conf.example`
2. Add database-specific validation functions
3. Implement database cloning logic
4. Add user/role management functions
5. Include load balancer testing support
6. Update documentation

## License

This project is licensed under the MIT License.

## Support

For support and questions:
1. Check the troubleshooting section
2. Review the log files for detailed error information
3. Ensure your database-specific configuration is correct
4. Verify database connectivity and permissions