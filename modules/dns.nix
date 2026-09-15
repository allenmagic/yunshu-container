{ config, lib, ... }:

with lib;

let
  cfg = config.services.yunshu.dns;
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
          iifname "${cfg.interface}" ip daddr != 127.0.0.1 udp dport 53 dnat to ${cfg.listen}:${toString cfg.port}
          iifname "${cfg.interface}" ip daddr != 127.0.0.1 tcp dport 53 dnat to ${cfg.listen}:${toString cfg.port}
        }
      '';
    };
  };
}
