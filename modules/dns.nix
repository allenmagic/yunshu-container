{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.yunshu.dns;

  # 客户端的 DNS 查询目标。开机时隧道多半还没连上，所以静态规则先落在降级目标；
  # 隧道起来后由下面的 watcher 原子切换过去。
  initialTarget = if cfg.fallbackServer != null then cfg.fallbackServer else cfg.listen;

  targetScript = pkgs.writeShellScript "yunshu-dns-target" ''
    set -eu
    IP=${pkgs.iproute2}/bin/ip
    NFT=${pkgs.nftables}/bin/nft
    IFACE=${cfg.interface}
    VIP=${cfg.vip}
    PORT=${toString cfg.port}
    TUNNEL=${cfg.listen}
    FALLBACK=${if cfg.fallbackServer != null then cfg.fallbackServer else cfg.listen}

    # flush + add 写在同一个 nft -f 里：整份文件是一个原子事务，中间没有
    # "规则为空"的窗口。分两条 nft 命令写就会有一个客户端 DNS 黑洞的间隙。
    set_target() {
      "$NFT" -f - <<EOF
flush chain inet yunshu-dns dns-dnat
add rule inet yunshu-dns dns-dnat iifname "$IFACE" ip daddr $VIP udp dport $PORT dnat ip to $1:$PORT
add rule inet yunshu-dns dns-dnat iifname "$IFACE" ip daddr $VIP tcp dport $PORT dnat ip to $1:$PORT
EOF
    }

    current=""
    while true; do
      if "$IP" link show tun0 >/dev/null 2>&1; then want="$TUNNEL"; else want="$FALLBACK"; fi
      # 失败时不推进 current，下一轮重试；nftables.service 还没跑起来时会走到这里
      if [ "$want" != "$current" ] && set_target "$want"; then current="$want"; fi
      sleep 3
    done
  '';
in
{
  options.services.yunshu.dns = {
    enable = mkEnableOption "DNS service inside the YunShu router VM";

    listen = mkOption {
      type = types.str;
      default = "10.251.1.1";
      description = ''
        Local address where YunShu's tunnel DNS listener is bound. The daemon
        binds DNS on the tun0 address (10.251.1.1), not loopback.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 53;
      description = "UDP/TCP port for the DNS endpoint.";
    };

    transparentRedirect = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Transparently redirect LAN DNS traffic on port 53 to the container's
        local DNS endpoint. This is opt-in outside gateway mode and can be
        disabled explicitly even in gateway mode.
      '';
    };

    interface = mkOption {
      type = types.str;
      default = "eth0";
      description = ''
        接收 LAN DNS 查询的接口名。gateway 模式会把它设成
        yunshu.container.lanInterface。

        注意这里必须是一个**容器内**的 option：本模块在容器内求值，
        而 yunshu.container.* 是宿主侧 option，容器求值上下文里根本不存在
        ——直接引用会报 "attribute 'yunshu' missing"。
      '';
    };

    vip = mkOption {
      type = types.str;
      default = "192.168.10.1";
      description = ''
        网关地址：只有目的地址是它的 53 查询会被 DNAT 到隧道 DNS。
        gateway 模式会把它设成 yunshu.container.gateway.address。

        不能省：同网段其它容器的上游查询也从本接口进来，一并改写就成了环。
      '';
    };

    fallbackServer = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "192.168.10.7";
      description = ''
        隧道不可用时把客户端 DNS 转给谁（通常是 dnsmasq 容器的地址）。
        null = 不降级：隧道没连上时客户端 DNS 直接黑洞，不会自动回落到公网解析。

        判据是 tun0 是否存在——与 yunshu-routes 用的是同一个，不引入新的健康检查语义。
      '';
    };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = mkIf (cfg.listen != "127.0.0.1" && cfg.listen != "::1") [ cfg.port ];
    networking.firewall.allowedUDPPorts = mkIf (cfg.listen != "127.0.0.1" && cfg.listen != "::1") [ cfg.port ];

    networking.nftables.enable = true;
    networking.nftables.tables.yunshu-dns = mkIf cfg.transparentRedirect {
      family = "inet";
      content = ''
        chain dns-dnat {
          type nat hook prerouting priority dstnat; policy accept;
          iifname "${cfg.interface}" ip daddr ${cfg.vip} udp dport 53 dnat ip to ${initialTarget}:${toString cfg.port}
          iifname "${cfg.interface}" ip daddr ${cfg.vip} tcp dport 53 dnat ip to ${initialTarget}:${toString cfg.port}
        }
      '';
    };

    systemd.services.yunshu-dns-target = mkIf (cfg.transparentRedirect && cfg.fallbackServer != null) {
      description = "Point client DNS at the tunnel resolver when tun0 exists, else at the fallback";
      wantedBy = [ "multi-user.target" ];
      after = [ "nftables.service" ];
      wants = [ "nftables.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${targetScript}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
