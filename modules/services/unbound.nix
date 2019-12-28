{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.unbound;

  stateDir = "/var/db/unbound";

  access = concatMapStringsSep "\n  " (x: "access-control: ${x} allow") cfg.allowedAccess;

  interfaces = concatMapStringsSep "\n  " (x: "interface: ${x}") cfg.interfaces;

  isLocalAddress = x: substring 0 3 x == "::1" || substring 0 9 x == "127.0.0.1";

  forward =
    optionalString (any isLocalAddress cfg.forwardAddresses) ''
      do-not-query-localhost: no
    '' +
    optionalString (cfg.forwardAddresses != []) ''
      forward-zone:
        name: .
    '' +
    optionalString (cfg.forwardOverTLS) "    forward-tls-upstream: yes\n" +
    concatMapStringsSep "\n" (x: "    forward-addr: ${x}") cfg.forwardAddresses;

  rootTrustAnchorFile = "${stateDir}/root.key";

  trustAnchor = optionalString cfg.enableRootTrustAnchor
    "auto-trust-anchor-file: ${rootTrustAnchorFile}";

  includeFile = optionalString (cfg.includeFile != "")
    "include: \"${cfg.includeFile}\"";

  confFile = pkgs.writeText "unbound.conf" ''
    server:
      directory: "${stateDir}"
      username: unbound
      pidfile: ""
      chroot: ""
      tls-cert-bundle: "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ${interfaces}
      ${access}
      ${trustAnchor}
      ${includeFile}
    ${cfg.extraConfig}
    ${forward}
  '';

in
{
  options = {
    services.unbound.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to enable the unbound DNS resolver.";
    };

    services.unbound.allowedAccess = mkOption {
      default = ["127.0.0.0/8"];
      type = types.listOf types.str;
      description = "List of allowed networks that are allowed to query the resolver";
    };

    services.unbound.forwardAddresses = mkOption {
      type = types.listOf types.str;
      default = [];
      example = literalExample "[ \"8.8.8.8\" \"1.1.1.1\" ]";
      description = "List of resolvers to forward queries to";
    };

    services.unbound.enableRootTrustAnchor = mkOption {
      default = true;
      type = types.bool;
      description = "Use and update root trust anchor for DNSSEC validation";
    };

    services.unbound.forwardOverTLS = mkOption {
      default = false;
      type = types.bool;
      description = "Whether to forward DNS queries over TLS";
    };

    services.unbound.interfaces = mkOption {
      default = [];
      type = types.listOf types.str;
      description = "List of interfaces to listen on";
    };

    services.unbound.extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Extra unbound configuration";
    };

    services.unbound.includeFile = mkOption {
      type = types.path;
      default = "";
      description = "Include configuration from file";
    };
  };

  config = mkIf cfg.enable {

    assertions = [
      { assertion = elem "unbound" config.users.knownGroups; message = "set users.knownGroups to enable unbound group"; }
      { assertion = elem "unbound" config.users.knownUsers; message = "set users.knownUsers to enable unbound user"; }
    ];

    environment.systemPackages = [ pkgs.unbound ];

    users.users.unbound = {
      name = "unbound";
      home = stateDir;
      description = "Unbound user";
      uid = mkDefault 532;
      gid = mkDefault config.users.groups.unbound.gid;
    };

    users.groups.unbound = {
      name = "unbound";
      description = "Unbound user group";
      gid = mkDefault 532;
    };

    launchd.daemons.unbound = {
      path = [ config.environment.systemPath ];
      script = ''
        [ -d ${stateDir} ] || mkdir ${stateDir}
        cp ${confFile} ${stateDir}/unbound.conf
        ${optionalString cfg.enableRootTrustAnchor ''
          ${pkgs.unbound}/bin/unbound-anchor -a ${rootTrustAnchorFile} || echo "Root anchor updated!"
        ''}
        chown -R unbound:unbound ${stateDir}
      exec ${pkgs.unbound}/bin/unbound -d -c ${stateDir}/unbound.conf
      '';
      serviceConfig.KeepAlive = true;
    };
  };
}
