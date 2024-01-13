#!/usr/bin/env ruby

require 'yaml'
require 'resolv'
require 'net/http'
require 'json'
require 'optparse'
require 'logger'
require 'colorize'

YAML_PATH = '/home/goredar/devops/configs/conf/'
HIERA_PATH = '/home/goredar/devops/hiera-backend/'
GAMES = %w[wot wotb wotg wowp wows exc twa]
IDENT_SIZE = 4
SEVERITY_MAP = {
  "DEBUG" => "DBUG",
  "INFO" => "INFO".blue,
  "WARN" => "WARN".yellow,
  "ERROR" => "ERRO".red,
  "FATAL" => "FATE".on_red,
  "UNKNOWN" => "UNKN",
}

class Hiera
  def self.add_certs(node, cert_names = [], owner = nil, apply = false)
    cert_names = [cert_names] unless cert_names.is_a? Array
    file_name = HIERA_PATH + "node/#{node.split('-').first}/#{node.gsub('.local', '')}.json"
    data = JSON.load IO.read file_name
    added = false
    present = false
    data.each do |key, val|
      if key.include? "::auto::ssl_certs"
        (present = true; next) if owner && !key.include?(owner)
        cert_names.each do |cert|
          if val.include? cert
            present = true
            LOG.debug('certs') { "#{cert} is already present on #{node}" }
          else
            val << cert
            added = true
            LOG.info('certs') { "#{cert} is added to #{node.gsub('.local', '')}.json" }
          end
        end
      end
    end
    unless (added or present)
      data["__acme::auto::ssl_certs"] = cert_names
      LOG.info("certs") { "#{cert_names} is added to #{node.gsub('.local', '')}.json under __acme:: section" }
      added = true
    end
    system "echo '#{JSON.dump(data)}' | jq . > #{file_name}" if added and apply
  end
end

class PowerDNS
  def self.add_record(opts = {})
    opts[:site] ||= :net
    opts[:dns_host] ||= opts[:site] == :cn ? "ns-cn1.acme.io" : "ns1.acme.io"
    opts[:dns_port] ||= "8081"
    opts[:zone] ||= "acme.io"
    opts[:api_key] ||= opts[:site] == :cn ? "kuvOmDeaj8" : "Ribpechoyb"
    opts[:type] ||= "CNAME"
    opts[:apply] ||= false
    return unless opts[:name] && opts[:content]
    rrsets = {
      "rrsets":
        [
          {
            "name": opts[:name],
            "type": opts[:type],
            "changetype": "REPLACE",
            "records": [
              {
                "content": opts[:content],
                "disabled": false,
                "set-ptr": true,
                "name": opts[:name],
                "ttl": 300,
                "type": opts[:type],
                "priority": 0,
              }
            ]
          }
        ]
    }
    http = Net::HTTP.new opts[:dns_host], opts[:dns_port]
    resp_code = opts[:apply] ? http.patch("/servers/localhost/zones/#{opts[:zone]}", JSON.dump(rrsets), "X-API-Key": opts[:api_key]).code : "200"
    if resp_code == "200"
      LOG.info("powerdns") { "added #{opts[:type]} record #{opts[:name]} -> #{opts[:content]}" }
    else
      LOG.error("powerdns") { "failed to add #{opts[:type]} record #{opts[:name]} -> #{opts[:content]}" }
    end
      LOG.debug("powerdns") { "site: #{opts[:site]}, responce code: " + resp_code.yellow }
  end
end

class App
  def self.grep_realms(app_name)
    @realm_cache ||= {}
    @realm_map ||= {}
    @realm_raw_content ||= {}
    Dir["#{YAML_PATH}/**/*.yaml"].each do |file_name|
      next unless file_name =~ /(.*)\.yaml/
      file_content = IO.read file_name
      next unless file_content.include? "#{app_name}:"
      realm_name = $1.split('/').last
      @realm_raw_content[realm_name] = file_content
      @realm_cache[realm_name] = YAML.load @realm_raw_content[realm_name]
      @realm_map[realm_name] = file_name
      yield [realm_name, @realm_cache[realm_name]] if block_given?
    end
    @realm_cache
  end

  def self.find_by_name(app_name)
    found_apps = {}
    realm = nil
    game = nil
    scan_content = proc do |node, content|
      if GAMES.include?(node)
        game = node
        content.each(&scan_content)
        game = nil
      end
      next unless (content.is_a?(Hash) && content.include?('nodes_list'))
      if node =~ app_name
        if block_given?
          yield [[realm, game, node].compact, content]
        else
          found_apps[[realm, game, node].compact.join('-')] = content
        end
      end
    end
    grep_realms app_name do |name, yaml|
      realm = name
      yaml.each &scan_content
      realm = nil
    end
    found_apps
  end

  def self.find_section(path)
    realm = path.shift
    start_offset = 0
    path.each_with_index do |node, level|
      start_offset = @realm_raw_content[realm].index /^\s{#{level * IDENT_SIZE}}#{node}:$/, start_offset
    end
    section_ident = (path.size - 1) * IDENT_SIZE
    end_offset = @realm_raw_content[realm].index(/^\s{#{section_ident}}\w*:/, start_offset + section_ident.size) - 1
    @realm_raw_content[realm][start_offset..end_offset]
  end

  def self.change_http_host(host, app_path, http_content)
    old_text = find_section app_path + ["http"]
    text = old_text.dup
    ident = ' ' * IDENT_SIZE * app_path.size
    text.gsub! /host:\s+#{http_content["host"]}/, "host: #{host}"
    text = text.chomp + $/ + ident + "old_host: #{http_content["host"]}" + $/
    if http_content["ssl_certificate"]
      text.gsub! http_content["ssl_certificate"], "/srv/ssl/auto/acme.io/acme.io.crt"
      text = text.chomp + $/ + ident + "old_ssl_certificate: #{http_content["ssl_certificate"]}" + $/
      text.gsub! http_content["ssl_certificate_key"], "/srv/ssl/auto/acme.io/acme.io.key"
      text = text.chomp + $/ + ident + "old_ssl_certificate_key: #{http_content["ssl_certificate_key"]}" + $/
    end
    @realm_raw_content[app_path[0]].gsub! old_text, text
    LOG.info("yaml") { "#{app_path.compact.join('-')} http section has been updated" }
  end

  def self.find_be_host(hostname, nodes = [])
    be_name = nil
    Resolv::DNS.open do |dns|
      ress = dns.getresources hostname, Resolv::DNS::Resource::IN::CNAME
      cname = ress[0].name.to_s rescue nil
      be_name = case cname
      when /(be.core.pw|local.acme.cn|acme.io)$/
        cname
      when /fe.core.pw$/
        cname.gsub "fe.core.pw", "be.core.pw"
      when /acme.cn$/
        cname.gsub "acme.cn", "local.acme.cn"
      else
        zone = '.be.core.pw'
        begin
          nodes.select { |n| Resolv.getaddress(n.split('.').first + zone) == Resolv.getaddress(hostname) }.first.split('.').first + '.be.core.pw'
        rescue
          if zone == '.be.core.pw'
            zone = '.fe.core.pw'
            retry
          else
            nil
          end
        end
      end
    end
    (Resolv.getaddress(be_name) ? be_name : nil) rescue nil
  end

  def self.commit_changes(realm = nil, apply = false)
    realms_to_commit = realm ? { realm => @realm_map[realm] } : @realm_map
    realms_to_commit.each do |realm, file_name|
      File.open file_name, "w" do |file|
        file.write @realm_raw_content[realm]
      end if apply
      LOG.warn("yaml") { "commiting changes to #{file_name.split('/').last.white}" }
    end
  end
end

options = {}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: mover.rb [options]"
  opts.on("-a", "--app APP", "App name to process") { |app| options[:app] = Regexp.new app }
  opts.on("-r", "--realm REALM", "Realm mask to filter app") { |realm| options[:realm] = realm }
  opts.on("--apply", "Apply changes, overvise it's dry run") { options[:apply] = true; options[:apply_certs] = true; options[:apply_dns] = true }
  opts.on("--apply-certs [OWNER]", "Add certs to Hiera files") { |owner| options[:apply_certs] = true; options[:certs_owner] = owner }
  opts.on("--apply-dns", "Add DNS record") { options[:apply_dns] = true }
  opts.on("--force", "Pass force flag to fabric") { options[:force] = true }
  opts.on("--debug", "Print debug info") { options[:debug] = true }
end

parser.parse!

(puts parser; exit 0) unless options[:app]

LOG = Logger.new STDOUT
LOG.level = options[:debug] ? Logger::DEBUG : Logger::INFO
LOG.formatter = proc do |severity, datetime, progname, msg|
  "#{SEVERITY_MAP[severity]}: [#{progname}] #{msg}\n"
end

puts App.find_by_name(options[:app])
