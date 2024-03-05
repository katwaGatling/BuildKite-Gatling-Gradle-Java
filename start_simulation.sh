#!/bin/bash

# Start a Gatling Enterprise simulation & display its results

# This script has the same purpose as the Jenkins, Bamboo or Teamcity plugin. It enables you to launch a Gatling
# Enterprise simulation and display live metrics.

# This script doesn’t create a new Gatling Enterprise simulation, you have to create it using the Gatling Enterprise
# Dashboard before.

set -e

checkParameter() {
  local __varname=$1

  if [ -z $2 ]; then
    echo "Missing parameter" $1
    echo "Syntax: ./start_simulation.sh gatlingEnterpriseUrl apiToken simulationId"
    exit 1
  else
    eval $__varname=$2
  fi
}

execRequest() {
  result=$(curl -s -X $3 --header "Authorization:$2" $1)
  if [ $? -ne 0 ]; then
    echo "Gatling Enterprise url is not configured correctly, please check that the url is correct" >&2
    exit 1
  fi
  checkForError "$result"
  echo "$result"
}

checkForError() {
  error=$(echo ${1} | jq -r '.error')
  if [ $error != "null" ]; then
    errorDescription=$(echo ${1} |  jq -r '.error_description')
    echo "$error: $errorDescription" >&2
    exit 1
  fi
}

isRunning() {
  [ $1 -eq 0 ] || [ $1 -eq 1 ] || [ $1 -eq 2 ] || [ $1 -eq 3 ] || [ $1 -eq 15 ]
}

isSuccessful() {
  [ $1 -eq 4 ] || [ $1 -eq 5 ]
}

isInjecting() {
  [ $1 -eq 3 ]
}

statuses=(
  [0]="Building"
  [1]="Deploying"
  [2]="Deployed"
  [3]="Injecting"
  [4]="Successful"
  [5]="Assertions successful"
  [6]="Automatically stopped"
  [7]="Manually stopped"
  [8]="Assertions failed"
  [9]="Timeout"
  [10]="Build failed"
  [11]="Broken"
  [12]="Deployment failed"
  [13]="Invalid license"
  [15]="Abort requested"
)

# Check params
command -v jq >/dev/null 2>&1 || { echo >&2 "Please install jq to use this script: https://stedolan.github.io/jq/download/.  Aborting."; exit 1; }
checkParameter gatlingEnterpriseUrl $1
checkParameter apiToken $2
checkParameter simulationId $3

if [[ $gatlingEnterpriseUrl == */ ]]; then
  echo "Gatling Enterprise URL can't end with a /, please remove it"
  exit 1
fi

# Start simulation
run=$(execRequest "${gatlingEnterpriseUrl}/api/public/simulations/start?simulation=${simulationId}" "${apiToken}" POST)
runId=$(echo "${run}" | jq -r '.runId')
reportsPath=$(echo "${run}" | jq -r '.reportsPath // empty')
reportsUrl=$([ -z "$reportsPath" ] && echo "${gatlingEnterpriseUrl}/#/simulations/reports/${runId}" || echo "${gatlingEnterpriseUrl}${reportsPath}")

echo "Simulation started with runId ${runId}"
echo "The corresponding reports will be available here: ${reportsUrl}"

runInformation=$(execRequest "${gatlingEnterpriseUrl}/api/public/run?run=${runId}" "${apiToken}" GET)
runStatus=$(echo "${runInformation}" | jq -r '.status')

# Check every 5 seconds the run status
while isRunning "${runStatus}"; do
  sleep 5

  runInformation=$(execRequest "${gatlingEnterpriseUrl}/api/public/run?run=${runId}" "${apiToken}" GET)
  runStatus=$(echo "${runInformation}" | jq -r '.status')

  if isInjecting "${runStatus}"; then

    runMetrics=$(execRequest "${gatlingEnterpriseUrl}/api/public/summaries/requests?run=${runId}" "${apiToken}" GET)
    urlUserMetric="${gatlingEnterpriseUrl}/api/public/series?run=${runId}&metric=usrActive"
    activeUsersMetrics=$(curl -s -X GET --header "Authorization:${apiToken}" "${urlUserMetric}")

    echo ""
    date
    echo "Number of concurrent users:" \
         "$(echo "${activeUsersMetrics}" | jq -r '[.[].values[-1]] | add // 0')"
    echo "Number of requests: $(echo "${runMetrics}" | jq -r '.out.counts.total')"
    echo "Number of requests per second: $(echo "${runMetrics}" | jq -r '.out.rps.total')"
    echo "Failure ratio: $(echo "${runMetrics}" | jq -r '.in.counts.koPercent')"
  fi
done

# Run is finished
echo "Simulation finished with status ${statuses[${runStatus}]}"
echo "The corresponding reports is available here: ${reportsUrl}"

assertions=$(echo "${runInformation}" | jq -r '.assertions')
assertionsLength=$(echo "${assertions}" | jq -r 'length')

for ((i=0; i<assertionsLength; i++)); do
  if [ "$(echo "${assertions}" | jq -r --arg i "${i}" '.[$i|tonumber].result')" == "true" ]; then
    result="succeeded"
  else
    result="failed"
  fi
  echo "Assertion: $(echo "${assertions}" | jq -r --arg i "${i}" \
       '.[$i|tonumber].message'), $result with value: $(echo "${assertions}" \
       | jq -r --arg i "${i}" '.[$i|tonumber].actualValue')"
done

if ! isSuccessful "${runStatus}"; then
  exit 1
fi
