@{
    # Compiled into the Windows PHP core; no php_<name>.dll is shipped.
    BuiltIn = @(
        'bcmath'
        'xml'
        'xmlreader'
        'xmlwriter'
    )

    Default = @(
        'bcmath'
        'bz2'
        'curl'
        'exif'
        'fileinfo'
        'gd'
        'gettext'
        'intl'
        'mbstring'
        'mysqli'
        'openssl'
        'pdo_mysql'
        'pdo_sqlite'
        'soap'
        'sockets'
        'sodium'
        'xml'
        'xmlreader'
        'xmlwriter'
        'zip'
        'opcache'
    )

    Optional = @(
        'ldap'
        'imap'
        'pgsql'
        'pdo_pgsql'
        'ftp'
        'xsl'
    )

    Notes = @{
        opcache = 'Recommended for performance in most production deployments.'
        ldap    = 'May require additional environment libraries depending on the PHP build.'
        imap    = 'Not always bundled in all Windows PHP archives.'
    }
}
