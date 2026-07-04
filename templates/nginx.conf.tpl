worker_processes  auto;

error_log  {{NGINX_LOG_DIR}}/error.log warn;
pid        {{NGINX_ROOT}}/logs/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    log_format  main
        '$remote_addr - $remote_user [$time_local] "$request" '
        '$status $body_bytes_sent "$http_referer" '
        '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  {{NGINX_LOG_DIR}}/access.log  main;

    sendfile        on;
    tcp_nopush      on;
    keepalive_timeout  65;
    server_tokens   off;
    types_hash_max_size 4096;

    client_body_temp_path {{NGINX_TEMP_DIR}}/client_body_temp;
    proxy_temp_path       {{NGINX_TEMP_DIR}}/proxy_temp;
    fastcgi_temp_path     {{NGINX_TEMP_DIR}}/fastcgi_temp;
    uwsgi_temp_path       {{NGINX_TEMP_DIR}}/uwsgi_temp;
    scgi_temp_path        {{NGINX_TEMP_DIR}}/scgi_temp;

    fastcgi_connect_timeout 60s;
    fastcgi_send_timeout 300s;
    fastcgi_read_timeout 300s;

    upstream php_backend {
        server {{PHP_FASTCGI_HOST}}:{{PHP_FASTCGI_PORT}};
        keepalive 8;
    }

    include conf.d/*.conf;
}
