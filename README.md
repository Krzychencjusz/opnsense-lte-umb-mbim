# OPNsense UMB/MBIM LTE WAN support

This repository documents a tested way to use FreeBSD `umb(4)` / MBIM cellular interfaces as WAN interfaces on OPNsense, including automatic dynamic gateway synchronization and optional dashboard labelling.

The setup was developed and tested with a Sierra Wireless MC7455, but the watcher is intentionally written for generic FreeBSD `umbX` interfaces.

## What this solves

FreeBSD can bring an MBIM modem up as a point-to-point `umbX` interface and obtain an address such as:

```text
inet 10.161.237.225 --> 10.161.237.226
```

The right-hand address is the current MBIM peer and must be used as the IPv4 gateway.

OPNsense sees the interface and its endpoint, but does not automatically use the dynamic `umbX` endpoint as the configured gateway. The peer may also change after a reboot or reconnect.

`umb-watch.sh` closes that gap.

For every active `umbX` interface it:

1. detects the current MBIM peer;
2. finds which internal OPNsense interface (`wan`, `opt1`, `opt4`, etc.) is assigned to that device;
3. finds the single enabled IPv4 gateway assigned to that OPNsense interface;
4. updates that gateway when the MBIM peer changes;
5. asks OPNsense to rebuild routing.

Nothing is hard-coded to a specific `optX` or gateway name.

## Multiple modems

The watcher supports multiple `umbX` devices in one process.

Example:

```text
umb0 -> wan  -> LTE_MAIN
umb1 -> opt4 -> LTE_BACKUP
umb2 -> opt7 -> MOBILE_3
```

The mappings are discovered from the live OPNsense configuration.

For safety, a given OPNsense interface must have exactly one enabled IPv4 gateway. If zero or multiple matching gateways are found, the watcher refuses to make an ambiguous change and logs the condition.

## Tested behaviour

The following was verified on the test system:

- `umb(4)` loads at boot;
- the modem reconnects after reboot and cold boot;
- the MBIM peer can change between sessions;
- the watcher detects the new peer and updates the correct OPNsense gateway;
- the watcher tolerates a long period with no LTE address;
- the watcher does not reset the modem while waiting for connectivity;
- primary WAN -> LTE failover works;
- LTE -> primary WAN failback works;
- the solution does not depend on a gateway group being present;
- the watcher does not depend on specific OPNsense internal interface names;
- mapping logic was also tested in-memory with two simulated `umb` assignments.

## Why MBIM instead of PPP

PPP was tested first. The MC7455 registered successfully and PPP could negotiate LCP/PAP/IPCP and obtain an IPv4 address, but data traffic showed PPP FCS errors and was unusable.

Using the native FreeBSD `umb(4)` driver and MBIM immediately produced working IP traffic.

The modem used in testing exposed:

```text
diag,nmea,modem,mbim
```

with USB ID:

```text
1199:9071
```

## 1. Load the UMB driver at boot

Create or edit:

```text
/boot/loader.conf.local
```

and add:

```text
umb_load="YES"
```

After reboot, verify:

```sh
ifconfig umb0
```

or, for all UMB devices:

```sh
ifconfig -l
```

## 2. Configure the modem APN

Example:

```sh
umbctl umb0 apn internet
```

Verify:

```sh
umbctl umb0
```

In the tested setup the APN persisted across interface down/up and reboot, so the final startup hook deliberately does not call `umbctl` on every boot.

## 3. Assign the interface in OPNsense

Assign the `umbX` device to an OPNsense interface.

For IPv4 Configuration Type use:

```text
None
```

Do not use DHCP on the UMB interface. MBIM/`umb(4)` assigns the address and point-to-point endpoint directly.

## 4. Create an IPv4 gateway

Create one enabled IPv4 gateway for each assigned `umbX` interface.

The gateway address may initially be a placeholder/current peer; the watcher will synchronize it automatically when the modem obtains a peer.

A monitor address such as:

```text
1.1.1.1
```

worked in testing.

The gateway name is arbitrary. It does not have to be `WAN_LTE_PPP` or any other fixed name.

## 5. Install the watcher

Copy:

```text
scripts/umb-watch.sh
```

to:

```text
/usr/local/sbin/umb-watch.sh
```

and make it executable:

```sh
chmod +x /usr/local/sbin/umb-watch.sh
```

## 6. Install the startup hook

Copy:

```text
scripts/rc.syshook.d/50-umb.sh
```

to:

```text
/usr/local/etc/rc.syshook.d/start/50-umb.sh
```

and make it executable:

```sh
chmod +x /usr/local/etc/rc.syshook.d/start/50-umb.sh
```

The hook detects every `umbX`, brings it administratively up and launches one detached watcher process through FreeBSD `daemon(8)`.

It does not wait for LTE registration. OPNsense can finish boot while the modem establishes service in the background.

## 7. Optional: show `LTE / MBIM` instead of `<unknown type>`

FreeBSD reports the UMB media type as:

```text
<unknown type>
```

and OPNsense passes that value through to the existing Interfaces dashboard widget.

The optional patch changes only the dashboard presentation for devices whose name starts with `umb`.

Copy:

```text
scripts/umb-widget-patch.sh
```

to:

```text
/usr/local/sbin/umb-widget-patch.sh
```

and:

```text
scripts/rc.syshook.d/40-umb-widget-patch.sh
```

to:

```text
/usr/local/etc/rc.syshook.d/start/40-umb-widget-patch.sh
```

Then:

```sh
chmod +x /usr/local/sbin/umb-widget-patch.sh
chmod +x /usr/local/etc/rc.syshook.d/start/40-umb-widget-patch.sh
```

The patch adds:

```js
if ((intf_data.device ?? "").startsWith("umb")) media = "LTE / MBIM"; // umb-media-patch
```

to the existing OPNsense Interfaces widget.

The patcher is idempotent: if the marker already exists, it exits without modifying the file. If a future OPNsense version changes the expected widget layout, it refuses to patch blindly and logs an error.

## Fail-safe behaviour

`umb-watch.sh` uses defensive exit codes from its PHP configuration lookup:

- `2` — expected OPNsense configuration structure is missing/incompatible;
- `3` — no OPNsense interface assignment exists for the `umbX` device;
- `4` — no enabled IPv4 gateway exists for the assigned interface;
- `5` — more than one enabled IPv4 gateway matches, so the update is ambiguous.

Errors are logged with:

```text
umb-watch
```

The watcher also stores per-device state under:

```text
/var/run/umb-watch.umbX.peer
/var/run/umb-watch.umbX.err
```

A single lock directory prevents duplicate watcher instances:

```text
/var/run/umb-watch.lock
```

## Failover is optional

The watcher only synchronizes the current MBIM peer with the matching OPNsense IPv4 gateway.

It does not configure gateway groups, policy routing, tiers, load balancing or default-route policy.

Therefore the same mechanism can be used when `umbX` is:

- the only WAN;
- an additional independent WAN;
- part of a failover group;
- part of a load-balancing design;
- one of several cellular WANs.

Those policies remain under normal OPNsense configuration.

## Useful checks

Show all UMB interfaces:

```sh
ifconfig -l | tr ' ' '\n' | awk '/^umb[0-9]+$/'
```

Show current point-to-point address:

```sh
ifconfig umb0 | grep inet
```

Check the watcher:

```sh
ps axww | grep '[u]mb-watch'
```

Show the state recorded for a modem:

```sh
cat /var/run/umb-watch.umb0.peer
```

Show routing:

```sh
netstat -rn -f inet
```

Show how OPNsense currently maps UMB devices to internal interface IDs and gateways:

```sh
php -r 'require_once "/usr/local/etc/inc/config.inc"; global $config; foreach ($config["interfaces"] as $id=>$cfg) { $dev=$cfg["if"] ?? ""; if (preg_match("/^umb[0-9]+$/",$dev)) { echo "$dev -> $id\n"; foreach ($config["OPNsense"]["Gateways"]["gateway_item"] as $gw) { if (($gw["interface"] ?? "") === $id && ($gw["ipprotocol"] ?? "") === "inet" && ($gw["disabled"] ?? "0") !== "1") echo "  gateway: ".($gw["name"] ?? "")." = ".($gw["gateway"] ?? "")."\n"; } } }'
```

## Upgrade considerations

This is a custom integration, not native OPNsense UMB gateway support.

The design avoids hard-coding OPNsense internal interface names and gateway names, and it deliberately refuses unsafe writes if the expected configuration structure changes.

Still, after every major OPNsense upgrade verify:

```text
umb.ko
umbctl
umbX interface creation
umb-watch process
dynamic peer -> gateway synchronization
routing
failover/failback, if used
dashboard patch, if used
```

The optional dashboard patch modifies an OPNsense core JavaScript file. An OPNsense core update may overwrite that file. `40-umb-widget-patch.sh` automatically reapplies the patch on boot if the expected insertion point still exists.

The watcher currently uses OPNsense's PHP configuration structure and:

```sh
configctl interface routes configure
```

A future major OPNsense redesign could require an update to those integration points.

## Notes from the tested MC7455 setup

Example modem status:

```text
Sierra Wireless MC7455
Firmware: SWI9X30C_02.20.03.00
USB configuration: diag,nmea,modem,mbim
```

Example working UMB session:

```text
inet 10.161.237.225 --> 10.161.237.226
```

Example routing with primary WAN online:

```text
default        192.168.26.1       UGS   igb0
1.1.1.1        10.161.237.226     UGHS  umb0
```

Example routing after primary WAN failure:

```text
default        10.161.237.226     UGS   umb0
1.1.1.1        10.161.237.226     UGHS  umb0
```

When the primary WAN returned, the default route moved back to the primary interface.

## Repository layout

```text
.
├── README.md
└── scripts
    ├── umb-watch.sh
    ├── umb-widget-patch.sh
    └── rc.syshook.d
        ├── 40-umb-widget-patch.sh
        └── 50-umb.sh
```

## License

No license has been selected yet. Add a `LICENSE` file before publishing if you want to define reuse and redistribution terms.
