{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.yunshu;

  payloadSrc = builtins.path {
    name = "yunshu-headless-payload";
    path = cfg.package;
    filter = path: type:
      type == "directory"
      || builtins.elem
        (removePrefix (toString cfg.package + "/") (toString path))
        [
          "opt/apps/yunshu/files/bin/yunshu"
          "opt/apps/yunshu/files/bin/yunshu-daemon"
          "opt/apps/yunshu/files/bin/yunshu-updater"
          "opt/apps/yunshu/files/bin/libtunnel.so"
          "opt/apps/yunshu/files/bin/exec/executor"
          "opt/apps/yunshu/files/system/yunshu-daemon.service"
          "opt/apps/yunshu/files/system/yunshu-updater.service"
          "opt/apps/yunshu/files/config/version.ini"
        ];
  };

  runtimePackage = pkgs.stdenvNoCC.mkDerivation {
    name = "yunshu-headless-2.3.10.30";
    src = payloadSrc;
    dontUnpack = true;
    # autoPatchelfHook：自动修 interpreter（NixOS glibc loader）并为所有
    # 动态库依赖设 rpath。buildInputs 提供 .deb 二进制所需的库（zlib 等）。
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [
      pkgs.glibc
      pkgs.zlib
      pkgs.libgcc        # libgcc_s.so.1（autoPatchelf 报缺）
    ];

    installPhase = ''
      mkdir -p "$out/opt/apps/yunshu/files"
      cp -a "${payloadSrc}/opt/apps/yunshu/files/bin" "$out/opt/apps/yunshu/files/bin"
      cp -a "${payloadSrc}/opt/apps/yunshu/files/system" "$out/opt/apps/yunshu/files/system"

      mkdir -p "$out/opt/apps/yunshu/files/config"
      cp "${payloadSrc}/opt/apps/yunshu/files/config/version.ini" \
        "$out/opt/apps/yunshu/files/config/version.ini"

      chmod 0755 \
        "$out/opt/apps/yunshu/files" \
        "$out/opt/apps/yunshu/files/bin" \
        "$out/opt/apps/yunshu/files/bin/yunshu" \
        "$out/opt/apps/yunshu/files/bin/yunshu-daemon" \
        "$out/opt/apps/yunshu/files/bin/yunshu-updater" \
        "$out/opt/apps/yunshu/files/bin/exec/executor"
      chmod 0644 "$out/opt/apps/yunshu/files/bin/libtunnel.so"

      # .deb 二进制的 interpreter 是 /lib64/ld-linux（NixOS stub-ld 占位），
      # autoPatchelfHook 在 postFixup 自动改到本机 glibc loader 并设 rpath
      #（bin 目录 + zlib/glibc）。libtunnel.so 在 bin 同目录，rpath 覆盖。
    '';
  };

  binDir = "${runtimePackage}/opt/apps/yunshu/files/bin";
  systemDir = "${runtimePackage}/opt/apps/yunshu/files/system";
  stateDir = "/var/lib/yunshu";

  yunshuCli = pkgs.writeShellScriptBin "yunshu" ''
    exec ${binDir}/yunshu "$@"
  '';

  initScript = ''
    mkdir -p \
      /opt/apps/yunshu/files \
      ${stateDir}/{config,socket,tmp,bak,logs,login-www}

    : > ${stateDir}/login-www/login-url.txt
    printf '%s\n' '{"url":"","status":"waiting","detail":""}' \
      > ${stateDir}/login-www/status.json
    printf '%s\n' \
      '<!doctype html>' \
      '<html lang="zh-CN">' \
      '<meta charset="utf-8">' \
      '<meta http-equiv="refresh" content="3">' \
      '<title>YunShu 登录</title>' \
      '<body>' \
      '<h1>YunShu 登录</h1>' \
      '<p>状态：等待登录</p>' \
      '<p>正在获取登录链接，请稍候…</p>' \
      '</body>' \
      '</html>' \
      > ${stateDir}/login-www/index.html

    ln -sfn ${binDir} /opt/apps/yunshu/files/bin
    ln -sfn ${systemDir} /opt/apps/yunshu/files/system
    ln -sfn ${stateDir}/config /opt/apps/yunshu/files/config
    ln -sfn ${stateDir}/socket /opt/apps/yunshu/files/socket
    ln -sfn ${stateDir}/tmp /opt/apps/yunshu/files/tmp
    ln -sfn ${stateDir}/bak /opt/apps/yunshu/files/bak
    ln -sfn ${stateDir}/logs /opt/apps/yunshu/files/logs

    chmod 0755 \
      /opt/apps/yunshu/files \
      ${stateDir}/socket \
      ${stateDir}/tmp \
      ${stateDir}/bak \
      ${stateDir}/logs

    if [ ! -f ${stateDir}/config/version.ini ]; then
      cp "${runtimePackage}/opt/apps/yunshu/files/config/version.ini" \
        ${stateDir}/config/version.ini
    fi

    if [ ! -f ${stateDir}/config/private_ctl.conf ]; then
      printf '%s\n' "${cfg.spAddr}" > ${stateDir}/config/private_ctl.conf
    fi

    if [ ! -f ${stateDir}/config/app_config.json ]; then
      cat > ${stateDir}/config/app_config.json <<EOF
{
  "corpcode": "${cfg.corpCode}",
  "sp_addr": "${cfg.spAddr}"
}
EOF
    fi
  '';

  loginHelper = pkgs.writeScriptBin "yunshu-login-helper" ''
    #!${pkgs.bash}/bin/bash
    set -u

    state_dir="''${YUNSHU_STATE_DIR:-/var/lib/yunshu}"
    corp_code="''${YUNSHU_CORP_CODE:-}"
    bin_path="''${YUNSHU_BIN:-/opt/apps/yunshu/files/bin/yunshu}"

    www_dir="$state_dir/login-www"
    log_file="$state_dir/login.log"
    url_file="$www_dir/login-url.txt"
    status_file="$www_dir/status.json"
    index_file="$www_dir/index.html"
    marker="$state_dir/config/.logged-in"

    mkdir -p "$www_dir" "$state_dir/config"
    : > "$url_file"

    html_escape() {
      printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
    }

    json_escape() {
      printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
    }

    write_status() {
      status="$1"
      detail="$2"
      url="$3"
      url_json="$(json_escape "$url")"
      printf '{"url":"%s","status":"%s","detail":"%s"}\n' \
        "$url_json" "$status" "$detail" > "$status_file"
    }

    render_page() {
      status="$1"
      url="$2"

      if [ -n "$url" ]; then
        url_attr="$(html_escape "$url")"
        link_open="<p><a href=\"$url_attr\">打开飞书 SSO 登录页</a></p>"
        link_code="<p><code>$url_attr</code></p>"
      else
        link_open="<p>正在获取登录链接，请稍候…</p>"
        link_code=""
      fi

      case "$status" in
        authenticated) status_text="登录成功" ;;
        error) status_text="登录失败" ;;
        *) status_text="等待登录" ;;
      esac

      printf '%s\n' \
        '<!doctype html>' \
        '<html lang="zh-CN">' \
        '<meta charset="utf-8">' \
        '<meta http-equiv="refresh" content="3">' \
        '<title>YunShu 登录</title>' \
        '<body>' \
        '<h1>YunShu 登录</h1>' \
        "<p>状态：$status_text</p>" \
        "$link_open" \
        "$link_code" \
        '<hr>' \
        '<p>完成飞书 SSO 后，本页会自动刷新；容器拿到 token 后会显示登录成功。</p>' \
        '</body>' \
        '</html>' \
        > "$index_file"
    }


    write_status waiting "" ""
    render_page waiting ""

    url=""
    printf '1\n' | "$bin_path" -c "$corp_code" -l 2>&1 | while IFS= read -r line; do
      printf '%s\n' "$line" >> "$log_file"
      printf '%s\n' "$line"

      if [ ! -s "$url_file" ]; then
        candidate="$(printf '%s\n' "$line" | grep -Eo 'https?://[^[:space:]]+' | head -n1 || true)"
        if [ -n "$candidate" ]; then
          printf '%s\n' "$candidate" > "$url_file"
          write_status waiting "" "$candidate"
          render_page waiting "$candidate"
        fi
      fi
    done
    yunshu_rc="''${PIPESTATUS[1]:-1}"
    url="$(cat "$url_file" 2>/dev/null || true)"

    if [ "$yunshu_rc" -eq 0 ]; then
      touch "$marker"
      write_status authenticated "yunshu login succeeded" "$url"
      render_page authenticated "$url"
    else
      write_status error "yunshu exited with $yunshu_rc" "$url"
      render_page error "$url"
    fi

    sleep 3
    exit "$yunshu_rc"
  '';

in
{
  options.services.yunshu = {
    enable = mkEnableOption "YunShu headless daemon and updater";

    package = mkOption {
      type = types.path;
      default = ../dist/yunshu-headless;
      description = ''
        Directory containing the stripped headless payload, i.e.
        dist/yunshu-headless from the original unpacked .deb.
      '';
    };

    corpCode = mkOption {
      type = types.str;
      default = "cpe";
      description = "YunShu corporate/enterprise code.";
    };

    spAddr = mkOption {
      type = types.str;
      default = "https://sp.eagleyun.cn/";
      description = "YunShu private SP endpoint.";
    };

    loginOnStart = mkOption {
      type = types.bool;
      default = true;
      description = "Attempt Feishu/SMS login at boot; URL is visible in the journal.";
    };

    loginHttpListen = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = "Address for the lightweight login status HTTP server.";
    };

    loginHttpPort = mkOption {
      type = types.port;
      default = 8080;
      description = "Port for the lightweight login status HTTP server.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ yunshuCli ];

    networking.firewall.allowedTCPPorts = optionals cfg.loginOnStart [ cfg.loginHttpPort ];

    systemd.services.yunshu-init = {
      description = "Prepare YunShu headless runtime state";
      wantedBy = [ "multi-user.target" ];
      before = [ "yunshu-daemon.service" "yunshu-updater.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = initScript;
    };

    systemd.services.yunshu-daemon = {
      description = "YunShu headless daemon";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "yunshu-init.service" ];
      wants = [ "network-online.target" ];
      requires = [ "yunshu-init.service" ];
      serviceConfig = {
        # 前台运行（无 -d daemonize）：systemd Type=simple 直接管理，避免
        # daemonize 后主进程退出被误判 deactivated、子进程无人照看
        ExecStart = "${binDir}/yunshu-daemon";
        Restart = "on-failure";
        RestartSec = 5;
        WorkingDirectory = stateDir;
        LimitNOFILE = 65536;
        AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_RAW" "CAP_SYS_ADMIN" ];
      };
    };

    # 隧道路由注入：yunshu 桌面版会自动把隧道虚拟网段（被墙域名解析到的
    # fake-IP）路由到 tun0，headless 版缺失。实测 fake-IP 落在 198.18.0.0/15
    # 网段内（连接 pa/ga 前落 198.18.x、连接后落 198.19.x），故加 198.18.0.0/15
    # 覆盖整个 RFC 2544 fake-IP 池。此服务持续循环：tun0 一出现就加（隧道可能
    # 开机后手动/延迟连接，故不设超时）。
    systemd.services.yunshu-routes = {
      description = "Add tunnel routes to tun0 whenever it appears";
      wantedBy = [ "multi-user.target" ];
      after = [ "yunshu-daemon.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = let
          routeScript = pkgs.writeShellScript "yunshu-add-routes" ''
            set -eu
            IP=${pkgs.iproute2}/bin/ip
            while true; do
              if "$IP" link show tun0 >/dev/null 2>&1; then
                "$IP" route replace 198.18.0.0/15 dev tun0 2>/dev/null || true
              fi
              sleep 3
            done
          '';
        in "${routeScript}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.services.yunshu-updater = {
      description = "YunShu headless updater";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "yunshu-daemon.service" "yunshu-init.service" ];
      wants = [ "network-online.target" ];
      requires = [ "yunshu-init.service" ];
      serviceConfig = {
        ExecStart = "${binDir}/yunshu-updater";
        Restart = "on-failure";
        RestartSec = 5;
        WorkingDirectory = stateDir;
        LimitNOFILE = 65536;
      };
    };

    systemd.services.yunshu-login-http = mkIf cfg.loginOnStart {
      description = "YunShu SSO login status HTTP server";
      partOf = [ "yunshu-login.service" ];
      after = [ "yunshu-init.service" ];
      requires = [ "yunshu-init.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.darkhttpd}/bin/darkhttpd ${stateDir}/login-www --port ${toString cfg.loginHttpPort} --addr ${cfg.loginHttpListen} --no-listing --no-server-id --log ${stateDir}/login-http.log";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.services.yunshu-login = mkIf cfg.loginOnStart {
      description = "YunShu headless login";
      wantedBy = [ "multi-user.target" ];
      after = [ "yunshu-daemon.service" "yunshu-updater.service" "yunshu-login-http.service" ];
      requires = [ "yunshu-login-http.service" ];
      unitConfig.ConditionPathExists = "!${stateDir}/config/.logged-in";
      environment = {
        YUNSHU_CORP_CODE = cfg.corpCode;
        YUNSHU_BIN = "${binDir}/yunshu";
        YUNSHU_STATE_DIR = stateDir;
      };
      serviceConfig = {
        Type = "simple";
        ExecStart = "${loginHelper}/bin/yunshu-login-helper";
        Restart = "on-failure";
        RestartSec = 10;
        WorkingDirectory = stateDir;
      };
    };

    # pa/ga 连接：登录态持久（token 在 /var/lib/yunshu），但 pa/ga 连接在容器
    # 重启后会断——yunshu-daemon 只建空壳 tun0，不会自动重连 pa/ga。此服务持续
    # 循环：已登录（.logged-in 存在）但连接断开（yunshu -i 含「已断开」）时执行
    # yunshu -s all 重连，覆盖「已登录 + 容器重启」与「连接中途断开」两种场景。
    systemd.services.yunshu-connect = {
      description = "YunShu pa/ga auto-connect after login";
      wantedBy = [ "multi-user.target" ];
      after = [ "yunshu-daemon.service" "yunshu-updater.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = let
          connectScript = pkgs.writeShellScript "yunshu-connect" ''
            set -eu
            BIN="${binDir}/yunshu"
            MARK="${stateDir}/config/.logged-in"
            while true; do
              if [ -f "$MARK" ]; then
                if "$BIN" -i 2>&1 | grep -q "已断开"; then
                  "$BIN" -s all || true
                fi
              fi
              sleep 15
            done
          '';
        in "${connectScript}";
        Restart = "on-failure";
        RestartSec = 10;
        WorkingDirectory = stateDir;
      };
    };
  };
}
