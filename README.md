ACME cookbook
=============

[![Build Status](https://travis-ci.org/schubergphilis/chef-acme.svg)](https://travis-ci.org/schubergphilis/chef-acme)
[![Cookbook Version](https://img.shields.io/cookbook/v/acme.svg)](https://supermarket.chef.io/cookbooks/acme)

Automatically get/renew free and trusted certificates from Let's Encrypt (letsencrypt.org).
ACME is the [Automated Certificate Management Environment protocol][1] used by [Let's Encrypt][2].

```
Starting with v4.0.0 of the acme cookbook the acme_ssl_certificate provider has been removed! The TLS-SNI-01 validation method used by this provider been disabled by Let's Encrypt due to security concerns. Please switch to the acme_certificate provider in this cookbook to request and renew your certificate using the supported HTTP-01 validation method.
```

Attributes
----------

| Attribute        | Description                                                                                                                                                                    | Default                                          |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------       | --------------------------------------:          |
| contact          | Contact information, default empty. Set to `mailto:your@email.com`                                                                                                             | []                                               |
| dir              | ACME server endpoint, Set to `https://acme-staging-v02.api.letsencrypt.org/directory` if you want to use the Let's Encrypt staging environment and corresponding certificates. | `https://acme-v02.api.letsencrypt.org/directory` |
| renew            | Days before the certificate expires at which the certificate will be renewed                                                                                                   | 30                                               |
| source_ips       | IP addresses used by Let's Encrypt to verify the TLS certificates, it will change over time. This attribute is for firewall purposes. Allow these IPs for HTTP (tcp/80).       | ['66.133.109.36']                                |
| private_key      | Private key content of registered account. Private keys identify the ACME client with the endpoint and are not transferable between staging and production endpoints.          | nil                                              |
| private_key_file | Filename where private key will be saved. If this file exists, the contents take precedence over the value set in `private_key`.                                               | `/etc/acme/account_private_key.pem`              |
| key_size         | Default private key size used when resource property is not. Must be one out of: 2048, 3072, 4096.                                                                             | 2048                                             |


Recipes
-------
### default
Installs the required acme-client rubygem.

Usage
-----
Use the `acme_certificate` resource to request a certificate with the http-01 challenge. The webserver for the domain for which you are requesting a certificate must be running on the local server. This resource only supports the http validation method. To use the tls-sni-01 challenge, please see the resource below. Provide the path to your `wwwroot` for the specified domain.

```ruby
acme_certificate 'test.example.com' do
  crt               '/etc/ssl/test.example.com.crt'
  key               '/etc/ssl/test.example.com.key'
  wwwroot           '/var/www'
end
```

If your webserver needs an existing certificate already when installing a new server, you will have a bootstrap problem: The web server cannot start without a certificate, but the certificate cannot be requested without the running web server. To overcome this, a temporary self-signed certificate can be generated with the `acme_selfsigned` resource, allowing the web server to start.

```ruby
acme_selfsigned 'test.example.com' do
  crt     '/etc/ssl/test.example.com.crt'
  chain   '/etc/ssl/test.example.com-chain.crt'
  key     '/etc/ssl/test.example.com.key'
end
```


A working example can be found in the included `acme_client` test cookbook.

Providers
---------
### certificate
| Property            | Type    | Default  | Description                                            |
|  ---                |  ---    |  ---     |  ---                                                   |
| `cn`                | string  | _name_   | The common name for the certificate                    |
| `alt_names`         | array   | []       | The common name for the certificate                    |
| `crt`               | string  | nil      | File path to place the certificate                     |
| `key`               | string  | nil      | File path to place the private key                     |
| `key_size`          | integer | 2048     | Private key size. Must be one out of: 2048, 3072, 4096 |
| `owner`             | string  | root     | Owner of the created files                             |
| `group`             | string  | root     | Group of the created files                             |
| `wwwroot`           | string  | /var/www | Path to the wwwroot of the domain                      |
| `ignore_failure`    | boolean | false    | Whether to continue chef run if issuance fails         |
| `retries`           | integer | 0        | Number of times to catch exceptions and retry          |
| `retry_delay`       | integer | 2        | Number of seconds to wait between retries              |
| `endpoint`          | string  | nil      | The Let's Encrypt endpoint to use                      |
| `contact`           | array   | []       | The contact to use                                     |

### selfsigned
| Property         | Type    | Default  | Description                                            |
|  ---             |  ---    |  ---     |  ---                                                   |
| `cn`             | string  | _name_   | The common name for the certificate                    |
| `crt`            | string  | nil      | File path to place the certificate                     |
| `key`            | string  | nil      | File path to place the private key                     |
| `key_size`       | integer | 2048     | Private key size. Must be one out of: 2048, 3072, 4096 |
| `chain`          | string  | nil      | File path to place the certificate chain               |
| `owner`          | string  | root     | Owner of the created files                             |
| `group`          | string  | root     | Group of the created files                             |

Example
-------
To generate a certificate for an apache2 website you can use code like this:

```ruby
# Include the recipe to install the gems
include_recipe 'acme'

# Set up contact information. Note the mailto: notation
node.override['acme']['contact'] = ['mailto:me@example.com']
# Real certificates please...
node.override['acme']['endpoint'] = 'https://acme-v01.api.letsencrypt.org'

site = "example.com"
sans = ["www.#{site}"]

# Generate a self-signed if we don't have a cert to prevent bootstrap problems
acme_selfsigned "#{site}" do
  crt     "/etc/httpd/ssl/#{site}.crt"
  key     "/etc/httpd/ssl/#{site}.key"
  chain    "/etc/httpd/ssl/#{site}.pem"
  owner   "apache"
  group   "apache"
  notifies :restart, "service[apache2]", :immediate
end

# Set up your web server here...

# Get and auto-renew the certificate from Let's Encrypt
acme_certificate "#{site}" do
  crt               "/etc/httpd/ssl/#{site}.crt"
  key               "/etc/httpd/ssl/#{site}.key"
  wwwroot           "/var/www/#{site}/htdocs/"
  notifies :restart, "service[apache2]"
  alt_names sans
end
```

DNS verification
----------------

Letsencrypt supports DNS validation. Depending on the setup there may be different ways to deploy an acme challenge to your infrastructure. If you want to use DSN validation, you have to provide two block arguments to the `acme_certificate` resource.

Implement 2 methods in a library in your cookbook, each returning a `Proc` object. The following example uses a HTTP API to provide challenges to the DNS infrastructure.

```ruby
# my_cookbook/libraries/acme_dns.rb

class Chef
  class Recipe
    def install_dns_challenge(apitoken)
      Proc.new do |authorization, new_resource|
        # use DNS authorization
        authz = authorization.dns
        fqdn = authorization.identifier['value']
        r = Net::HTTP.post(URI("https://my_awesome_dns_api/#{fqdn}"), authz.record_content, {'Authorization' => "Token #{apitoken}"})
        if r.code != '200'
          fail "DNS API does not want to install Challenge for #{fqdn}"
        else
          # do some validation that the challenge has propagated to the infrastructure
        end
        # it is important that the authz and fqdn is passed back, so it can be passed to the remove_dns_challenge method
        [authz, fqdn]
      end
    end
    def remove_dns_challenge(apitoken)
      Proc.new do |authz, fqdn|
        uri = URI("https://my_awesome_dns_api/#{fqdn}")
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme=='https') do |http|
          http.delete(uri, {'Authorization' => "Token #{apitoken}"})
        end
      end
    end
  end
end
```

Use it in your recipe the following way:

```ruby
apitoken = chef_vault_item(vault, item)['dns_api_token']
acme_certificate node['fqdn'] do
  key '/path/to/key'
  crt '/path/to/crt'
  install_authz_block install_dns_challenge(apitoken)
  remove_authz_block remove_dns_challenge(apitoken)
end
```



Testing
-------
The kitchen includes a `pebble` server to run the integration tests with, so testing can run locally without interaction with the online APIs.

Contributing
------------
1. Fork the repository on Github
2. Create a named feature branch (like `add_component_x`)
3. Write your change
4. Write tests for your change (if applicable)
5. Run the tests, ensuring they all pass
6. Submit a Pull Request using Github

License and Authors
-------------------
Authors: Thijs Houtenbos <thoutenbos@schubergphilis.com>

Credits
-------
Let’s Encrypt is a trademark of the Internet Security Research Group. All rights reserved.

[1]: https://ietf-wg-acme.github.io/acme/
[2]: https://letsencrypt.org/
