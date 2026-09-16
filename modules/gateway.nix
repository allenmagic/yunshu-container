{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.yunshu.container;
  g = config.yunshu.container.gateway;
in
{
  # 宿主侧 options：由部署方（main-router.nix）设置，与 side-router 对齐
  options.yunshu.container.gateway = {
    floatIp = mkOption {
      type = types.str;
      default = "192.168.10.1";
      description = ''
        VRRP 浮动 IP：本容器持有（MASTER），不可用时由 side-router 接管
        （BACKUP）。下游设备的默认网关与 DNS 都指它，必须与 side-router
        的 keepalived 配置以及 dnsmasq 下发的 option 3/6 完全一致。
      '';
    };

    vrrpId = mkOption {
      type = types.int;
      default = 51;
      description = "VRRP virtual_router_id, shared with the BACKUP node.";
    };

    authPass = mkOption {
      type = types.str;
      default = "aio-vrrp";
      description = ''
        VRRP 认证口令，与 BACKUP 一致。VRRPv2 的认证字段只有 8 字节，超长的
        部分会被悄悄截断；且 PASS 认证是明文，不提供实际安全性。
      '';
    };

    priority = mkOption {
      type = types.int;
      default = 100;
      description = ''
        VRRP priority of this (MASTER) node. The BACKUP node must use a lower
        value; a track_script lowers this one further to trigger failover.
      '';
    };

    unicastPeers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "192.168.10.3" ];
      description = ''
        Peers for VRRP unicast instead of multicast. Recommended when the nodes
        are macvlan siblings on the same parent interface: it drops the
        dependency on the kernel replicating 224.0.0.18 between macvlan
        sub-interfaces, which is the usual way these setups fail silently.
      '';
    };

    unicastSrcIp = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "192.168.10.2";
      description = ''
        Source address for VRRP unicast adverts. Set it together with
        unicastPeers: on a router with a LAN and a WAN interface, keepalived
        would otherwise pick the source by route lookup and could send adverts
        out of the wrong interface.
      '';
    };

    trackTunnel = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Track the YunShu tunnel with a health check and drop the VRRP priority
        when it fails, so the BACKUP takes the VIP over (degrading to direct).

        The probe is TCP, never ICMP: many commercial VPN TUNs do not forward
        ICMP, so a ping-based check would judge a perfectly healthy tunnel dead
        and drift the whole LAN onto the unprotected direct path.

        Requires tunnelTrackWeight to be larger in magnitude than the gap
        between this node's priority and the BACKUP's, otherwise the lowered
        priority still wins and no failover happens.
      '';
    };

    tunnelProbeUrl = mkOption {
      type = types.str;
      default = "http://www.gstatic.com/generate_204";
      description = ''
        URL probed through tun0 when trackTunnel is enabled. Use a domain that
        is actually proxied — that is what exercises the fake-IP route; probing
        a direct-only domain would pass even with the tunnel down.
      '';
    };

    tunnelTrackWeight = mkOption {
      type = types.int;
      default = -30;
      description = ''
        Priority delta applied when the tunnel health check fails. Must bring
        this node's effective priority below the BACKUP's, e.g. with priority
        100 and a BACKUP at 90, -30 lands on 70 and triggers the failover.
      '';
    };
  };

  # 注入容器的配置片段。
  # 放在 _guestConfig 而不是顶层 config：这些是**容器内**的选项（keepalived、
  # nftables、firewall 都在容器里跑），而上面的 options 必须在宿主求值才能被
  # 部署方设置——两个求值上下文不同，见 container.nix 的说明。
  config.yunshu.container._guestConfig = {
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = true;
      "net.ipv6.conf.all.forwarding" = true;
      "net.ipv4.conf.all.rp_filter" = 0;
      "net.ipv4.conf.default.rp_filter" = 0;
      "net.ipv4.conf.all.send_redirects" = 0;
      "net.ipv4.conf.default.send_redirects" = 0;
    };

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
        tcp flags syn tcp option maxseg size set rt mtu   # 隧道下防 PMTUD 黑洞
        iifname "${cfg.lanInterface}" accept
        iifname "tun0" accept
        limit rate 10/minute log prefix "FORWARD_DROP: " drop
      '';

      # VRRP 心跳是 IP protocol 112，不是 TCP/UDP——NixOS 防火墙的 input 链默认
      # drop 且不会为它生成任何放行规则，容器会静默收不到对端心跳。
      # 单机双容器（两个 macvlan 兄弟）场景下尤其致命：双方都只能靠"听不到更
      # 高优先级"维持状态，出现双 MASTER 时谁也不会退让。
      extraInputRules = ''
        ip protocol 112 accept comment "VRRP"
      '';
    };

    # 透明网关自己接管 DNS：把 LAN 侧的 53 查询 DNAT 到隧道 DNS，
    # 这是 fake-IP 分流的入口，不能关。
    # interface 必须在这里从宿主侧 option 传进去——dns 模块在容器内求值，
    # 读不到 yunshu.container.*（见 dns.nix 里该 option 的说明）。
    services.yunshu.dns.enable = mkDefault true;
    services.yunshu.dns.transparentRedirect = mkDefault true;
    services.yunshu.dns.interface = cfg.lanInterface;

    services.keepalived = {
      enable = true;

      vrrpScripts = mkIf g.trackTunnel {
        chkTun = {
          script = "${pkgs.curl}/bin/curl -sf -o /dev/null --max-time 2 --interface tun0 ${g.tunnelProbeUrl}";
          interval = 3;
          timeout = 2;
          weight = g.tunnelTrackWeight;
          fall = 1;  # 一次失败立刻降权，缩短启动期 DNS 黑洞窗口
          rise = 3;
          # 默认的 keepalived_script 用户 NixOS 并不创建，keepalived 会告警并
          # 回退到运行用户；显式写 root 免得行为随版本变动。
          user = "root";
        };
      };

      vrrpInstances.LAN = {
        state = "MASTER";
        interface = cfg.lanInterface;
        virtualRouterId = g.vrrpId;
        priority = g.priority;
        virtualIps = [ { addr = "${g.floatIp}/24"; } ];
        trackScripts = optional g.trackTunnel "chkTun";
        # 单播与 nopreempt 用模块原生 option，不要手写 extraConfig 拼字符串：
        # 少一层拼接就少一类"渲染出来格式不对但求值不报错"的故障。
        inherit (g) unicastSrcIp;
        unicastPeers = g.unicastPeers;
        extraConfig = ''
          advert_int 1
          authentication {
            auth_type PASS
            auth_pass ${g.authPass}
          }
        '';
      };
    };
  };
}
