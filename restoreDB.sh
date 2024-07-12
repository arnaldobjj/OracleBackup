################################################################################
# Script      : restoreDB.sh
# Objective   : Oracle database restore from AWS S3
# Used By     : oracle
# Call        : sh /opt/restoreDB/restoreDB.sh <key option>
#
# Version  Date        Author        Comments
# -------  --------    ------------  ------------------------------------------
# 1.0      20240222    adasilva      Initial version
################################################################################

# How to create a secure password file
# master_password="xxxxxxxxxxxxxxxx"
# real_password="xxxxxxxxxxxxxxxx"
# encrypted_password=$(echo "$real_password" | openssl enc -aes-256-cbc -a -salt -pbkdf2 -pass pass:"$master_password")
# echo "$encrypted_password" > encrypted.safe
# cat encrypted.safe

# Environment Variables
export ORACLE_HOME="/fortvale/app/oracle/product/19.3.0/db_1"
export GRID_HOME="/fortvale/app/grid/product/19.3.0/grid"
export SQL="$ORACLE_HOME/bin/sqlplus"
DEBUG=1 # debug flag (1 = ON / 0 = OFF)
BODYMSG="" # Mail message
MASTERKEY="yourmasterpasswordhere"  # Define the master password
CTEE="/usr/bin/tee -a"
WORK_DIR="/opt/restoreDB"
LOG="$WORK_DIR/log/restoreDB.log"
HTMLFILE=$WORK_DIR/log/restoreDB.html
LOG_LAST_EXEC_TIME="$WORK_DIR/log/lastExecTime.log"
RMAN=$ORACLE_HOME/bin/rman

#==============================================================#
# Procedures / Functions                                       #
#==============================================================#
# Function to check if the JOB is already running
# @return {string} Job  - Return the job running
check_job_running ()
{
  jobRunning=0;
  v_jobid=$0;
  jobRunning=`ps -ef | grep -v grep | grep -v $v_jobid | grep -c JOB  `
  if [ $jobRunning -gt 0 ]; then
    v_my_pid=$$
    v_pid_running=`ps -ef | grep -v grep | grep -i JOB | awk '{print $2}' | head -1`
    log "v_my_pid: $v_my_pid"
    log "v_pid_running: $v_pid_running"
    if [ $v_my_pid -ne $v_pid_running ]; then
      log "Script $0 is running. Please check before start new job."
      exit 1
    fi
  fi
}

# Function to check if the directories are ok
check_directories ()
{
  if [ ! -d $WORK_DIR/log ]; then
    mkdir -p $WORK_DIR/log
  fi

  # Cleaning the script log file before running
  if [ -f $LOG ]; then
    > $LOG
  fi

  # Cleaning the script log file before running
  if [ -f $HTMLFILE ]; then
    > $HTMLFILE
  fi
}

# Function to check the current user
check_user ()
{
  ### Determine the user which is executing this script.
  CURRUSR=`id |cut -d"(" -f2 | cut -d ")" -f1`
  if [ "$CURRUSR" != "oracle" ]; then
    echo "$CURRUSR is not allowed to run, just as oracle user. Contact the Administrator."
    exit 1
  fi
}


# Function to log messages
log_message() {
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] $1" >> "$LOG"
  echo "$1"
}

# Function to retrieve the last execution time for a specific database from the log file
get_last_exec_time() {
  local db_name="$1"
  grep "^$db_name," "$LOG_LAST_EXEC_TIME" | tail -n 1 | cut -d ',' -f 2
}

# Function to log the last execution time for a database
log_last_exec_time() {
  local db_name="$1"
  local exec_time="$2"
  # Check if the database entry already exists in the log file
  if grep -q "^$db_name," "$LOG_LAST_EXEC_TIME"; then
    # Remove the existing entry for the database
    sed -i "/^$db_name,/d" "$LOG_LAST_EXEC_TIME"
  fi
  # Append the new entry to the log file
  echo "$db_name,$exec_time" >> "$LOG_LAST_EXEC_TIME"
}

# Check if log last execution file exists, if not create a new one empty.
if [ ! -s "$LOG_LAST_EXEC_TIME" ]; then
  touch $LOG_LAST_EXEC_TIME
fi

# Removing the log file
rm -f $LOG

# Define the options
# Use your DBName and DBIds here
options=(
    "EARTH    1111111111"
    "MARS     2222222222"
    "VENUS    3333333333"
    "JUPITER  4444444444"
    "SATURN   5555555555"
    "MARCURY  6666666666"
)

# Print the options with the last execution time
log_message "Key  DB Name  DB Id         Last Exec Time"
log_message "---- -------  ------------  --------------"
for i in "${!options[@]}"; do
    db_info=(${options[$i]})
    db_name="${db_info[0]}"
    db_id="${db_info[1]}"
    last_exec_time="$(get_last_exec_time "$db_name")"
    printf "%-4s %-8s %-13s %s\n" "$((i+1))" "${db_info[0]}" "${db_info[1]}" "$last_exec_time"
done

# Ask for user input
read -p "Enter the key of the item to be restored: " key

# Validate user input
if [[ ! $key =~ ^[0-9]+$ ]]; then
  log_message "[Error] Please enter a valid key."
  exit 1
fi

# Check if the key is within range
if (( key < 1 || key > ${#options[@]} )); then
  log_message "[Error] Key out of range."
  exit 1
fi

# Retrieve the selected option
selected_option="${options[$((key-1))]}"

# Separate DB Name and DB ID
DBNAME=$(echo "$selected_option" | awk '{print $1}')
DBID=$(echo "$selected_option" | awk '{print $2}')

# Confirm with the user before proceeding
log_message "You selected: $DBNAME with DB ID: $DBID"
read -p "Do you want to continue with restoration? (Y/N): " confirm
log_message "You selected: $confirm"

# Convert the input to uppercase
confirm=$(echo "$confirm" | tr '[:lower:]' '[:upper:]')

# Check the user`s confirmation
if [ "$confirm" != "Y" ]; then
  log_message "[Info] Restoration process aborted."
  exit 0
fi

# Perform the restoration process
c_begin_time_sec=$(date +%s)
log_message "[Info] Performing restoration process [Database: $DBNAME - DBID: $DBID]"

# Initial checks
if check_job_running && check_directories && check_user; then
    log_message "[Info] Initial checks"
else
    log_message "[Error] Initial checks"
fi

# Read the encrypted password from the file
encrypted_password=$(cat $WORK_DIR/.sec/.encrypted.safe)

# Decrypt the password using openssl
PASSW=$(echo "$encrypted_password" | openssl enc -d -aes-256-cbc -a -salt -pass pass:"$MASTERKEY" -pbkdf2)

# Read the encrypted password from the file
encrypted_password=$(cat $WORK_DIR/.sec/.backup.safe)

# Decrypt the password using openssl
BACKUP_PASSW=$(echo "$encrypted_password" | openssl enc -d -aes-256-cbc -a -salt -pass pass:"$MASTERKEY" -pbkdf2)

# Check if $PASSW is not empty
if [ -n "$PASSW" ]; then
  log_message "[Info] Decrypted RMAN password."
else
  log_message "[Error] Decrypted RMAN password."
  exit 8;
fi

# Check if $BACKUP_PASSW is not empty
if [ -n "$BACKUP_PASSW" ]; then
  log_message "[Info] Decrypted backup password."
else
  log_message "[Error] Decrypted backup password."
  exit 8;
fi

# Stopping all the databases before start the removing
DB_LIST=$(ps -ef | grep -v grep | grep ora_pmon | awk '{print $8}' | cut -d'_' -f3-)

# Iterate over each value in DB_LIST
for db_name in $DB_LIST; do
  log_message "[Info] Stopping the database: $db_name"
  export ORACLE_SID=$db_name
  DBCONN="sys/$PASSW as sysdba"
  returnDB=$("$SQL" -s $DBCONN << EOF
    shutdown abort;
    exit;
EOF
)
  returnDB=$(echo "$returnDB" | xargs)
  if [ "$returnDB" = "ORACLE instance shut down." ]; then
    log_message "[Info] Database $db_name has been shut down."
  else
    log_message "[Error] Database $db_name is not DOWN, please check the alert log file."
    exit 8
  fi
done

# Error handling for removing database files from ASM

# Checking before remove
asm_data=$(sudo -u grid -E env ORACLE_SID=+ASM ORACLE_HOME="$GRID_HOME" "$GRID_HOME/bin/asmcmd" ls -l +DATA/C* 2>/dev/null | wc -l)
if [ $asm_data -gt 0 ]; then
  # Removing data from +DATA diskgroup
  sudo -u grid -E env ORACLE_SID=+ASM ORACLE_HOME="$GRID_HOME" "$GRID_HOME/bin/asmcmd" rm -rf +DATA/C*
  if [ $? -gt 0 ]; then
    log_message "[Error] Removing database files from the ASM (+DATA diskgroup)."
    exit 8
  else
    log_message "[Info] Database files from the ASM (+DATA diskgroup) have been removed."
  fi
fi

# Checking before remove
asm_fra=$(sudo -u grid -E env ORACLE_SID=+ASM ORACLE_HOME="$GRID_HOME" "$GRID_HOME/bin/asmcmd" ls -l +FRA/C* 2>/dev/null | wc -l)
if [ $asm_fra -gt 0 ]; then
  # Removing data from +FRA diskgroup
  sudo -u grid -E env ORACLE_SID=+ASM ORACLE_HOME="$GRID_HOME" "$GRID_HOME/bin/asmcmd" rm -rf +FRA/C*
  if [ $? -gt 0 ]; then
    log_message "[Error] Removing database files from the ASM (+FRA diskgroup)."
    exit 8
  else
    log_message "[Info] Database files from the ASM (+FRA diskgroup) have been removed."
  fi
fi

dbname=$(echo "$DBNAME" | tr '[:upper:]' '[:lower:]')
# Removing directories
log_message "[Info] Removing directories"
rm -rf /fortvale/app/oracle/diag/rdbms/*
rm -rf /fortvale/app/oracle/admin/*

#*/ Removing init files
log_message "[Info] Removing init files."
rm -f $ORACLE_HOME/dbs/initC*.ora
rm -f $ORACLE_HOME/dbs/spfileC*.ora
rm -f $ORACLE_HOME/dbs/lkC*
rm -f $ORACLE_HOME/dbs/hc_C*.dat
rm -f $ORACLE_HOME/dbs/track_*.ora

if [ -e "$ORACLE_HOME/spfile$DBNAME.ora" ]; then
  log_message "[Error] File $ORACLE_HOME/spfile$DBNAME.ora exists."
  exit 8
else
  log_message "[Info] File $ORACLE_HOME/spfile$DBNAME.ora has been removed."
fi

# Creating directories
log_message "[Info] Creating directories."
mkdir -p /fortvale/app/oracle/diag/rdbms/$dbname/$DBNAME/cdump
mkdir -p /fortvale/app/oracle/diag/rdbms/$dbname/$DBNAME/trace
mkdir -p /fortvale/app/oracle/admin/$DBNAME/adump

# Loading the variables to RMAN connection
export ORACLE_SID="$DBNAME"
TARGETSTR="/"
REPOSSTR=\"RMAN_${DBNAME}/${PASSW}@FVERMAN\"

#" RMAN restore starting...
log_message "[Info] Initiating RMAN restore. This operation may take a while."
{
$RMAN target $TARGETSTR catalog $REPOSSTR << EOF
set echo on
startup nomount force
SET DECRYPTION IDENTIFIED BY $BACKUP_PASSW;
set dbid=$DBID;
run {
allocate channel ch1 type sbt
PARMS='SBT_LIBRARY=/fortvale/app/oracle/product/19.3.0/db_1/lib/libosbws.so,SBT_PARMS=(OSB_WS_PFILE=/fortvale/app/oracle/product/19.3.0/db_1/dbs/osbws_conf/osbws_cflashdb.ora)';
RESTORE SPFILE TO "/$ORACLE_HOME/dbs/spfile$DBNAME.ora";
shutdown abort
startup nomount
RESTORE CONTROLFILE;
ALTER DATABASE MOUNT;
RESTORE DATABASE;
SWITCH DATAFILE ALL;
RECOVER DATABASE;
release channel ch1;
}
alter database open resetlogs;
exit;
EOF
} >> $LOG 2>&1 &

# Display "." while waiting for the process to finish
while kill -0 $! 2>/dev/null; do
  printf "."
  sleep 10
done

# Add a new line after the dots
printf "\n"
log_message " "

log_message "[Info] RMAN restore has been completed."

# RMAN cleaning up expired archives...
log_message "[Info] Initiating RMAN clean up."
{
$RMAN target $TARGETSTR catalog $REPOSSTR << EOF
set echo on
crosscheck archivelog all;
delete noprompt expired archivelog all;
exit;
EOF
} >> $LOG 2>&1

log_message "[Info] RMAN clean up has been completed."

# Remove the new incarnation from the RMAN catalog
DBCONN="rman_$DBNAME/$PASSW@FVERMAN"
removeORPHAN=$("$SQL" -s $DBCONN << EOF
        set heading off
        set feedback off
        set pages 0
        DELETE FROM rman_$DBNAME.dbinc WHERE DBINC_STATUS = 'ORPHAN';
        commit;
        exit;
EOF
)

checkORPHAN=$("$SQL" -s $DBCONN << EOF
        set heading off
        set feedback off
        set pages 0
        select count(*) from rman_$DBNAME.dbinc WHERE DBINC_STATUS = 'ORPHAN';
        exit;
EOF
)
if [ $checkORPHAN -gt 0 ]; then
  log_message "[Warn] The new incarnation was not removed from the RMAN catalog."
else
  log_message "[Info] The new incarnation has been removed from the RMAN catalog."
fi

# Checking the database
log_message "[Info] Checking the database"
export ORACLE_SID=$DBNAME
DBCONN="system/$PASSW"
statusDB='NOK'
statusDB=$("$SQL" -s $DBCONN << EOF
        set heading off
        set feedback off
        set pages 0
        select open_mode from v\$database;
        exit;
EOF
)
statusDB=$(echo "$statusDB" | xargs)
if [ "$statusDB" = "READ WRITE" ]; then
  log_message "[Info] Database $DBNAME status [$statusDB]."
else
  log_message "[Error] Database $DBNAME is not UP, please check the log file."
  exit 8
fi

# Set variable end of the process time
c_end_time_sec=$(date +%s)
log_message "[Info] Execution Log: $LOG."

# Calculate total execution time in seconds
v_total_exec_sec=$(expr ${c_end_time_sec} - ${c_begin_time_sec})

# Convert total execution time to hh:mm:ss format
v_total_exec_h=$(printf "%02d" $((v_total_exec_sec / 3600)))
v_total_exec_m=$(printf "%02d" $(((v_total_exec_sec / 60) % 60)))
v_total_exec_s=$(printf "%02d" $((v_total_exec_sec % 60)))

# Log the execution time in human-readable format
log_message "[Info] Script execution time: ${v_total_exec_h}:${v_total_exec_m}:${v_total_exec_s}"

# Updating the log with last execution time
log_last_exec_time "$DBNAME" "${v_total_exec_h}:${v_total_exec_m}:${v_total_exec_s}"

log_message "[OK] The database $DBNAME was sucessfully restored."

exit 0

###################################################################
# End of script
###################################################################
