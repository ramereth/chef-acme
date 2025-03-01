#
# Author:: Thijs Houtenbos <thoutenbos@schubergphilis.com>
# Cookbook:: acme
# Resource:: certificate
#
# Copyright:: 2015-2021, Schuberg Philis
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

unified_mode true

default_action :create

property :cn,         String, name_property: true
property :alt_names,  Array,  default: []

property :crt,        [String, nil], required: true
property :key,        [String, nil], required: true

property :owner,      String, default: 'root'
property :group,      String, default: 'root'

property :wwwroot,    String, default: '/var/www'

property :key_size,   Integer, default: lazy { node['acme']['key_size'] }, equal_to: [2048, 3072, 4096]

property :dir,        [String, nil]
property :contact,    Array, default: []

# if you want to use DNS authentication, you can pass the code to install and
# remove the challenge as a block
#
# the install_authz_block will be called for each authorization with the
# authorization and resource as parameter. It must return the authz object from
# the authorization.
# The resource will then call the acme verification process. After verification
# the remove_authz_block will be called with the authz as parameter. This is
# intended to allow cleanup of the challenge
property :install_authz_block, [Proc, nil]
property :remove_authz_block, [Proc, nil]

property :chain, String, deprecated: 'The chain property has been deprecated as the acme-client gem now returns the full certificate chain by default (on the crt property.) Please update your cookbooks to remove this property.'
deprecated_property_alias 'fullchain', 'crt', 'The fullchain property has been deprecated as the acme-client gem now returns the full certificate chain by default (on the crt property.) Please update your cookbooks to switch to \'crt\'.'

deprecated_property_alias 'endpoint', 'dir', 'The endpoint property was renamed to dir, to reflect ACME v2 changes. Please update your cookbooks to use the new property name.'

def names_changed?(cert, names)
  return false if names.empty?

  san_extension = cert.extensions.find { |e| e.oid == 'subjectAltName' }
  return false if san_extension.nil?

  current = san_extension.value.split(', ').select { |v| v.start_with?('DNS:') }.map { |v| v.split(':')[1] }
  !(names - current).empty? || !(current - names).empty?
end

action :create do
  file "#{new_resource.cn} SSL key" do
    path      new_resource.key
    owner     new_resource.owner
    group     new_resource.group
    mode      '400'
    content   OpenSSL::PKey::RSA.new(new_resource.key_size).to_pem
    sensitive true
    action    :nothing
  end.run_action(:create_if_missing)

  mycert   = nil
  mykey    = OpenSSL::PKey::RSA.new ::File.read new_resource.key
  names    = [new_resource.cn, new_resource.alt_names].flatten.compact
  renew_at = ::Time.now + 60 * 60 * 24 * node['acme']['renew']

  if !new_resource.crt.nil? && ::File.exist?(new_resource.crt)
    mycert = ::OpenSSL::X509::Certificate.new ::File.read new_resource.crt
  end

  if mycert.nil? || mycert.not_after <= renew_at || names_changed?(mycert, names)
    order = acme_order_certs_for(names)
    all_validations = []
    if new_resource.install_authz_block.nil?
      order.authorizations.each do |authorization|
        authz = install_http_validation(authorization, new_resource)
        acme_validate(authz)
        remove_http_validation(authz, new_resource)
        all_validations.push(authz)
      end
    else
      ruby_block 'install and validate challenges using custom method' do
        block do
          order.authorizations.each do |authorization|
            authz, fqdn = new_resource.install_authz_block.call(authorization, new_resource)
            acme_validate(authz)
            new_resource.remove_authz_block.call(authz, fqdn)
          end
        end
      end
    end

    ruby_block "create certificate for #{new_resource.cn}" do
      block do
        unless (all_validations.map { |authz| authz.status == 'valid' }).all?
          errors = all_validations.select { |authz| authz.status != 'valid' }.map do |authz|
            "{url: #{authz.url}, status: #{authz.status}, error: #{authz.error}} "
          end.reduce(:+)

          raise "[#{new_resource.cn}] Validation failed, unable to request certificate, Errors: [#{errors}]"
        end

        begin
          newcert = acme_cert(order, new_resource.cn, mykey, new_resource.alt_names)
        rescue Acme::Client::Error => e
          raise "[#{new_resource.cn}] Certificate request failed: #{e.message}"
        else
          Chef::Resource::File.new("#{new_resource.cn} SSL new crt", run_context).tap do |f|
            f.path    new_resource.crt
            f.owner   new_resource.owner
            f.group   new_resource.group
            f.content newcert
            f.mode    00644
          end.run_action :create
        end
      end
    end
  end
end

action_class.class_eval do
  def install_http_validation(authorization, new_resource)
    authz = authorization.http
    tokenpath = "#{new_resource.wwwroot}/#{authz.filename}"

    directory ::File.dirname(tokenpath) do
      owner     new_resource.owner
      group     new_resource.group
      mode      '755'
      recursive true
      action    :nothing
    end.run_action(:create)

    file tokenpath do
      owner   new_resource.owner
      group   new_resource.group
      mode    '644'
      content authz.file_content
      action  :nothing
    end.run_action(:create)
    authz
  end

  def remove_http_validation(authz, new_resource)
    tokenpath = "#{new_resource.wwwroot}/#{authz.filename}"
    file tokenpath do
      backup false
      action :delete
    end
  end
end
