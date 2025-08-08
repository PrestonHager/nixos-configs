{ config, ... }:

#locations = {
#  "/" = {
#    proxyPass = "http://localhost:8083/";
#    proxyWebsockets = true;
#    extraConfig = ''
#      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
#      proxy_set_header X-Forwarded-Port $server_port;
#      proxy_set_header X-Forwarded-Scheme $scheme;
#      proxy_set_header X-Forwarded-Proto $scheme;
#      proxy_set_header X-Real-IP $remote_addr;
#      proxy_set_header Host $host;
#      proxy_set_header Early-Data $ssl_early_data;
#    '';
#  };
#};
#extraConfig = ''
#  proxy_buffering off;
#  proxy_request_buffering off;
#
#  client_max_body_size 0;
#  client_body_buffer_size 512k;
#  proxy_read_timeout 86400s;
#
#  location /.well-known/carddav {
#    return 301 $scheme://$host/remote.php/dav;
#  }
#  location /.well-known/caldav {
#    return 301 $scheme://$host/remote.php/dav;
#  }
#  location ^~ /.well-known {
#    return 301 $scheme://$host/index.php$request_uri;
#  }
#  proxy_hide_header Upgrade;
#'';

{
  services.caddy = {
    virtualHosts."cloud.prestonhager.com".extraConfig = ''
      reverse_proxy http://localhost:8083
    '';
  };
}

