#!/usr/bin/env bash
set -e

app_name="${1:-pal-tracker}"
script_dir="${2:-.}"
service_name="${3:-tracker-database}"

function pre_tunnel_exit() {
    echo "ERROR: No suitable credentials found for application '$app_name' and service '$service_name'" >&2
}

trap pre_tunnel_exit EXIT

echo "Retrieving target database parameters ..."

# The value of VCAP_SERVICES is obtained from the running process
# environment to handle the use of credhub-managed credentials.
vcap_services=$(cf ssh $app_name -c 'perl -0 -ne "print if (s/^VCAP_SERVICES=//)" /proc/$(pgrep java)/environ')
credentials=$(echo "$vcap_services" | jq ".[] | .[] | select(.instance_name == \"$service_name\") | .credentials")

db_host=$(echo $credentials | jq -r '.hostname')
db_name=$(echo $credentials | jq -r '.name')
db_username=$(echo $credentials | jq -r '.username')
db_password=$(echo $credentials | jq -r '.password')
db_port=$(echo $credentials | jq -r '.port')

test -n "$db_host" || exit 1

echo "Opening ssh tunnel to $db_host:$db_port"
cf ssh -N -L 63306:$db_host:$db_port $app_name &
cf_ssh_pid=$!

function close_tunnel_at_exit() {
    echo "Closing tunnel"
    kill -KILL $cf_ssh_pid
}

trap close_tunnel_at_exit EXIT

# Note that the following depends on /dev/tcp support being compiled
# into the version of bash being used. However, if such support is
# not present it will gracefully degrade into a 20-second wait, which
# should be sufficient.
tries=20
while (( tries > 0 )) && ! (echo "" > /dev/tcp/localhost/63306) 2> /dev/null
do
    echo "Waiting for tunnel ($tries attempts remaining)"
    (( tries = tries - 1 ))
    sleep 1
done

echo "Running migration ..."
flyway-*/flyway -url="jdbc:mysql://127.0.0.1:63306/$db_name" \
    -locations=filesystem:"$script_dir"/databases/tracker \
    -user="$db_username" \
    -password="$db_password" \
    migrate

echo "Migration complete"