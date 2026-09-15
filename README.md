# yunshu-nix

把 `YunShu_2.3.10.30_cpe.deb` 剥离 GUI 后的 headless 后台服务，跑在一个
NixOS declarative container 里。默认以 `gateway` 模式接入局域网，复用 YunShu
自带的 TUN 分流；也可以切换到 `private_proxy` 模式，用 3proxy 暴露代理服务。

详细部署、登录、排障和备份说明见 [docs/使用手册.md](./docs/使用手册.md)。

## 默认配置

- 运行时 payload 来自 `dist/yunshu-headless/`
- 默认模式：`mode = "gateway"`，容器作为局域网默认网关，直接复用 YunShu TUN 分流
- 可选代理模式：`mode = "private_proxy"` 时启用 `3proxy`，监听 `0.0.0.0:7890`
- DNS：`gateway` 模式默认接管 53 端口，可通过 `services.yunshu.dns` 单独关闭
- 网络模式：`bridge`，容器拥有独立局域网 IP
- 容器 root 文件系统默认持久化，登录 token 落在容器内 `/var/lib/yunshu`

## 目录结构

```text
flake.nix
modules/
  container.nix          # 容器公共选项 + mode 分发器
  yunshu-headless.nix    # yunshu 运行时 + systemd 服务 + 登录服务
  proxy.nix              # 3proxy 基础能力，不是 mode
  dns.nix                # DNS 独立配置
  modes/
    gateway.nix          # 透明网关 + keepalived/VRRP + 转发
    private-proxy.nix    # 内网 3proxy
    public-proxy.nix     # 公网 3proxy，认证/ACL 基础实现
    tproxy.nix           # tproxy 预留模式
examples/
  container-flake.nix    # 在现有 NixOS host 上导入该容器的完整示例
docs/
  使用手册.md
```

## 在现有 NixOS host 上部署

完整示例见 [`examples/container-flake.nix`](./examples/container-flake.nix)。
最小配置：

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    yunshu-router = {
      url = "path:/home/allenmagic/Projects/yunshu-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, yunshu-router, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        yunshu-router.nixosModules.container

        {
          networking.hostName = "router-host";

          # 宿主机需要先有 br0 bridge。
          networking.bridges.br0.interfaces = [ "eth0" ];
          networking.interfaces.br0.useDHCP = true;

          yunshu.container = {
            enable = true;
            mode = "gateway";
            networkMode = "bridge";
            bridge = "br0";
            lanAddress = "192.168.10.3/24";
          };
        }
      ];
    };
  };
}
```

重建 host：

```sh
sudo nixos-rebuild switch --flake .#host
```

局域网设备把默认网关指向容器 IP：

```text
192.168.10.3
```

`gateway` 模式默认会透明接管 53 端口；如果显式关闭了 DNS 接管，则建议通过 DHCP 把客户端 DNS 指向容器。

## 容器网络

`modules/container.nix` 提供 `bridge` 和 `nat` 两种接入模式，默认是 `bridge`。
`gateway` 模式要求使用 `bridge`。

### gateway 模式（默认）

```nix
yunshu.container = {
  enable = true;
  mode = "gateway";
  networkMode = "bridge";
  bridge = "br0";
  lanAddress = "192.168.10.3/24";
};
```

网关模式会在容器内开启 IP 转发、关闭 ICMP redirect、放行 `eth0 <-> tun0`
转发，并关闭独立的 7890 代理。局域网设备只需把默认网关指向容器 LAN IP。

### bridge 网络模式

容器 eth0 直接接入宿主机已有 bridge，并获得独立局域网 IP：

```nix
yunshu.container = {
  enable = true;
  networkMode = "bridge";
  bridge = "br0";
  lanAddress = "192.168.10.3/24";
};
```

宿主机需要提前配置 bridge。虽然宿主机 IP/NAT 故障时容器仍可能工作，但物理网卡
或 bridge 本身失效时容器也会断。

### private_proxy + nat

如果暂时不能建 bridge，可以用私有 veth + 端口转发：

```nix
yunshu.container = {
  enable = true;
  mode = "private_proxy";
  networkMode = "nat";
  hostAddress = "10.100.0.1";
  localAddress = "10.100.0.2";
  forwardProxy = true;
  proxyPort = 7890;
};
```

## 登录与状态持久化

`yunshu-headless.nix` 会启动：

- `yunshu-init.service`
- `yunshu-daemon.service`
- `yunshu-updater.service`
- 默认启用的 `yunshu-login.service`

登录状态保存在容器内的 `/var/lib/yunshu`。容器模块默认：

- `persistState = true`
- `ephemeral = false`

因此容器重启或宿主机重启后，登录 token、`config.db` 和缓存会保留，不会每次
都要求重新登录。

`yunshu-login.service` 登录成功后会在
`/var/lib/yunshu/config/.logged-in` 写标记；服务再次启动时会检查该标记，已经
登录过就不会重复跑交互式飞书流程。

首次登录或 token 过期时，在局域网浏览器打开：

```text
http://<容器IP>:8080
```

例如 gateway/bridge 模式下是 `http://192.168.10.3:8080`。页面会显示飞书 SSO
登录链接，完成登录后会自动刷新并显示“登录成功”。也可以继续从 journal 查看：

```sh
sudo journalctl -M yunshu-router -u yunshu-login -f
```

如果希望强制重新登录：

```sh
sudo nixos-container run yunshu-router -- \
  rm -f /var/lib/yunshu/config/.logged-in
sudo nixos-container run yunshu-router -- \
  systemctl restart yunshu-login
```

## 运行模式

`yunshu.container.mode` 是唯一入口，当前支持：

- `gateway`：透明网关，开启 IP 转发、keepalived/VRRP 浮动网关，并默认接管 DNS。
- `private_proxy`：面向可信内网的 3proxy，默认不认证、允许访问私网目标。
- `public_proxy`：面向不可信入口的 3proxy，默认使用来源 ACL（`iponly`）、拒绝私网目标，并要求配置 `publicProxy.allowFrom`。
- `tproxy`：预留的透明代理模式，当前会显式报未实现。

每个 mode 独立成文件，只启用自己拥有的服务；例如 `gateway` 会强制关闭
`services.yunshu.proxy`，而 `private_proxy` 会强制关闭 keepalived。这样不会出现
两个模式的服务同时生效。

DNS 不属于 mode，而是独立的 `services.yunshu.dns` 配置。`gateway` 默认
`enable = true` 且 `transparentRedirect = true`，两者都可以在 guestModule 中
显式关闭。

## 覆盖服务参数

```nix
yunshu.container.guestModule = {
  services.yunshu = {
    corpCode = "<企业码>";
    spAddr = "https://sp.eagleyun.cn/";
    loginOnStart = true;
  };

  # private_proxy 模式下代理参数生效（gateway 模式会强制关闭代理）
  services.yunshu.proxy = {
    listen = "0.0.0.0";
    listenPort = 7890;
  };

  # DNS 可以独立控制；gateway 模式默认开启，可在此显式关闭
  services.yunshu.dns = {
    enable = true;
    transparentRedirect = true;
  };
};
```

## 注意

- `yunshu` 安装路径被二进制硬编码为 `/opt/apps/yunshu`，模块通过
  `/opt/apps/yunshu/files` 下的符号链接映射到不可变 store 和可写
  `/var/lib/yunshu` 状态目录。
- 容器需要 `/dev/net/tun` 和 `CAP_NET_ADMIN`，`modules/container.nix` 已经通过
  `enableTun = true` 提供；宿主机内核仍需支持 `tun` 模块。
