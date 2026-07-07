@echo off
setlocal
if not exist "artisan" (
  echo artisan was not found in the current directory.
  echo Change into a Laravel project folder, then run artisan again.
  exit /b 1
)
"{{PHP_EXE}}" -c "{{PHP_INI}}" artisan %*
