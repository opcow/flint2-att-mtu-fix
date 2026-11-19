#!/bin/sh
# fix-ipv6-mtu.sh - re-apply Flint 2 IPv6 MTU / UPnP fixes after a firmware upgrade.
# Safe to run any time: it only changes (and reloads) what is actually wrong.
# Log: logread -e ipv6fix   (persistent: /root/ipv6fix.log)

TAG=ipv6fix
MTU=1492
log() { logger -t "$TAG" "$*"; echo "$*"; case "$*" in set*|added*|WARNING*|started*) echo "$(date '+%F %T') $*" >> /root/ipv6fix.log;; esac; }
changed=0

# ensure <uci key> <value> - sets it only if different
ensure() {
  if [ "$(uci -q get "$1")" != "$2" ]; then
    uci set "$1=$2"
    log "set $1=$2"
    changed=1
  fi
}

# --- MTU (AT&T gateway filters ICMPv6, so PMTUD is broken) ---
ensure network.wan.mtu $MTU
ensure network.wan6.mtu $MTU
ensure dhcp.lan.ra_mtu $MTU

# --- MTU on the WAN *device* section ---
# Firmware 4.11 added a 'config device' section for eth1; when one exists, netifd
# takes the MTU from it and ignores network.wan.mtu. Index looked up, not assumed.
WANDEV=$(uci -q get network.wan.device)
[ -z "$WANDEV" ] && WANDEV=eth1
DEVIDX=$(uci show network | sed -n "s/^network\.@device\[\([0-9]*\)\]\.name='$WANDEV'$/\1/p" | head -n1)
if [ -n "$DEVIDX" ]; then
  DEVKEY="network.@device[$DEVIDX]"
else
  SEC=$(uci add network device)
  uci set "network.$SEC.name=$WANDEV"
  DEVKEY="network.$SEC"
  log "added device section for $WANDEV"
  changed=1
fi
ensure "$DEVKEY.mtu" $MTU

# --- MSS clamping on the WAN zone (index looked up, not assumed) ---
WANZ=$(uci show firewall | sed -n "s/^firewall\.@zone\[\([0-9]*\)\]\.name='wan'$/\1/p")
if [ -n "$WANZ" ]; then
  ensure "firewall.@zone[$WANZ].mtu_fix" 1
else
  log "WARNING: could not find the wan firewall zone"
fi

# --- UPnP / NAT-PMP for Tailscale direct connections ---
if [ ! -x /etc/init.d/miniupnpd ]; then
  log "miniupnpd missing, installing"
  if opkg update >/dev/null 2>&1 && opkg install miniupnpd >/dev/null 2>&1; then
    log "miniupnpd installed"
  else
    log "WARNING: miniupnpd install failed"
  fi
fi
[ -f /etc/config/upnpd ] && ensure upnpd.config.enabled 1

# --- Apply only if something changed (reload_config touches only changed configs) ---
if [ "$changed" = 1 ]; then
  uci commit
  reload_config
  sleep 10
fi

# --- Live check: uci can be right while the interface isn't ---
# MSS clamping (--clamp-mss-to-pmtu) follows the live interface MTU, so this matters.
LIVE=$(cat "/sys/class/net/$WANDEV/mtu" 2>/dev/null)
if [ "$LIVE" != "$MTU" ]; then
  log "WARNING: $WANDEV live MTU is ${LIVE:-unknown} despite config - forcing $MTU"
  ip link set "$WANDEV" mtu $MTU
  changed=1
fi

if [ -x /etc/init.d/miniupnpd ]; then
  /etc/init.d/miniupnpd enabled || { /etc/init.d/miniupnpd enable; log "enabled miniupnpd"; }
  # GL's firewall include already restarts it on firewall reloads; only start it if it's down
  if ! pidof miniupnpd >/dev/null; then
    /etc/init.d/miniupnpd start
    log "started miniupnpd"
  fi
fi

# --- Full cone NAT: can only be re-applied from the UI, so just check it ---
sleep 3
if iptables-save 2>/dev/null | grep -qi fullcone; then
  log "full cone NAT rules present"
else
  log "WARNING: full cone NAT rules missing - toggle it off/on in the GL.iNet UI"
fi

[ "$changed" = 1 ] && log "done - settings were re-applied" || log "done - everything already correct"
