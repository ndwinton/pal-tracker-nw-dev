#!/usr/bin/env bash
set -e

app_name="${1:-pal-tracker}"
script_dir="${2:-.}"
service_name="${3:-tracker-database}"
service_key="${4:-flyway-migration-key}"

function pre_tunnel_exit() {
    echo "ERROR: No suitable credentials found for application '$app_name' and service '$service_name'" >&2
}

trap pre_tunnel_exit EXIT

# If a service is using credhub then the credentials are not exposed
# in VCAP_SERVICES. So we create a service key for the database in order
# to obtain the necessary. Creating a key is idempotent, so it does not
# matter if it already exists.

echo "Creating service key, if necessary ..."

cf create-service-key $service_name $service_key > /dev/null

echo "Retrieving target database parameters ..."

credentials=$(cf service-key $service_name $service_key | sed -ne '/{/,$p')

db_host=$(echo $credentials | jq -r '.hostname')
db_name=$(echo $credentials | jq -r '.name')
db_username=$(echo $credentials | jq -r '.username')
db_password=$(echo $credentials | jq -r '.password')
db_port=$(echo $credentials | jq -r '.port')

test -n "$db_host" || exit 1

echo "Opening ssh tunnel to $db_host:$db_port ..."

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