{
  description = "Example NixOS host running YunShu in a declarative container";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # 本地项目；部署到其他机器时可替换为 git URL。
    yunshu-router = {
      url = "path:/home/allenmagic/Projects/yunshu-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, yunshu-router }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        yunshu-router.nixosModules.container

        {
          networking.hostName = "router-host";

          yunshu.container = {
            name = "yunshu-router";
            networkMode = "bridge";
            mode = "gateway";
            bridge = "br0";
            lanAddress = "192.168.10.3/24";
          };
        }
      ];
    };
  };
}
