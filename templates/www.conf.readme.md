`php-fpm` is not shipped for native Windows PHP builds.

This installer uses `php-cgi.exe` behind `nginx` over FastCGI, which is the closest supported Windows deployment model for the same stack.

The generated `nginx` config exposes a shared FastCGI upstream, while virtual hosts live under `conf\conf.d\*.conf`.
