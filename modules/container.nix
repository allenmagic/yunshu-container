{ config, lib, ... }:

with lib;

let
  cfg = config.yunshu.container;

  # 注：不在此用 environment.etc 设 machine-id —— 那会生成指向 ro store 的
  # 符号链接，NixOS 容器启动 touch /etc/machine-id 报 Read-only file system。
  # 让容器 bootstrap 生成可写 machine-id（persistState 下登录态在
  # /var/lib/yunshu 持久，不受 machine-id 变更影响）。
  #
  # 容器自身的 /etc/resolv.conf 也不在这里写：登录 YunShu 要先把控制面域名
  # 解析出来，那个时刻隧道还没起来，解析路径必须有一条不依赖隧道的兜底——
  # 由 guestModule 提供（见 main-router.nix）。
  identityConfig = {
    networking.hostName = cfg.hostname;
    networking.resolvconf.enable = lib.mkForce false;
  };

  # MAC 固定。nspawn 每次创建容器接口都会生成随机 MAC，必须钉死：否则 DHCP
  # 租约随重建漂移、VRRP 对端把本节点当新设备、上游按 MAC 绑定时直接失效。
  #
  # 必须用 .link（systemd.network.links）：它由 udev 直接读取，容器里没有跑
  # networkd 也生效。写成 .network（systemd.network.networks）是无效的——
  # 那种文件只有 networkd 会读，而 NixOS 容器默认不开 networkd，
  # 结果是配置看着齐全、MAC 实际仍是随机的。
  #
  # 前缀 10- 是刻意的：scripted 网络后端会为**每个**在 networking.interfaces
  # 里声明过的接口自动生成 `40-<接口名>` 的 .link（匹配 OriginalName，写
  # MACAddress/MTUBytes），而 udev 对同一接口**只应用文件名排序最靠前的那个
  # .link**。用 10- 保证本模块的设置优先，并且不依赖消费者是否在 guestModule
  # 里声明过这些接口。
  macConfig = {
    systemd.network.links = mapAttrs' (iface: mac: nameValuePair "10-${iface}" {
      matchConfig.Name = iface;
      linkConfig.MACAddress = mac;
    }) cfg.macAddresses;
  };
in
{
  imports = [ ./gateway.nix ];

  options.yunshu.container = {
    enable = mkEnableOption "YunShu 透明网关容器（macvlan 接入的 VRRP 网关）";

    name = mkOption {
      type = types.str;
      default = "yunshu-router";
      description = "Name of the NixOS container.";
    };

    hostname = mkOption {
      type = types.str;
      default = "yunshu-router";
      description = "Fixed hostname inside the container (stable device identity).";
    };

    machineId = mkOption {
      type = types.str;
      default = "5212e91dae029bf58f9beffe3402c288";
      description = "Fixed systemd machine-id (32 lowercase hex chars, no dashes).";
    };

    macvlans = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "lan0:eth0"
        "wan0:eth1"
      ];
      description = ''
        macvlan 接入列表，格式 "<宿主接口>:<容器内接口名>"，原样透传给
        containers.<name>.macvlans（systemd-nspawn 的 --network-macvlan=）。

        冒号后半段是容器内的名字，**不能省略**：省略时 nspawn 会把容器内接口
        命名成 mv-<宿主接口>，与 keepalived / DNS 透明重定向里写的 eth0 对不上，
        而且不会报任何错（有断言挡着）。
      '';
    };

    macAddresses = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        eth0 = "02:00:00:02:00:11";
        eth1 = "02:00:00:02:00:12";
      };
      description = ''
        按容器内接口名固定 MAC，macvlans 里出现的每个接口都必须有对应项。
        随机 MAC 会让 DHCP 租约随重建漂移、上游按 MAC 绑定时直接失效。
      '';
    };

    lanInterface = mkOption {
      type = types.str;
      default = "eth0";
      description = "容器内的 LAN 侧接口名（VRRP 绑 VIP、DNS 透明重定向都认它）。";
    };

    wanInterface = mkOption {
      type = types.str;
      default = "eth1";
      description = "容器内的 WAN 侧接口名（出网口，masquerade 打在这个口上）。";
    };

    persistState = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Persist the container root filesystem, including /var/lib/yunshu login
        tokens. Disable only for stateless/throwaway instances.
      '';
    };

    guestModule = mkOption {
      type = types.deferredModule;
      description = ''
        NixOS module evaluated inside the container. This is where the deployer
        declares the LAN address, the WAN DHCP client, and the container's own
        resolver — none of which the module can infer from outside.
      '';
    };

    _guestConfig = mkOption {
      type = types.attrs;
      internal = true;
      default = { };
      description = ''
        网关模块贡献的 guest 配置片段。

        存在的理由：yunshu.container.gateway.* 是**宿主侧** option（要在宿主
        求值，才能被 main-router.nix 设置），而它产生的 nftables/keepalived
        配置必须注入**容器内**。两者不在同一个求值上下文，只能由这里搭桥。
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.macvlans != [ ];
        message = "yunshu.container.macvlans 不能为空——本模块只支持 macvlan 接入。";
      }
      {
        assertion = all (m: hasInfix ":" m) cfg.macvlans;
        message = ''
          yunshu.container.macvlans 每一项都要写成 "<宿主接口>:<容器内接口名>"。
          省略冒号后半段的话，nspawn 会把容器内接口命名成 mv-<宿主接口>，
          与 keepalived / DNS 透明重定向里写的 eth0 对不上，且不报任何错。
        '';
      }
      {
        # MAC 漂移不会报错，只表现为"上网行为诡异"：DHCP 租约变、上游按 MAC
        # 绑定时直接失效、VRRP 对端把本节点当成新设备。挡在求值期最划算。
        assertion = all (i: hasAttr i cfg.macAddresses) (map (m: last (splitString ":" m)) cfg.macvlans);
        message = "yunshu.container.macAddresses 缺少 macvlans 中列出的容器内接口——每个 macvlan 接口都要固定 MAC。";
      }
    ];

    containers.${cfg.name} = {
      autoStart = true;
      privateNetwork = true;
      enableTun = true;
      ephemeral = !cfg.persistState;
      macvlans = cfg.macvlans;
      config = mkMerge [
        cfg.guestModule
        cfg._guestConfig
        identityConfig
        macConfig
      ];
    };
  };
}
