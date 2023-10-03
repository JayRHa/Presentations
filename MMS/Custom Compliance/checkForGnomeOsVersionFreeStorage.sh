#!/bin/dash

log="$HOME/compliance.log"
echo "$(date) | Starting compliance script" >> $log

# Get free storage
free_storage=$(df -h / | tail -1 | awk '{print $4}')

# Get OS version
if [ -f /etc/os-release ]; then
    . /etc/os-release
    os_version="$NAME $VERSION_ID"
else
    os_version="Unknown OS"
fi

echo "$(date) | OS Version: $os_version | Free Storage: $free_storage" >> $log

processes="gnome-shell"

numProcesses=$(echo "$processes" | awk -F" " '{print NF-1}')
numProcesses=$((numProcesses+1))

iteration=0

echo -n "{"
echo "\"OS Version\": \"$os_version\","
echo "\"Free Storage\": \"$free_storage\","
echo "$processes" | tr ' ' '\n' | while read process; do
    echo -n "$(date) |   + Working on process [$process]..." >> $log
    iteration=$((iteration+1))
    if pgrep -l "$process" > /dev/null; then
        echo -n "\"$process\": \"Running\""
        echo "Running" >> $log
    else
        echo -n "\"$process\": \"NotRunning\""
        echo "NotRunning" >> $log
    fi

    if [ $iteration -lt $numProcesses ]; then
        echo -n ","
    fi
done
echo "}"
echo "$(date) | Ending compliance script" >> $log
