# VRRP 与 DNS 故障转移方案

## 背景

`yunshu-nix` 的 `gateway` 模式作为 VRRP MASTER，负责透明网关和 DNS 分流。
主路由 VM（router-image）作为 VRRP BACKUP，平时提供 DHCP 和普通 NAT 逃生路径。

如果 DHCP 继续把客户端 DNS 下发为路由器自身 IP（`192.168.10.1`），
DNS 请求不会进入 yunshu 容器，YunShu 的域名分流会失效。

同时，如果把 DHCP DNS 简单改为 VRRP 浮动 IP，但 Backup 节点上没有 DNS 服务，
那么容器故障、VRRP 漂移回路由器后，客户端虽然仍指向 VRRP，却无法解析域名。

## 结论

采用“双角色 DNS”：

- 正常状态：DNS 指向 VRRP，由 yunshu 容器接管并做策略分流。
- 故障状态：VRRP 漂移回路由器，dnsmasq 以 `bind-dynamic` 自动监听 VRRP，
  提供普通公网 DNS 逃生。

## 网络链路

```text
正常：
  客户端 DNS -> 192.168.10.254 (VRRP，在 yunshu 容器)
             -> 容器 nftables DNAT
             -> 127.0.0.1:53
             -> YunShu DNS / 分流

容器故障：
  VRRP 192.168.10.254 漂移到 router-image
             -> dnsmasq bind-dynamic
             -> 223.5.5.5 / 223.6.6.6 / 119.29.29.29 / 182.254.116.116
```

## yunshu-nix 侧要求

`gateway` 模式默认应保持：

```nix
services.yunshu.dns.enable = true;
services.yunshu.dns.transparentRedirect = true;
services.yunshu.dns.listen = "127.0.0.1";
services.yunshu.dns.port = 53;
```

其中 `listen` 是 YunShu 本地 DNS listener，不是对 LAN 暴露的地址；
53 端口透明重定向负责把进入容器的 VRRP DNS 流量 DNAT 到本地 listener。

## router-image 侧修改

需要同步修改以下 dnsmasq 文件：

- `base/dnsmasq.conf`
  - 保持 `bind-dynamic`，保证 VRRP 漂移回本机时 dnsmasq 能监听浮动地址。
- `base/dnsmasq.d/10-dhcp-eth1.conf`
  - DHCP DNS 从 `__LAN_IP__` 改为 `__LAN_GATEWAY__`。
- `base/dnsmasq.d/20-upstream-dns.conf`
  - 增加 `no-resolv`，固定 fallback 上游 DNS。
- `base/dnsmasq.d/AGENTS.md`
  - 更新约定，说明 dnsmasq 只是 fallback DNS，不允许把上游指向 VRRP 自身。

## 反模式

不要使用：

```ini
# 这会在本 VM 接管 VRRP 后把 DNS 查询送回自己，可能形成回环
server=192.168.10.254
```

也不要在 dnsmasq 中关闭 DNS：

```ini
# 禁止：容器故障后没有 fallback DNS
port=0
```

## 验证清单

1. 容器正常时：

```sh
ip addr show eth1 | grep 192.168.10.254
ss -lunp | grep :53
ss -ltnp | grep :53
```

应看到 VRRP 在容器上，且 YunShu DNS 监听在 `127.0.0.1:53`。

2. 模拟容器故障后：

- VRRP `192.168.10.254` 应出现在 router-image 的 LAN 接口上。
- dnsmasq 应能响应 `192.168.10.254:53`。
- 客户端使用普通公网 DNS 仍可解析，但不再有 YunShu 策略分流。
