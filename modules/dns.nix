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
      description = ''
        在网关地址上开一个本地解析器，把客户端 DNS 转发到隧道 DNS（首选）或
        降级上游。这是 fake-IP 分流的入口，不能关。
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
        本地解析器的监听地址（= 客户端从 DHCP 拿到的网关/DNS）。
        gateway 模式会把它设成 yunshu.container.gateway.address。
      '';
    };

    fallbackServers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "223.5.5.5" "119.29.29.29" ];
      description = ''
        隧道 DNS 不应答时的降级上游（公网 DNS）。

        用 dnsmasq 的 strict-order 实现回落：按声明顺序逐个尝试，隧道 DNS
        超时才轮到公网。**不要在隧道可用时也把公网 DNS 混进来**——那样被墙
        域名可能拿到公网污染应答，fake-IP 不触发，分流直接失效。
      '';
    };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = mkIf (cfg.listen != "127.0.0.1" && cfg.listen != "::1") [ cfg.port ];
    networking.firewall.allowedUDPPorts = mkIf (cfg.listen != "127.0.0.1" && cfg.listen != "::1") [ cfg.port ];

    # 以前这里是"把 LAN 的 53 DNAT 到隧道 DNS / 降级容器"。跨容器 DNAT 在
    # macvlan 兄弟之间不工作（真机实测：指向其它容器或公网地址一律超时，
    # 只有指向本机地址能用），而且一旦目标不可达客户端 DNS 就整个断掉。
    # 改成在本地起解析器后，DNS 永远有一个在场的应答者，选错上游最多是
    # 解析慢或拿到真实 IP，不会"全网 DNS 黑洞"。
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
