# yunshu headless

从 `yunshu_cpe.deb` 剥离 GUI（Electron/Chromium）后的无界面后台服务 payload。

## 内容

- `opt/apps/yunshu/files/bin/yunshu`：CLI，负责登录/状态/连接控制
- `opt/apps/yunshu/files/bin/yunshu-daemon`：核心守护进程
- `opt/apps/yunshu/files/bin/yunshu-updater`：自动更新
- `opt/apps/yunshu/files/bin/libtunnel.so`：隧道引擎
- `opt/apps/yunshu/files/bin/exec/executor`：策略执行器
- `opt/apps/yunshu/files/config`：配置目录（安装时生成 app_config.json / private_ctl.conf）
- `opt/apps/yunshu/files/{socket,tmp,bak,logs}`：运行时目录

## 安装

```sh
sudo YUNSHU_CORP_CODE=<企业码> ./install.sh
```

可选 `YUNSHU_SP_ADDR` 指定私有化地址，默认 `https://sp.eagleyun.cn/`。

## 登录

```sh
./yunshu-login.sh <企业码>
```

飞书 SSO 需要浏览器或终端二维码完成一次交互，之后 token 会交给本机 daemon。

## 无 systemd

```sh
./supervise-run.sh
```
