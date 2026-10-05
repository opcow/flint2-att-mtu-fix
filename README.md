# flint2-att-mtu-fix

Keeps IPv6 working on a GL.iNet Flint 2 (GL-MT6000) behind an AT&T residential gateway in IP passthrough mode by re-applying MTU and MSS clamping settings whenever firmware updates or GL's own scripts reset them.

## The problem

AT&T's gateway filters ICMPv6, so Path MTU Discovery breaks. IPv6 routers never fragment; they send "Packet Too Big" and expect the sender to shrink. When those messages are dropped, connections open fine and then stall as soon as a large transfer starts.

Symptoms: slow page loads and outright load failures on every device, which go away when IPv6 is disabled. It often looks like a DNS problem.

## The fix

| Setting | Value | Why |
|---|---|---|
| `network.wan.mtu` | 1492 | Caps the WAN MTU |
| `network.wan6.mtu` | 1492 | Same for the IPv6 WAN interface |
| `dhcp.lan.ra_mtu` | 1492 | Advertises the right MTU to LAN clients via Router Advertisements; this also covers QUIC/UDP, which MSS clamping can't. Not exposed in the GL.iNet UI. |
| `firewall.@zone[wan].mtu_fix` | 1 | TCP MSS clamping on the WAN zone |

The script also makes sure miniupnpd is installed, enabled and running (Tailscale needs UPnP/NAT-PMP for direct connections). It checks that full cone NAT rules are present; if they're missing, it logs a warning, because that can only be re-enabled by toggling it off and on in the GL.iNet UI.

The script is idempotent. It changes and reloads only what is actually wrong, so it's safe to run at every boot and on a schedule.

## Install

Copy the script to the router (`-O` because the router has no SFTP server):

```
scp -O fix-ipv6-mtu.sh root@192.168.8.1:/root/
```

Then on the router:

```sh
sed -i 's/\r$//' /root/fix-ipv6-mtu.sh          # strip Windows line endings, if any
chmod +x /root/fix-ipv6-mtu.sh

# Keep the script, boot hook and schedule across firmware upgrades
echo /root/fix-ipv6-mtu.sh >> /etc/sysupgrade.conf
echo /etc/rc.local         >> /etc/sysupgrade.conf
echo /etc/crontabs/root    >> /etc/sysupgrade.conf

# Run 60 s after every boot
sed -i '/^exit 0/i (sleep 60; /root/fix-ipv6-mtu.sh) &' /etc/rc.local

# Run every 30 minutes (catches resets that happen without a reboot)
echo '*/30 * * * * /root/fix-ipv6-mtu.sh >/dev/null 2>&1' >> /etc/crontabs/root
/etc/init.d/cron restart

# Test run
/root/fix-ipv6-mtu.sh
```

Confirm the files will survive an upgrade with `sysupgrade -l`.

## Checking what it did

```sh
logread -e ipv6fix          # this boot only (system log is in RAM)
cat /root/ipv6fix.log       # persistent; timestamped record of every fix it applied
```

## If you upgrade without "Keep Settings"

Everything is wiped, including the script. Run it straight from your PC without copying it first.

PowerShell:

```
Get-Content fix-ipv6-mtu.sh -Raw | ssh root@192.168.8.1 sh
```

Linux/macOS:

```
ssh root@192.168.8.1 sh < fix-ipv6-mtu.sh
```

Then repeat the install steps.

## Verifying the network side

After the settings are applied, reconnect clients so they pick up the new Router Advertisement, then run [test-ipv6.com](https://test-ipv6.com). Check that the large-packet test on the "Tests Run" tab passes.

## Notes

- Tested on a Flint 2 (GL-MT6000) running GL.iNet firmware with IPv6 in Native mode.
- 1492 is right for AT&T fiber/passthrough. If test-ipv6.com still reports MTU problems, try a lower value.
- The WAN firewall zone index is looked up by name, not assumed.
# flint2-att-mtu-fix
