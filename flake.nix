{
  description = "YunShu 透明网关容器（macvlan 接入 + VRRP 浮动网关）";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
    nixosModules = {
      yunshu-headless = ./modules/yunshu-headless.nix;
      dns = ./modules/dns.nix;

      # 在 NixOS host 上 import 这个模块，声明并启用网关容器。
      # guest 内复用 headless 与 dns 模块；容器自己的 LAN 地址、WAN DHCP、
      # resolv.conf 由部署方通过 yunshu.container.guestModule 补充——
      # 那些信息模块无法从外部推断。
      container = {
        imports = [ ./modules/container.nix ];

        yunshu.container.enable = true;
        yunshu.container.guestModule = {
          imports = [
            self.nixosModules.yunshu-headless
            self.nixosModules.dns
          ];

          system.stateVersion = "26.11";
          services.yunshu.enable = true;
        };
      };
    };
  };
}
