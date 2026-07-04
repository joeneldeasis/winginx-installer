server {
    listen       {{HTTP_PORT}};
    server_name  {{SERVER_NAME}};

    root   {{WEB_ROOT}};
    index  index.php index.html index.htm;

    charset utf-8;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /favicon.ico {
        access_log off;
        log_not_found off;
    }

    location = /robots.txt {
        access_log off;
        log_not_found off;
    }

    location ~ \.php$ {
        try_files $uri =404;
        include fastcgi_params;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT $document_root;
        fastcgi_param PHP_VALUE "open_basedir={{WEB_ROOT}};{{PHP_ROOT}}/tmp/";
        fastcgi_pass php_backend;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
