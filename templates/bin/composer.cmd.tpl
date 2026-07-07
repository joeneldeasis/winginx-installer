@echo off
setlocal
"{{PHP_EXE}}" -c "{{PHP_INI}}" "{{COMPOSER_PHAR}}" %*
