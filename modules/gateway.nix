{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.yunshu.container;
  g = config.yunshu.container.gateway;
in
{
  # 宿主侧 options：由部署方（main-router.nix）设置。
  options.yunshu.container.gateway = {
    address = mkOption {
      type = types.str;
      default = "192.168.10.1";
      example = "192.168.10.1";
      description = ''
        本容器在 LAN 侧的地址，同时也是下游客户端使用的**网关与 DNS 地址**
        （由 dnsmasq 通过 DHCP option 3/6 下发）。

        本模块据此设置接口地址并生成 DNS 重定向规则，所以不要同时在
        guestModule 里再写一份 networking.interfaces.*.ipv4.addresses
        ——两处不一致时 DNS 会静默失效。
      '';
    };

    dnsFallback = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "192.168.10.7";
      description = ''
        隧道不可用时把客户端 DNS 转给谁（通常是 dnsmasq 容器的地址）。
        null = 不降级，隧道没连上时客户端 DNS 直接黑洞。

        这是"网关只有一台"之后唯一的降级逻辑：以前靠 BACKUP 节点接管 VIP
        来换 DNS 路径，现在改成本容器内换一条 DNAT 目标。
      '';
    };
  };

  # 注入容器的配置片段。
  # 放在 _guestConfig 而不是顶层 config：这些是**容器内**的选项（nftables、
  # firewall 都在容器里跑），而上面的 options 必须在宿主求值才能被部署方
  # 设置——两个求值上下文不同，见 container.nix 的说明。
  config.yunshu.container._guestConfig = {
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = true;
      "net.ipv6.conf.all.forwarding" = true;
      "net.ipv4.conf.all.rp_filter" = 0;
      "net.ipv4.conf.default.rp_filter" = 0;
      "net.ipv4.conf.all.send_redirects" = 0;
      "net.ipv4.conf.default.send_redirects" = 0;
    };

    # LAN 地址由本模块唯一持有：它既是接口地址，也是 DNS 重定向规则的匹配目标，
    # 分成两处写迟早会漂。
    networking.interfaces.${cfg.lanInterface}.ipv4.addresses = [
      {
        address = g.address;
        prefixLength = 24;
      }
    ];

    networking.nftables.enable = true;

    # SNAT/masquerade：下游设备直连流量出 WAN 口时，把源地址改成容器自身
    #（它自己的 WAN 地址），否则回包从上游直接绕回下游设备、绕开本容器 →
    # 非对称路由丢包。隧道流量（走 tun0）由 yunshu 隧道自身处理，不需 masquerade。
    networking.nftables.tables.yunshu-snat = {
      family = "ip";
      content = ''
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          oifname "${cfg.wanInterface}" masquerade
        }
      '';
    };

    networking.firewall = {
      filterForward = true;
      extraForwardRules = ''
        tcp flags syn tcp option maxseg size set rt mtu
        iifname "${cfg.lanInterface}" accept
        iifname "tun0" accept
      '';
    };

    # 透明网关自己接管 DNS：把 LAN 侧的 53 查询 DNAT 到隧道 DNS，
    # 这是 fake-IP 分流的入口，不能关。
    # interface / vip / fallback 必须在这里从宿主侧 option 传进去——dns 模块在
    # 容器内求值，读不到 yunshu.container.*（见 dns.nix 里该 option 的说明）。
    services.yunshu.dns.enable = mkDefault true;
    services.yunshu.dns.transparentRedirect = mkDefault true;
    services.yunshu.dns.interface = cfg.lanInterface;
    services.yunshu.dns.vip = g.address;
    services.yunshu.dns.fallbackServer = g.dnsFallback;
  };
}
