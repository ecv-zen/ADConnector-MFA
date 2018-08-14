$token_enckey_location	= "s3://<bucket>/<path>/encKey"   # Create by dd if=/dev/urandom of=encKey bs=1 count=96
$db_host				= "localhost"
$db_port				= "3306"
$db_user				= "linotp"
$db_pass				= "<DB-Password"
$db_name				= "LINOTP"
$htpasswd_admin_user	= "<username>:LinOTP2 admin area:<password-ht-hash>"
$realm					= "<realm>"

$radius_clients = {
    'localhost' => {
        'ipaddr' => '127.0.0.1',
        'netmask' => '32',
        'secret' => '<your-secret>',
    },

    'adconnector' => {
        'ipaddr' => '10.0.0.0',
        'netmask' => '16',
        'secret' => '<your-secret>',
    },
}



##### No configuration below this line #####

$linotp_conf_template = @(END)
[server:main]
use = egg:Paste#http
host = 0.0.0.0
port = 5001

[DEFAULT]
debug = false
profile = false
smtp_server = localhost
error_email_from = paste@localhost
linotpAudit.key.private = %(here)s/private.pem
linotpAudit.key.public = %(here)s/public.pem
linotpAudit.sql.highwatermark = 10000
linotpAudit.sql.lowwatermark = 5000
linotp.DefaultSyncWindow = 1000
linotp.DefaultOtpLen = 6
linotp.DefaultCountWindow = 50
linotp.DefaultMaxFailCount = 15
linotp.FailCounterIncOnFalsePin = True
linotp.PrependPin = True
linotp.DefaultResetFailCount = True
linotp.splitAtSign = True
linotpGetotp.active = False
linotpSecretFile = %(here)s/encKey
radius.dictfile= %(here)s/dictionary
radius.nas_identifier = LinOTP

[app:main]
use = egg:LinOTP
alembic.ini = %(here)s/alembic.ini
sqlalchemy.url = mysql://<%= $tmpl_db_user %>:<%= $tmpl_db_pass %>@<%= $tmpl_db_host %>:<%= $tmpl_db_port %>/<%= $tmpl_db_name %>
sqlalchemy.pool_recycle = 3600
who.config_file = %(here)s/who.ini
who.log_level = warning
who.log_file = /var/log/linotp/linotp.log
full_stack = true
static_files = true
cache_dir = %(here)s/data
custom_templates = %(here)s/custom-templates/

[loggers]
keys = root

[logger_root]
level = WARN
handlers = file

[handlers]
keys = file

[handler_file]
class = handlers.RotatingFileHandler
args = ('/var/log/linotp/linotp.log','a', 10000000, 4)
level = WARN
formatter = generic

[formatters]
keys = generic

[formatter_generic]
format = %(asctime)s %(levelname)-5.5s [%(name)s][%(funcName)s #%(lineno)d] %(message)s
datefmt = %Y/%m/%d - %H:%M:%S
END

$radius_client_conf_template = @(END)
<% $radius_clients.each |$element, $element_value| { -%>
client <%= $element %> {
<% $element_value.each |$key, $value| { %>      <%= $key -%> = <%= $value %>
<% } %>
} 

<% } -%>
END

$linotp_perl_module_template = @(END)
perl {
     filename = /usr/share/linotp/radius_linotp.pm
}
END

$perl_module_config_template = @(END)
URL=https://localhost/validate/simplecheck
REALM=<%= $realm %>
Debug=True
SSL_CHECK=False
END


$linotp_main_config_template = @(END)
server default {

listen {
	type = auth
	ipaddr = *
	port = 0

	limit {
	      max_connections = 16
	      lifetime = 0
	      idle_timeout = 30
	}
}

listen {
	ipaddr = *
	port = 0
	type = acct
}



authorize {
        preprocess
        IPASS
        suffix
        ntdomain
        files
        expiration
        logintime
        update control {
                Auth-Type := Perl
        }
        pap
}

authenticate {
	Auth-Type Perl {
		perl
	}
}


preacct {
	preprocess
	acct_unique
	suffix
	files
}

accounting {
	detail
	unix
	-sql
	exec
	attr_filter.accounting_response
}


session {

}


post-auth {
	update {
		&reply: += &session-state:
	}

	-sql
	exec
	remove_reply_message_if_eap
}
}
END


class linotp {

	exec { 'linotp_repo':
		command			=> "/usr/bin/yum -y localinstall http://linotp.org/rpm/el7/linotp/x86_64/Packages/LinOTP_repos-1.1-1.el7.x86_64.rpm",
		creates			=> '/etc/yum.repos.d/linotp.repo'
	}

	package { 'linotp_package':
		name			=> "LinOTP",
		ensure			=> present,
		allow_virtual 	=> false,
		require 		=> Exec['linotp_repo']
	}

    package { 'linotp_package_apache':
        name    		=> "LinOTP_apache",
        ensure  		=> present,
        allow_virtual 	=> false,
        require 		=> Package['linotp_package']
    }

 	package {'yum-plugin-versionlock':
		ensure 			=> present,
		allow_virtual 	=> false,
	}

	exec { 'lock_python-repoze-who':
		command 		=> '/usr/bin/yum versionlock python-repoze-who',
		unless  		=> '/usr/bin/yum versionlock list | /usr/bin/grep python-repoze-who 2>&1 >> /dev/null',
		require 		=> Package['yum-plugin-versionlock'],
	}

	file { 'absent_ssl_default_config':
		path 			=> "/etc/httpd/conf.d/ssl.conf",
		ensure 			=> absent,
		require 		=> Package['linotp_package_apache'],
	}

	file { 'apache_linotp_config':
		path  			=> '/etc/httpd/conf.d/ssl_linotp.conf',
		ensure 			=> present,
		require 		=> Package['linotp_package_apache'],
		content 		=> file('/etc/httpd/conf.d/ssl_linotp.conf.template'),
	}

	file { 'linotp_ini':
		ensure 			=> file,
		path			=> "/etc/linotp2/linotp.ini",
		content			=> inline_epp($linotp_conf_template, {'tmpl_db_user' => $db_user,'tmpl_db_pass' => $db_pass, 'tmpl_db_host' => $db_host, 'tmpl_db_port' => $db_port, 'tmpl_db_name' => $db_name}),
 		require 		=> Package['linotp_package'];	
	}

	exec { 'encKey':
		command 		=> "/usr/bin/aws s3 cp $token_enckey_location /etc/linotp2/encKey && /usr/bin/chmod 640 /etc/linotp2/encKey &&  /usr/bin/chown linotp.root /etc/linotp2/encKey",
		creates 		=> "/etc/linotp2/encKey",
	}

	file { 'htpasswd_admin':
		path			=> "/etc/linotp2/admins",
		content 		=> $htpasswd_admin_user,
		mode			=> 0640,
		owner			=> "linotp",
		group			=> "apache",
	}

	service { 'httpd':
		ensure 			=> running,
		name 			=> httpd,
		enable 			=> true,
		subscribe 		=> [File['apache_linotp_config'], File['linotp_ini']]
	}

}


class freeradius {
	$required_packages = ['freeradius', 'freeradius-perl', 'freeradius-utils', 'perl-App-cpanminus', 'perl-LWP-Protocol-https', 'perl-Try-Tiny']
	package { $required_packages:
		ensure			=> present,
		allow_virtual 	=> false,
	}

	file { 'raddb_clients_conf':
        ensure      	=> file,
        path        	=> "/etc/raddb/clients.conf",
        content     	=> inline_epp($radius_client_conf_template, $radius_clients),
		owner			=> root,
		group			=> radiusd,
		mode			=> 0640,
		require			=> Package[$required_packages],
    }

	exec { 'linotp_perl_module':
		command			=> "/usr/bin/curl -so /usr/share/linotp/radius_linotp.pm https://raw.githubusercontent.com/johnalvero/linotp-auth-freeradius-perl/master/radius_linotp.pm",
		creates			=> "/usr/share/linotp/radius_linotp.pm",
		require     	=> Package[$required_packages],
	}

	file { 'linotp_perl_module_file':
		ensure			=> file,
		path			=> "/etc/raddb/mods-available/perl",
		content			=> inline_epp($linotp_perl_module_template),
        owner   		=> root,
        group   		=> radiusd,
        mode    		=> 0640,
        require 		=> Package[$required_packages],
	}

	file { '/etc/raddb/mods-enabled/perl':
		ensure			=> 'link',
		target			=>	'/etc/raddb/mods-available/perl',
		require 		=> File['linotp_perl_module_file'],

	}

	file { '/etc/linotp2/rlm_perl.ini':
		ensure			=> file,
		content			=> inline_epp($perl_module_config_template, {'realm' => $realm}),
		owner   		=> linotp,
        group   		=> root,
        mode    		=> 0640,
        require 		=> Package[$required_packages],
	}

	file { '/etc/raddb/sites-enabled/inner-tunnel':
		ensure			=> absent,
		require 		=> Package[$required_packages],
	}

    file { '/etc/raddb/sites-enabled/default':
        ensure  		=> absent,
        require 		=> Package[$required_packages],
    }

    file { '/etc/raddb/mods-enabled/eap':
        ensure  		=> absent,
        require 		=> Package[$required_packages],
    }

	file { '/etc/raddb/sites-available/linotp':
		ensure			=> file,
		content			=> inline_epp($linotp_main_config_template),
		owner   		=> root,
        group   		=> radiusd,
        mode    		=> 0640,
        require 		=> Package[$required_packages],
	}

    file { '/etc/raddb/sites-enabled/linotp':
        ensure  		=> 'link',
        target  		=> '/etc/raddb/sites-available/linotp',
        require 		=> Package[$required_packages],

    }

    service { 'radiusd':
        ensure 			=> running,
        name 			=> radiusd,
        enable 			=> true,
        subscribe 		=> [File['/etc/raddb/sites-available/linotp'], File['/etc/linotp2/rlm_perl.ini'], File['raddb_clients_conf']]
    }


}

include linotp
include freeradius