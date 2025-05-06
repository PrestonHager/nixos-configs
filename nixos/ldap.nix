{ config, pkgs, ... }:

{
  services.openldap = {
    enable = true;

    urlList = [ "ldap:///" "ldaps:///" ];

    settings = {
      attrs = {
        olcLogLevel = "conns config";

        olcTLSCACertificateFile = "/var/lib/acme/ldap.prestonhager.com/full.pem";
        olcTLSCertificateFile = "/var/lib/acme/ldap.prestonhager.com/cert.pem";
        olcTLSCertificateKeyFile = "/var/lib/acme/ldap.prestonhager.com/key.pem";
        olcTLSCRLCheck = "none";
        olcTLSVerifyClient = "never";
        olcTLSProtocolMin = "3.1";
      };

      children = {
        "cn=schema".includes = [
          "${pkgs.openldap}/etc/schema/core.ldif"
          "${pkgs.openldap}/etc/schema/cosine.ldif"
          "${pkgs.openldap}/etc/schema/inetorgperson.ldif"
        ];

        "olcDatabase={1}mdb".attrs = {
          objectClass = [ "olcDatabaseConfig" "olcMdbConfig" ];

          olcDatabase = "{1}mdb";
          olcDbDirectory = "/var/lib/openldap/data";

          olcSuffix = "dc=ldap,dc=prestonhager,dc=com";

          olcRootDN = "cn=admin,dc=ldap,dc=prestonhager,dc=com";
#          olcRootPW.path = pkgs.writeText "olcRootPW" "pass";
          olcRootPW.path = "/etc/ldap_pw";

          olcAccess = [
            ''
            {0}to attrs=userPassword
              by self write
              by anonymous auth
              by * none
            ''

            ''
            {1}to *
              by * read
            ''
          ];
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [
    389
    636
  ];

  systemd.services.openldap = {
    wants = [ "acme-ldap.prestonhager.com.service" ];
    after = [ "acme-ldap.prestonhager.com.service" ];
  };

  users.groups.nginx.members = [ "openldap" ];
}

