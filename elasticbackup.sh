#!/bin/bash

##
# [Elasticbackup agent]
# @author orykami <88.jacquot.benoit@gmail.com>
##

# Hostname
HOST=${HOSTNAME}
# Elasticbackup agent configuration path
CONFIG_PATH="/etc/elasticbackup.conf"
# Logger arguments
LOG_ARGS="-s -t elasticbackup"
# Path to `jq` command on your system
JQ="$(which jq)"
# Path to `curl` command on your system
CURL="$(which curl)"
# Elasticsearch cluster URL (with port if required)
ES_URL="http://localhost:9200"
# Name of the repository used to create backup on ES
ES_REPO_NAME="backup"
# Repository type (supported : fs)
ES_REPO_TYPE="fs"
# Repository settings as json object
ES_REPO_SETTINGS_JSON=""
# Maximum snapshot to preserve (int)
ES_SNAPSHOT_PRESERVE_COUNT=48
# Webhook URL to notify for backup status
SLACK_WEBHOOK_URL=""
# Snapshot prefix
ES_SNAPSHOT_PREFIX="elasticbackup"
# Current run date
RUN_DATE="$(date +%F_%H-%M)"
# Timestamp when the script start to run
START_TIME=`date +%s`
##
# Retrieve configuration file from argument
##
while [[ $# > 1 ]]; do
    case $1 in
        # Configuration file (-c|--config)
        -c|--config)
            shift
            CONFIG_PATH="$1"
        ;;
    esac
    shift
done

##
# Load script configuration from specified path, exit otherwise
##
if [[ -f ${CONFIG_PATH} ]]
then
  . ${CONFIG_PATH}
else
  logger -p user.err -s "Configuration file ${CONFIG_PATH} not found."
  exit 1
fi

# Generation of next snapshot name
NEXT_SNAPSHOT_NAME="${ES_SNAPSHOT_PREFIX}-${RUN_DATE}"

##
# Write log to stdout/syslog
# @param $1 log.level Log level
# @param $2 Log message
##
log() {
  logger -p "$1" ${LOG_ARGS} "$2"
  return 0
}

##
# Notify slack via webhook with arguments
# @param $1 Notification message
#
##
notify_slack() {
  # Notify #devops on Slack network if webhook is specified
  if [[ -n ${SLACK_WEBHOOK_URL} ]]; then
    printf -v JSON '{"text":"[%s][%s] %s"}' ${HOST} ${RUN_DATE} "$1"
    ${CURL} -X POST -H 'Content-type: application/json' --data --insecure "$JSON" ${SLACK_WEBHOOK_URL} > /dev/null 2>&1
  fi
  return 0
}

##
# Main script ()
##

log user.info "Start elasticbackup.sh (Elasticsearch backup agent)"
# Check if command `jq` is available
if [[ -z ${JQ} ]]; then
  ERROR_MESSAGE="Command 'jq' not found, use sudo apt-get install jq first !"
  log user.err "${ERROR_MESSAGE}"
  notify_slack "${ERROR_MESSAGE}"
  exit 1
fi

# Check if command `curl` is available
if [[ -z ${CURL} ]]; then
  ERROR_MESSAGE="Command 'curl' not found, use sudo apt-get install curl first !"
  log user.err "${ERROR_MESSAGE}"
  notify_slack "${ERROR_MESSAGE}"
  exit 1
fi

# Check if ES_REPO_NAME is defined
if [[ -z ${ES_REPO_NAME} ]]; then
  ERROR_MESSAGE="Missing configuration ES_REPO_NAME"
  log user.err "${ERROR_MESSAGE}"
  notify_slack "${ERROR_MESSAGE}"
  exit 1
fi

# Check to make sure elasticsearch is actually up and running
ES_STATE=$(${CURL} -s ${ES_URL}/_cluster/health | ${JQ} --raw-output .status)
if [[ ${ES_STATE} == "green" ]] || [[ ${ES_STATE} == "yellow" ]]; then
  log user.info "Elasticsearch cluster ${ES_URL} is up (status : ${ES_STATE})"
else
  ERROR_MESSAGE="Elasticsearch cluster ${ES_URL} seems down"
  log user.err "${ERROR_MESSAGE}"
  notify_slack "${ERROR_MESSAGE}"
  exit 1;
fi

# Check to see if the repo exists and create if necessary
ES_REPO_EXISTS=$(${CURL} -s ${ES_URL}/_snapshot/ | jq --raw-output "has(\"${ES_REPO_NAME}\")")
if [[ "false" == ${ES_REPO_EXISTS} ]]; then
  log user.info "Repository ${ES_REPO_NAME} not found, create it from settings"
  # Check if ES_REPO_TYPE is defined
  if [[ -z ${ES_REPO_TYPE} ]]; then
    ERROR_MESSAGE="Missing configuration ES_REPO_TYPE for repository creation"
    log user.err "${ERROR_MESSAGE}"
    notify_slack "${ERROR_MESSAGE}"
    exit 1;
  fi
  # Check if ES_REPO_SETTINGS_JSON is defined
  if [[ -z ${ES_REPO_SETTINGS_JSON} ]]; then
    ERROR_MESSAGE="Missing configuration ES_REPO_SETTINGS_JSON for repository creation"
    log user.err "${ERROR_MESSAGE}"
    notify_slack "${ERROR_MESSAGE}"
    exit 1;
  fi
  # Create PUT request to ES cluster
  RESPONSE=$(${CURL} -s -X PUT ${ES_URL}/_snapshot/${ES_REPO_NAME} -H 'Content-Type: application/json' -d "{\"type\":\"${ES_REPO_TYPE}\",\"settings\":${ES_REPO_SETTINGS_JSON}}")
  if [[ $(echo ${RESPONSE} | jq --raw-output .acknowledged) == "true" ]]; then
    log user.info "Repository [${ES_REPO_TYPE}:${ES_REPO_NAME}] created on ES"
    else
      ERROR_MESSAGE="Repository [${ES_REPO_TYPE}:${ES_REPO_NAME}] creation failed : ${RESPONSE}"
      log user.err "${ERROR_MESSAGE}"
      notify_slack "${ERROR_MESSAGE}"
      exit 1
    fi
fi

# Check for existing number of snapshots
SNAPSHOT_LIST=$(${CURL} -s ${ES_URL}/_snapshot/${ES_REPO_NAME}/_all)
# If the current snapshot already exists, we skip
SNAPSHOT_EXISTS=$(echo ${SNAPSHOT_LIST} | jq --raw-output ".snapshots[] | .snapshot" | grep -c ${NEXT_SNAPSHOT_NAME})
if [[ ${SNAPSHOT_EXISTS} -gt 0 ]]; then
  log user.info "Snapshot '${NEXT_SNAPSHOT_NAME}' already in progress/done, skip"
  exit 0
fi

# No deletions needed, so take a snapshot!
RESPONSE=$(${CURL} -s -X PUT "${ES_URL}/_snapshot/${ES_REPO_NAME}/${NEXT_SNAPSHOT_NAME}?wait_for_completion=true")
if [[ "$(echo ${RESPONSE} | jq --raw-output .snapshot.state)" == "SUCCESS" ]]; then
  log user.info "Snapshot '${NEXT_SNAPSHOT_NAME}' created"
else
  ERROR_MESSAGE="Failed to create snapshot '${NEXT_SNAPSHOT_NAME}' : ${RESPONSE}"
  log user.err "${ERROR_MESSAGE}"
  notify_slack "${ERROR_MESSAGE}"
  exit 1;
fi

##
# Refresh snapshot list from ES server
##
SNAPSHOT_LIST=$(${CURL} -s ${ES_URL}/_snapshot/${ES_REPO_NAME}/_all)

##
# Pruning previous snapshots if required
##
SNAPSHOT_COUNT=$(echo ${SNAPSHOT_LIST} | jq "[.snapshots[] | select(.snapshot | startswith(\"${ES_SNAPSHOT_PREFIX}\")) | .snapshot] | length")
# Check if we need to delete any outdated snapshot
log user.info "Current snapshot count : ${SNAPSHOT_COUNT}/${ES_SNAPSHOT_PRESERVE_COUNT}"
if [[ ${SNAPSHOT_COUNT} -gt ${ES_SNAPSHOT_PRESERVE_COUNT} ]]; then
  TO_PURGE_SNAPSHOT_COUNT=$(expr ${SNAPSHOT_COUNT} - ${ES_SNAPSHOT_PRESERVE_COUNT})
  if [[ ${TO_PURGE_SNAPSHOT_COUNT} -gt 0 ]]; then
    log user.info "Start pruning ${TO_PURGE_SNAPSHOT_COUNT} snapshot(s)"
    for OLD_SNAPSHOT in $(echo ${SNAPSHOT_LIST} | jq --raw-output "[.snapshots[] | select(.snapshot | startswith(\"$ES_SNAPSHOT_PREFIX\")) | .snapshot][0:${TO_PURGE_SNAPSHOT_COUNT}] | .[]"); do
      RESPONSE=$(${CURL} -s -X DELETE ${ES_URL}/_snapshot/${ES_REPO_NAME}/${OLD_SNAPSHOT})
      if [[ "$(echo ${RESPONSE} | jq --raw-output .acknowledged)" == "true" ]]; then
        log user.info "Snapshot ${OLD_SNAPSHOT} pruned"
      else
        ERROR_MESSAGE="Failed to remove snapshot ${OLD_SNAPSHOT} : $(echo ${RESPONSE} | jq --raw-output .error)"
        log user.err "${ERROR_MESSAGE}"
        notify_slack "${ERROR_MESSAGE}"
      fi
    done
  fi
fi

# Create log entry for backup trace
DURATION=$((`date +%s` - ${START_TIME}))
log user.info "Backup completed in ${DURATION} seconds"

# Notify #devops on Slack network if webhook is specified
if [[ -n ${SLACK_WEBHOOK_URL} ]]; then
  SUCCESS_MESSAGE="ES snapshot ${NEXT_SNAPSHOT_NAME} completed in ${DURATION} second(s)"
  notify_slack "${SUCCESS_MESSAGE}"
fi

exit 0