#!/bin/sh
for DEV in $(/sbin/ifconfig -l | /usr/bin/tr ' ' '\n' | /usr/bin/awk '/^umb[0-9]+$/ {print}'); do
    /sbin/ifconfig "$DEV" up
done
/usr/sbin/daemon /usr/local/sbin/umb-watch.sh
exit 0
