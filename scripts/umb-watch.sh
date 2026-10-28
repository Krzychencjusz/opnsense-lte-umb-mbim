#!/bin/sh
# UMB watcher: synchronize peer AND interface gateway link; preserve automatic NAT.
LOCKDIR=/var/run/umb-watch.lock
PENDING=/var/run/umb-watch.reload-pending
mkdir "$LOCKDIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
trap 'exit 0' HUP INT TERM
FIRST=1
RELOAD_ERROR=0
while :; do
    VALID=0
    for DEV in $(/sbin/ifconfig -l | /usr/bin/tr ' ' '\n' | /usr/bin/awk '/^umb[0-9]+$/ {print}'); do
        PEER=$(/sbin/ifconfig "$DEV" 2>/dev/null | /usr/bin/awk '$1 == "inet" && $3 == "-->" {print $4; exit}')
        STATE="/var/run/umb-watch.${DEV}.peer"
        ERRSTATE="/var/run/umb-watch.${DEV}.err"
        if [ -z "$PEER" ]; then
            /bin/rm -f "$STATE" "$ERRSTATE"
            continue
        fi
        # Always inspect the current configuration, even when PEER has not changed.
        RESULT=$(/usr/local/bin/php /usr/local/sbin/umb-gateway-sync.php "$DEV" "$PEER" --apply 2>&1)
        RC=$?
        case "$RC" in
            0|10)
                VALID=1
                printf '%s\n' "$PEER" > "$STATE"
                /bin/rm -f "$ERRSTATE"
                if [ "$RC" = 10 ]; then
                    /usr/bin/logger -t umb-watch "Gateway configuration synchronized: $RESULT"
                fi
                ;;
            *)
                ERRKEY="${PEER}:${RC}"
                OLDERR=$(/bin/cat "$ERRSTATE" 2>/dev/null)
                if [ "$ERRKEY" != "$OLDERR" ]; then
                    /usr/bin/logger -t umb-watch "Gateway synchronization failed: $RESULT"
                    printf '%s\n' "$ERRKEY" > "$ERRSTATE"
                fi
                ;;
        esac
    done
    # A fresh process also reapplies once, recovering an interrupted previous run.
    if [ "$VALID" = 1 ] && { [ "$FIRST" = 1 ] || [ -f "$PENDING" ]; }; then
        if /usr/local/sbin/configctl interface routes configure >/dev/null 2>&1 &&
           /usr/local/sbin/configctl filter reload >/dev/null 2>&1; then
            /bin/rm -f "$PENDING"
            FIRST=0
            RELOAD_ERROR=0
            /usr/bin/logger -t umb-watch "Routes and firewall rules reapplied"
        else
            if [ "$RELOAD_ERROR" = 0 ]; then
                /usr/bin/logger -t umb-watch "Routes/firewall reload failed; retrying on subsequent checks"
                RELOAD_ERROR=1
            fi
        fi
    fi
    sleep 10
done
