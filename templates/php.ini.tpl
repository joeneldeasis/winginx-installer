; Core paths
extension_dir="{{PHP_ROOT}}/ext"
sys_temp_dir="{{PHP_ROOT}}/tmp"
upload_tmp_dir="{{PHP_ROOT}}/tmp"
session.save_path="{{PHP_ROOT}}/tmp/session"

; Error handling
display_errors=Off
display_startup_errors=Off
log_errors=On
error_log="{{PHP_ROOT}}/logs/php-error.log"

; Resource limits
memory_limit=256M
max_execution_time=120
max_input_time=120
post_max_size=64M
upload_max_filesize=64M
max_input_vars=3000
default_socket_timeout=60

; Security hardening
cgi.fix_pathinfo=0
expose_php=Off
session.use_strict_mode=1
allow_url_fopen=On
date.timezone={{TIMEZONE}}

; Windows FastCGI tuning
fastcgi.impersonate=1
fastcgi.logging=0
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.validate_timestamps=1
opcache.revalidate_freq=2

; Managed extensions
; winginx-managed-extensions:start
{{EXTENSION_LINES}}
; winginx-managed-extensions:end
