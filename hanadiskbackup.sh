#/bin/bash
#
#
[[ -f $HOME/.bashrc ]] && source $HOME/.bashrc -start "echo dummy"

declare HBS_SCRIPT_NAME="HANA Disk Backup script"
declare HBS_SCRIPT_VERSION="0.1.3-beta1"

#######################################
# Runtime script's variables
# ---
# Script PID
declare HBS_MY_PID=$$

# Script trace level
declare HBS_TRACE_LEVEL=2

# Script's exit code
declare HBS_EXIT_CODE=0

#######################################
# Script's parameters
# ---
# User key for hdbsql
declare HBS_USERKEY="KEY4BACKUP"

# HANA backup's type (c|i|d)
declare HBS_BACKUP_TYPE="c"

# Backup starting mode (0 - sync, 1 - async)
declare HBS_BACKUP_ASYNC=0

# Backup compression mode (0 - no compression, 1 - compress backup)
declare HBS_BACKUP_COMPRESSED=0

# Backup configuration files mode (0 - no configuration files in a data backup, 1 - includes configuration files in a data backup)
declare HBS_BACKUP_INCLUDECONF=0

# List of databases to backup
declare HBS_DATABASES=""

# HANA backup's file prefix, part1
declare HBS_FILE_PREFIX_PART1=""

# HANA backup's file prefix, part2
declare HBS_FILE_PREFIX_PART2=$(date +"%Y-%m-%d")

# HANA backup's path
declare HBS_BACKUP_PATH=""

# Additional HANA backup's options (if any)
declare HBS_BACKUP_OPTIONS=""

# HANA backup's comment
declare HBS_BACKUP_COMMENT=""

# Script's logfile directory
declare HBS_LOG_DIR="/var/opt/hanadiskbackup"

# Script's logfile name
declare HBS_LOG_NAME="hanadiskbackuplog_${SAPSYSTEMNAME}_$(date +"%Y-%m-%d").txt"

# Script's logfile full name
declare HBS_LOG_FULLNAME=""

# Mail notification mode:
# - 0: none
# - 1: send e-mail if error
# - 2: send e-mail anytime
declare HBS_MAIL_MODE=0

# Mail notification's sender (from)
declare HBS_MAILFROM=""

# Mail notification's recipients (to)
declare HBS_MAILTO=""

#######################################
# Script's options
# ---
# Input option value for HANA backup's type
declare OPT_BACKUP_TYPE="com"

# Input option value for databases list
declare OPT_DATABASES="%all"

# Mail notification mode
declare OPT_MAIL_MODE="0"

#######################################
# Show help information
# Globals:
#   HBS_SCRIPT_NAME, HBS_SCRIPT_VERSION
# Outputs:
#   Writes info to stdout
#######################################
showVersion() {
cat<<EOF
$HBS_SCRIPT_NAME $HBS_SCRIPT_VERSION
EOF
}

#######################################
# Show help information
# Globals:
#   HHBS_SCRIPT_DESCRIPTION
# Outputs:
#   Writes info to stdout
#######################################
showHelp() {
cat<<EOF
$HBS_SCRIPT_NAME $HBS_SCRIPT_VERSION

Usage
    hanadiskbackup.sh [OPTION...]

Description:
    TODO[mprusov]: Add desription of the script.

Examples:
    # start HANA backup for all tenant
    hanadiskbackup.sh --dbs %all

Options:
    --async, -A
        Switch to asynchronous calling of the 'BACKUP DATA...' SQL-statement.

    --backup-type <type-of-backup>
        Set session backup type.
        The default backup type is '${OPT_BACKUP_TYPE}'.

    --compressed
        Create a data backup or delta backup (differential or incremental backup)
        using native SAP HANA compression.

    --dbs <Comma-separated databases list>
        List of databases for backup.
        You can use the string '%all' for backup all of databases.
        The default value is '${OPT_DATABASES}'.

    --include-configuration
        Includes the user configuration files (changed .ini files) in a data backup.

    --mail-mode <mail mode>
        Set e-mail notification's mode.
        Possible values:
        *   0 - none, 
        *   1 - send e-mail if error
        *   2 - send e-mail anytime
        The default notification mode is 0.
        Script uses the utility sendmail for mailing.

    --mail-from <sender>
        Use <sender> for field "from" in the e-mail notification.
        Example: "HANA Disk Backup Script<nobody@nobody.com>".
        Default value: none.

    --mail-to <recipient(s)>
        Use <recipient(s)> for field "to" in the e-mail notification.
        Default value: none.

    -U <HANA User Key from secure user store>
        The default user key is '${HBS_USERKEY}'.

    --version
        Show version information and exit.

    --help
        Display this help and exit.

Authors:
    - Mikhail Prusov, mprusov@sapbasis.tech
EOF
}

#######################################
# Write log text (info, error, warning...)
# Globals:
#   HBS_MY_PID
# Arguments:
#   $1: Type of information (I, -, W, E)
#   $2: Text for writing
# Outputs:
#   Writes info to stdout/stderr
#######################################
logMessage() {
    local log_type=$1
    local my_pid=${HBS_MY_PID:-'-'}
    local timestamp=$(date '+%F %X %Z')
    local log_text=$2
    local log_message=""
    if [[ "$log_type" == "-" ]]; then
        log_message="$log_text"
    else
        log_message="$log_type $my_pid $timestamp: $log_text"
    fi
    if [[ "$log_type" == "E" || "$log_type" == "W" ]]; then
        echo "$log_message" >&2
    elif [[ "$log_type" == "I" || "$log_type" == "-" ]]; then
        echo "$log_message" >&1
    else
        echo "$log_message" >&2
    fi
    [[ ! -z "$HBS_LOG_FULLNAME" ]] && echo "$log_message" >> $HBS_LOG_FULLNAME
}

#######################################
# Log text info
# Arguments:
#   $1: Text for writing
# Outputs:
#   Writes info text to log
#######################################
logInfo() {
    logMessage 'I' "$1"
}

#######################################
# Log debug text info
# Arguments:
#   $1: Text for writing
# Outputs:
#   Writes info text to log
#######################################
debugInfo() {
    if [[ $HBS_TRACE_LEVEL > 1 ]]; then
        logMessage 'I' "$1"
    fi
}

#######################################
# Log warning text info
# Arguments:
#   $1: Text for writing
# Outputs:
#   Writes info text to log
#######################################
logWarning() {
    logMessage 'W' "$1"
}

#######################################
# Log error text info
# Arguments:
#   $1: Text for writing
# Outputs:
#   Writes info text to log
#######################################
errorInfo() {
    logMessage 'E' "$1"
}

#######################################
# Terminate the script with error info
# Arguments:
#   $1: Text for writing
#   $2: Exit code (optional)
# Outputs:
#   Writes error text to log and exit
#######################################
exitWithError() {
    HBS_EXIT_CODE=${2:-'1'}
    errorInfo "${1}. Terminating with code ${HBS_EXIT_CODE}..."
    processMailNotification
    exit $HBS_EXIT_CODE
}

#######################################
# Finish the script with info
# Arguments:
#   $1: Text for writing
# Outputs:
#   Writes info text to log and exit
#######################################
exitWithInfo() {
    logInfo "${1}"
    processMailNotification
    exit 0
}

#######################################
# Prepare logfile
# Globals:
#   HBS_LOG_DIR, HBS_LOG_NAME, HBS_LOG_FULLNAME
# Arguments:
#   $1: Type of information (I, -, W, E)
#   $2: Text for writing
# Outputs:
#   Writes info to stdout/stderr
#######################################
prepareLogFile() {
    local log_fullname="$HBS_LOG_DIR/$HBS_LOG_NAME"
    touch $log_fullname 1>/dev/null 2>&1
    if [[ $? != 0 ]]; then
        logWarning "Log file \"$log_fullname\" is not acessible. Writing into logfile will skipped."
    else
        HBS_LOG_FULLNAME=$log_fullname
        logInfo "I will write log info into logfile \"$HBS_LOG_FULLNAME\"."
    fi
}

#######################################
# Construct hdbsql calling
# ---
HDBSQL="$DIR_EXECUTABLE/hdbsql -U ${HBS_USERKEY}"
HDBSQL_BACKUP="$HDBSQL -E 1 -x -quiet -j -a"
HDBSQL_QUERY="$HDBSQL -E 1 -x -quiet -j -a -C"

# Options for hdbsql-command for "BACKUP DATA..." SQL-statement
declare HBS_HDBSQL4B_OPT="-x -quiet -j -a"

# hdbsql-command for "BACKUP DATA..." SQL-statement
declare HBS_HDBSQL4B_CMD=""

# Options for hdbsql-command for any query SQL-statement
declare HBS_HDBSQL4Q_OPT="-x -quiet -j -a -C"

# hdbsql-command for any query SQL-statement
declare HBS_HDBSQL4Q_CMD=""

# hdbsql result string
declare HBS_HDBSQL_RESULT_STRING=""

# hdbsql exit code
declare HBS_HDBSQL_EXIT_CODE=0

#######################################
# Prepare command for calling of hdbsql
# Globals:
#   HBS_HDBSQL4B_CMD, HBS_HDBSQL4B_OPT
#   HBS_HDBSQL4Q_CMD, HBS_HDBSQL4Q_OPT
#   HBS_USERKEY
# Arguments:
#   none
# Outputs:
#   none
#######################################
prepareHDBSQLCommands() {
    local SELECT_FROM_DUMMY_SQL="SELECT * FROM DUMMY"
    # Construct and validate HBS_HDBSQL4B_CMD
    HBS_HDBSQL4B_CMD="$DIR_EXECUTABLE/hdbsql -U $HBS_USERKEY $HBS_HDBSQL4B_OPT"
    execHDBSQLBackup "$SELECT_FROM_DUMMY_SQL"
    if [[ $? != 0 ]]; then
        exitWithError "Validating of the hdbsql for backup is failed"
    fi
    # Construct and validate HBS_HDBSQL4Q_CMD
    HBS_HDBSQL4Q_CMD="$DIR_EXECUTABLE/hdbsql -U $HBS_USERKEY $HBS_HDBSQL4Q_OPT"
    execHDBSQLQuery "$SELECT_FROM_DUMMY_SQL"
    if [[ $? != 0 ]]; then
        exitWithError "Validating of the hdbsql for query is failed"
    fi
}

#######################################
# Execute SQL-statement with hdbsql
# Globals:
#   HBS_HDBSQL_RESULT_STRING, HBS_HDBSQL_EXIT_CODE
# Arguments:
#   $1: command for hdbsql
#   $2: sql text to execute
#######################################
execHDBSQLCommand() {
    local hdbsql_cmd="$1"
    local sql_text="$2"
    debugInfo "Try to execute the SQL-statement via hdbsql:"
    debugInfo "  hdbsql command is: \"$hdbsql_cmd\""
    debugInfo "  sql command is: \"$sql_text\""
    HBS_HDBSQL_RESULT_STRING=$($hdbsql_cmd "$sql_text")
    HBS_HDBSQL_EXIT_CODE=$?
    if [[ $HBS_HDBSQL_EXIT_CODE != 0 ]]; then
        errorInfo "Executing of the SQL-statement is failed:"
        errorInfo "  sql command is: \"$sql_text\""
    else
        if [[ -z "$HBS_HDBSQL_RESULT_STRING" ]]; then
            debugInfo "Executing of the SQL-statement is successfully with no result string."
        else
            debugInfo "Executing of the SQL-statement is successfully with result:"
            debugInfo "  result string is: \"$HBS_HDBSQL_RESULT_STRING\""
        fi
    fi
    return $HBS_HDBSQL_EXIT_CODE
}

#######################################
# Execute backup command with hdbsql
# Globals:
#   HBS_HDBSQL_RESULT_STRING, HBS_HDBSQL_EXIT_CODE
# Arguments:
#   $1: sql text to execute
#######################################
execHDBSQLBackup() {
    execHDBSQLCommand "$HBS_HDBSQL4B_CMD" "$1"
    return $?
}

#######################################
# Execute SQL-quert with hdbsql
# Globals:
#   HBS_HDBSQL_RESULT_STRING, HBS_HDBSQL_EXIT_CODE
# Arguments:
#   $1: sql text to execute
#######################################
execHDBSQLQuery() {
    HBS_HDBSQL_RESULT_STRING=""
    execHDBSQLCommand "$HBS_HDBSQL4Q_CMD" "$1"
    return $?
}

#######################################
# Parse backup mode ^w([s|m])?:([cid-]*)$
# Globals:
#   HBS_HDBSQL_RESULT_STRING, HBS_HDBSQL_EXIT_CODE,
#   HBS_BACKUP_TYPE
# Arguments:
#   $1: sql text to execute
#######################################
parseWeeklyBackupPlan() {
    # Build full week backup plan
    local week_plan="${BASH_REMATCH[2]}-------"
    if [[ "${BASH_REMATCH[1]}" == "s" ]]; then
        week_plan="${week_plan:1:6}${week_plan:0:1}"
    else
        week_plan="${week_plan:0:7}"
    fi
    debugInfo "The week's backup (starting from monday) plan is \"$week_plan\""

    # Evalute day of week
    local day_of_week=$[$(date +%u)-1]
    debugInfo "Today's day is \"$day_of_week\""

    # Evalute HBS_BACKUP_TYPE
    # ---
    HBS_BACKUP_TYPE="${week_plan:$day_of_week:1}"
    debugInfo "Today's backup type is \"$HBS_BACKUP_TYPE\""
}

# Prepare list of all databases
# ---
prepareListBackupDatabases() {
    GET_LIST_OF_DATABASES_SQL="SELECT DATABASE_NAME FROM M_DATABASES"
    execHDBSQLQuery "$GET_LIST_OF_DATABASES_SQL"
    if [[ $? != 0 ]]; then
        exitWithError "Can't get list of databses to backup"
    fi
    HBS_DATABASES=$HBS_HDBSQL_RESULT_STRING
}

#######################################
# Construct SQL-statement 'BACKUP DATA...' 
# ---

declare HBS_BACKUP_DELTA_SQLPART
declare HBS_BACKUP_DEFINITION_SQLPART
declare HBS_BACKUP_OPTION_SQLPART
declare HBS_BACKUP_COMMENT_SQLPART
declare HBS_BACKUP_DATA_SQL

#######################################
# Prepare parts for SQL-statement 'BACKUP DATA...' 
# Globals:
#   HBS_BACKUP_TYPE,
#   HBS_FILE_PREFIX_PART1, HBS_FILE_PREFIX_PART2,
#   HBS_BACKUP_PATH, HBS_BACKUP_ASYNC, HBS_BACKUP_COMMENT
#   HBS_BACKUP_DELTA_SQLPART, HBS_BACKUP_DEFINITION_SQLPART, 
#   HBS_BACKUP_OPTION_SQLPART, HBS_BACKUP_COMMENT_SQLPART
# Arguments:
#   none
#######################################
prepareBackupDataSQLTexts() {
    # Evaluate HBS_BACKUP_DELTA_SQLPART
    declare -A delta_text='([c]="" [d]="DIFFERENTIAL" [i]="INCREMENTAL")'
    HBS_BACKUP_DELTA_SQLPART=${delta_text[$HBS_BACKUP_TYPE]}
    
    # Evaluate HBS_BACKUP_DEFINITION_SQLPART
    local backup_file_prefix_sql="$HBS_FILE_PREFIX_PART2"
    [[ ! -z "$HBS_FILE_PREFIX_PART1" ]]&& \
        backup_file_prefix_sql="${HBS_FILE_PREFIX_PART1}_$backup_file_prefix_sql"
    local backup_definition_file_sql="'$backup_file_prefix_sql'"
    [[ ! -z "$HBS_BACKUP_PATH" ]] && \
        backup_definition_file_sql="$HBS_BACKUP_PATH,'$backup_file_prefix_sql'"
    HBS_BACKUP_DEFINITION_SQLPART="USING FILE ($backup_definition_file_sql)"

    # Evaluate HBS_BACKUP_OPTION_SQLPART
    HBS_BACKUP_OPTION_SQLPART="$HBS_BACKUP_OPTIONS"
    [[ $HBS_BACKUP_ASYNC == 1 ]] && HBS_BACKUP_OPTION_SQLPART="$HBS_BACKUP_OPTION_SQLPART ASYNCHRONOUS"
    [[ $HBS_BACKUP_COMPRESSED == 1 ]] && HBS_BACKUP_OPTION_SQLPART="$HBS_BACKUP_OPTION_SQLPART COMPRESSED"
    [[ $HBS_BACKUP_INCLUDECONF == 1 ]] && HBS_BACKUP_OPTION_SQLPART="$HBS_BACKUP_OPTION_SQLPART INCLUDE CONFIGURATION"

    # Evaluate HBS_BACKUP_COMMENT_SQLPART
    [[ ! -z "$HBS_BACKUP_COMMENT" ]] && \
        HBS_BACKUP_COMMENT_SQLPART="COMMENT '$HBS_BACKUP_COMMENT'"
}

#######################################
# Prepare SQL-statement 'BACKUP DATA...' 
# Globals:
#   HBS_BACKUP_DATA_SQL
#   HBS_BACKUP_DELTA_SQLPART, HBS_BACKUP_DEFINITION_SQLPART, 
#   HBS_BACKUP_OPTION_SQLPART, HBS_BACKUP_COMMENT_SQLPART
# Arguments:
#   $1: Database Name
#######################################
prepareBackupDataSQL() {
    HBS_BACKUP_DATA_SQL="BACKUP DATA"
    [[ ! -z "$HBS_BACKUP_DELTA_SQLPART" ]] && \
        HBS_BACKUP_DATA_SQL="$HBS_BACKUP_DATA_SQL $HBS_BACKUP_DELTA_SQLPART"
    HBS_BACKUP_DATA_SQL="$HBS_BACKUP_DATA_SQL FOR $1 $HBS_BACKUP_DEFINITION_SQLPART"
    [[ ! -z "$HBS_BACKUP_OPTION_SQLPART" ]] && \
        HBS_BACKUP_DATA_SQL="$HBS_BACKUP_DATA_SQL $HBS_BACKUP_OPTION_SQLPART"
    [[ ! -z "$HBS_BACKUP_COMMENT_SQLPART" ]] && \
        HBS_BACKUP_DATA_SQL="$HBS_BACKUP_DATA_SQL $HBS_BACKUP_COMMENT_SQLPART"
}

#######################################
# Prepare mail notification engine 
# Globals:
#   OPT_MAIL_MODE, 
#   HBS_MAIL_MODE, HBS_MAILFROM, HBS_MAILTO
# Arguments:
#   none
#######################################
prepareMailMode() {
    HBS_MAIL_MODE=0
    [[ ! "$OPT_MAIL_MODE" =~ (^[012]$) ]] && \
        exitWithError "Unknown mail notification mode \"$OPT_MAIL_MODE\""
    
    HBS_MAIL_MODE=$OPT_MAIL_MODE
    [[ $HBS_MAIL_MODE -eq 0 ]] && return

    [[ -z "$HBS_MAILFROM" ]] && \
        exitWithError "The e-mail sender is not specified. Use the option \"mail-from\""

    [[ -z "$HBS_MAILTO" ]] && \
        exitWithError "The e-mail recipient(s) is not specified. Use the option \"mail-to\""
}

#######################################
# Process mail notofocation
# Globals:
#   HBS_MAIL_MODE, HBS_MAILFROM, HBS_MAILTO
#   HBS_LOG_DIR, HBS_LOG_NAME
# Arguments:
#   none
#######################################
processMailNotification() {
    [[ $HBS_MAIL_MODE -eq 0 || $HBS_MAIL_MODE -eq 1 && HBS_EXIT_CODE -eq 0 ]] && return

    # Prepare mail file
    # ---
    local log_fullname="$HBS_LOG_DIR/$HBS_LOG_NAME"
    local mail_fullname="$HBS_LOG_DIR/$HBS_LOG_NAME.eml"
    local mail_subject=""
    local mail_text=""

    if [[ HBS_EXIT_CODE -eq 0 ]]; then
        mail_subject="HANA Disk Backup Script finished successfully [$(date +"%Y-%m-%d %T")]"
        mail_text="HANA Disk Backup Script finished successfully.
Log file $log_fullname is attached."
    else
        mail_subject="HANA Disk Backup Script failed [$(date +"%Y-%m-%d %T")]"
        mail_text="HANA Disk Backup Script finished with error ($HBS_EXIT_CODE).
Log file $log_fullname is attached."
    fi

cat>$mail_fullname<<EOF
From: $HBS_MAILFROM
To: $HBS_MAILTO
Subject: $mail_subject
Mime-Version: 1.0
Content-Type: multipart/mixed; boundary="28011973"

--28011973
Content-Type: text/plain; charset="US-ASCII"
Content-Transfer-Encoding: 7bit
Content-Disposition: inline

$mail_text

--28011973
Content-Type: application;
Content-Transfer-Encoding: base64
Content-Disposition: attachment; filename="$HBS_LOG_NAME"

$(base64 $log_fullname)

--28011973
EOF

    # Send mail file
    # ---
    /usr/sbin/sendmail -t < $mail_fullname
}

#######################################
#### Main
##

# Parse command line options
# ---
getopt --test &>/dev/null
if [[ $? -ne 4 ]]; then
    exitWithError "Getopt is too old" -2
fi

OPTS_SHORT="U:,A"
OPTS_LONG="async,compressed,backup-type:,dbs:,include-conf,mail-mode:,mail-from:,mail-to:,version,help"
OPTS=$(getopt -s bash -o '' --options $OPTS_SHORT --longoptions $OPTS_LONG -n "$0" -- "$@")
if [[ $? -ne 0 ]] ; then
    exitWithError "Failed parsing options" -2
fi
eval set -- "$OPTS"

while true; do
  case "$1" in
    -U)
        HBS_USERKEY=$2
        shift 2
        ;;
    --async|-A)
        HBS_BACKUP_ASYNC=1
        shift 1
        ;;
    --compressed)
        HBS_BACKUP_COMPRESSED=1
        shift 1
        ;;
    --backup-type)
        OPT_BACKUP_TYPE=$(echo $2 | tr '[:upper:]' '[:lower:]')
        shift 2
        ;;
    --dbs)
        OPT_DATABASES=$2
        shift 2
        ;;
    --include-conf)
        HBS_BACKUP_INCLUDECONF=1
        shift 1
        ;;
    --mail-mode)
        OPT_MAIL_MODE=$2
        shift 2
        ;;
    --mail-from)
        HBS_MAILFROM=$2
        shift 2
        ;;
    --mail-to)
        HBS_MAILTO=$2
        shift 2
        ;;
    --version)
        showVersion
        exit 0
        ;;
    --help)
        showHelp
        exit 0
        ;;
    --)
        shift
        break
        ;;
  esac
done

# Prepare logging mechanism
# ---
prepareLogFile

# Start working
# ---
logInfo "$HBS_SCRIPT_NAME ($HBS_SCRIPT_VERSION) started"

# Prepare mail mode
prepareMailMode

# Prepare commands for calling hdbsql
# ---
prepareHDBSQLCommands

# Parse option value OPT_BACKUP_TYPE
# ---
if [[ "$OPT_BACKUP_TYPE" =~ ^w([s|m])?:([cid-]*)$ ]]; then
    parseWeeklyBackupPlan
    [[ -z "$HBS_FILE_PREFIX_PART1" ]] && HBS_FILE_PREFIX_PART1="WEEKLY"
    [[ -z "$HBS_BACKUP_COMMENT" ]] && HBS_BACKUP_COMMENT="Weekly backup copy with hanadiskbackup script"
else
    case $OPT_BACKUP_TYPE in
        c|com|d|dif|i|inc|-)
            HBS_BACKUP_TYPE=${OPT_BACKUP_TYPE:0:1}
            ;;
        *)
            exitWithError "Specified backup type '${OPT_BACKUP_TYPE}' is unknown. You can use next backup types: com, dif, inc..."
            ;;
    esac
    [[ -z "$HBS_FILE_PREFIX_PART1" ]] && HBS_FILE_PREFIX_PART1="ONETIME"
    [[ -z "$HBS_BACKUP_COMMENT" ]] && HBS_BACKUP_COMMENT="One-time backup copy with hanadiskbackup script"
fi

# Check HBS_BACKUP_TYPE for skipping mode
# ---
if [[ "$HBS_BACKUP_TYPE" == "-" ]]; then
    exitWithInfo "Backup type is none. $HBS_SCRIPT_NAME finished without actually performing backup."
fi

# Parse option value OPT_DATABASES
# ---
if [[  "$OPT_DATABASES" == "%all" ]]; then
    prepareListBackupDatabases
else
    HBS_DATABASES=$(echo $OPT_DATABASES | tr ',' ' ')
fi

# Prepare parts of SQL-statement 'BACKUP DATA'
prepareBackupDataSQLTexts

# Launch backups for selected HANA databases
# ---
declare HBS_DATABASE=""
for HBS_DATABASE in $HBS_DATABASES; do
    logInfo "Try to start the backup of the database \"$HBS_DATABASE\"..."
    prepareBackupDataSQL $HBS_DATABASE
    execHDBSQLBackup "$HBS_BACKUP_DATA_SQL"
    if [[ $? != 0 ]]; then
        exitWithError "Starting the backup of the database \"$HBS_DATABASE\" is failed"
    fi
    logInfo "Starting the backup of the database \"$HBS_DATABASE\" done successfully"
done

# Finish work
# ---
exitWithInfo "$HBS_SCRIPT_NAME finished successfully"
