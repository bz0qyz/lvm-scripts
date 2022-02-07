#!/bin/bash
# LOG_FILE=/tmp/$(basename "${0}").log

function log(){
  # Set Default values
  MSG=()
  LEVEL=0
  APPEND=0
  QUIET=0
  # Make sure to enable interpretation of backslash escapes
  ECHO_OPTS="-e"
  NEW_LOG_FILE=0
  SAVE_LOG_FILE=0
  PREFIX=""
  declare -a LEVEL_PREFIX=("info" "warning" "error")
  declare -a STR_BOOL=("False" "True")
  declare -a STR_RETVAL=("Success" "Failed" "Failed")

  ## Colored Output Variables
  NC='\033[0m' # No Color
  RED='\033[0;31m'
  GRN='\033[0;32m'
  BRN='\033[0;33m'
  BLU='\033[0;34m'
  GRY='\033[0;37m'
  YLW='\033[1;33m'
  declare -a LEVEL_COLOR=("${GRN}" "${YLW}" "${RED}")
  declare -a BOOL_COLOR=("${GRN}" "${RED}")

  function show_log_help() {
    echo -en "\n${YLW}"
    echo "USAGE: log [options] \"log message\""
    echo -e "OPTIONS:${GRY}"
    echo " -l|--level <integer> - The log level. 0=INFO 1-WARNING 2=ERROR"
    echo " -p|--prefix <string> - Set a custom log prefix. overrides -l"
    echo " -r|--retval <integer> - Specify a return value."
    echo " -f|--log-file <string> - Write log entries to a file."
    echo " -q|--quiet - Do not write logs to stdout. Without -f this is pointless"
    echo " -c|--create-new-log - Create a new log file rather than appending."
    echo " -s|--save-log - If an old log file exists, Save it before creating a new one."
    echo " -n|--no-newline - Do not terminate the log entry with a new line. Assumes that the next log will be appended (-a)"
    echo " -a|--append - Append the log entry to the previous line. No prefix is added."
    echo " -x|--exit - terminate with \`exit\` rather than \`return\`."
    echo -e "${YLW}Appending help:${GRY}"
    echo "  If you are appending a log line and supply a \`--retval\` with an empty message,"
    echo "  The message will be either \"Success\" or \"Failed\" depending on the value of \`--retval\`"
    echo "  EXAMPLE:"
    echo "  \$ test.sh && log Starting Log Service... -n; log -r 1 -a"
    echo "  [INFO] Starting Log Service...(Failed)"
    echo -en "${NC}\n"
  }

  # Process passed arguments
  while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
  		-l|--level)
        # The log level. 0=info, 1=warning, 2=error
        LEVEL="${2}"
        shift # past argument
        shift # past value
        ;;
  		-p|--prefix)
        # Set a custom log prefix. changes color to blue
        PREFIX="${2}"
        shift # past argument
        shift # past value
        ;;
      -r|--retval)
        # Specify a return value.
        RETVAL="${2}"
        shift # past argument
        shift # past value
        ;;
      -f|--file)
        # Send the log output to a file
        LOG_FILE="${2}"
        shift # past argument
        shift # past value
        ;;
      -n|--no-newline)
        # Do not terminate the log with a newline (\n)
        ECHO_OPTS="${ECHO_OPTS} -n"
        shift
        ;;
      -a|--append)
        # Append to the last log line instead of creating a new one
        # Previous line must have been sent with -n|--no-newline
  			APPEND=1
        shift
  			;;
      -q|--quiet)
        # Only send logs to a file. No output to screen
  			QUIET=1
        shift
  			;;
      -c|--create-new-log)
        # Create a new log file
  			NEW_LOG_FILE=1
        shift
  			;;
      -s|--save-log)
        # Save the old log file before creating a new one
  			SAVE_LOG_FILE=1
        shift
  			;;
  		-x|--exit)
        # Terminate with exit rather than return
  			EXIT=1
        shift
  			;;
      -h|--help)
        # Show the command help
  			show_log_help && return 0
        shift
  			;;
  		*) # unnamed parameters
  			MSG+=("$1") # save it in an array for later
  			shift # past argument
  			;;
  	esac
  done
  # Save the shell opts so we can put them back
  SHELL_OPTS=${-}
  # Create a datestamp for the log file
  DTE=$(date +%Y%m%d-%H%M%S)
  # If the log level is higher that 2(error), then set it to 2
  [[ ${LEVEL} -gt ${#LEVEL_PREFIX[@]} ]] && LEVEL=2
  # Set the log output color to the level color
  CLR="${LEVEL_COLOR[${LEVEL}]}"
  # If not specified, set the log prefix to the level prefix
  # If a custom prefix was received, make the output color blue
  [[ -n "${PREFIX}" ]] && CLR=${BLU} || PREFIX="${LEVEL_PREFIX[${LEVEL}]}"
  # Convert the prefix to uppercase
  PREFIX=$( echo ${PREFIX} | tr '[:lower:]' '[:upper:]')
  # If a custom RETVAL was not received, use the LEVEL
  [[ -z "${RETVAL}" ]] && RETVAL=${LEVEL}
  # If no message was received. Set the message to STR_RETVAL[$RETVAL]
  if [[ ${#MSG[@]} -eq 0 ]] && [[ -n ${RETVAL} ]]; then
    [[ ${RETVAL} -gt ${#STR_RETVAL[@]} ]] && MSG=("(${STR_RETVAL[2]})") || MSG=("(${STR_RETVAL[${RETVAL}]})")
    [[ ${RETVAL} -gt ${#BOOL_COLOR[@]} ]] && CLR=${BOOL_COLOR[1]} || CLR=${BOOL_COLOR[${RETVAL}]}
  fi
  # Build the message strings
  if [[ ${APPEND} -eq 0 ]]; then
    MSG_SCREEN="${CLR}[${PREFIX}] ${MSG[*]}${NC}"
    MSG_FILE="${DTE} ${MSG_SCREEN}"
  else
    # Appending to the previous message
    MSG_SCREEN="${CLR}${MSG[*]}${NC}"
    MSG_FILE="${MSG_SCREEN}"
  fi

  # Write the output log message
  [[ -n ${QUIET} ]] && echo ${ECHO_OPTS} "${MSG_SCREEN}"
  ## Log to a log file
  if [[ -n "${LOG_FILE}" ]]; then
    set +e
    if [[ -d $(dirname ${LOG_FILE}) ]] || mkdir -p $(dirname ${LOG_FILE}) >/dev/null 2>&1 ; then
      if touch "${LOG_FILE}" >/dev/null 2>&1 ; then
        [[ ${SHELL_OPTS} =~ e ]] && set -e
        # Rotate the log file if NEW_LOG_FILE and/or SAVE_LOG_FILE is set
        [[ ${SAVE_LOG_FILE} -gt 0 ]] && cp "${LOG_FILE}" "${LOG_FILE}-${DTE}.save"
        [[ ${NEW_LOG_FILE} -gt 0 ]] &&  cp -f /dev/null "${LOG_FILE}"
        # Write the log entry to the log file
        echo ${ECHO_OPTS} "${MSG_FILE}" >> "${LOG_FILE}"
      else
        [[ ${SHELL_OPTS} =~ e ]] && set -e
        log "failed to create log file: ${LOG_FILE}" -l 2
      fi
    else
      [[ ${SHELL_OPTS} =~ e ]] && set -e
      log "failed to create log file directory: ${LOG_FILE}" -l 2
    fi

  fi
  [[ ${SHELL_OPTS} =~ e ]] && set -e
  [[ ${EXIT} -eq 1 ]] && exit ${RETVAL} || return ${RETVAL}
}
