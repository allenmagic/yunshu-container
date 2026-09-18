{ config, lib, pkgs, ... }:

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
        YunShu 隧道 DNS 的监听地址（tun0 上的地址），作为**首选上游**。
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
      description = "在网关地址上开本地解析器（fake-IP 分流的入口，不能关）。";
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
        本地解析器的监听地址（= 客户端从 DHCP 拿到的网关/DNS）。
        gateway 模式会把它设成 yunshu.container.gateway.address。
      '';
    };

    fallbackServers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "223.5.5.5" "119.29.29.29" ];
      description = ''
        隧道 DNS 不应答时的降级上游（公网 DNS）。按声明顺序回落，
        隧道 DNS 超时才轮到它们。
      '';
    };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = mkIf (cfg.listen != "127.0.0.1" && cfg.listen != "::1") [ cfg.port ];
    networking.firewall.allowedUDPPorts = mkIf (cfg.listen != "127.0.0.1" && cfg.listen != "::1") [ cfg.port ];

    # 不要改回"把 53 DNAT 到别的容器"：macvlan 下跨容器 DNAT 实测不通，
    # 且目标不可达时客户端 DNS 会整个断掉。本地解析器永远在场。
    services.dnsmasq = mkIf cfg.transparentRedirect {
      enable = true;
      # 不接管容器自身的解析：容器的 resolv.conf 由部署方写死（隧道 DNS 优先），
      # 让 dnsmasq 覆盖它会绕一圈。
      resolveLocalQueries = false;

      settings = {
        interface = cfg.interface;
        # bind-dynamic 而非 bind-interfaces：接口/地址变化时自动跟随。
        bind-dynamic = true;

        # 上游顺序即优先级：隧道 DNS 在前，公网 DNS 兜底。
        strict-order = true;
        no-resolv = true;
        server = [ cfg.listen ] ++ cfg.fallbackServers;
      };
    };
  };
}
