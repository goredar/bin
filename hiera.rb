require 'json'

class Hiera
  HIERA_PATH = '/home/goredar/devops/hiera-backend'
  def self.add_certs(node, cert_names = [], owner = nil, apply = false)
    cert_names = [cert_names] unless cert_names.is_a? Array
    file_name = Dir.glob("#{HIERA_PATH}/node/*/#{node}*.json").first
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
            LOG.info('certs') { "#{cert} is added to #{file_name}" }
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
  def self.add_classes(node, classes = [], apply = false)
    classes = [classes] unless classes.is_a? Array
    file_name = Dir.glob("#{HIERA_PATH}/node/*/#{node}*.json").first
    data = JSON.load IO.read file_name
    data["acme::classes"] ||= []
    data["acme::classes"] += classes
    data["acme::classes"].uniq!
    LOG.info("classes") { "#{classes} is added to #{node.gsub('.local', '')}.json under acme::classes section" }
    system "echo '#{JSON.dump(data)}' | jq . > #{file_name}" if apply
  end
  def self.remove_classes(node, classes = [], apply = false)
    classes = [classes] unless classes.is_a? Array
    file_name = Dir.glob("#{HIERA_PATH}/node/*/#{node}*.json").first
    data = JSON.load IO.read file_name
    return unless data["acme::classes"]
    data["acme::classes"] -= classes
    data["acme::classes"].uniq!
    data.delete "acme::classes" if data["acme::classes"].empty?
    LOG.info("classes") { "#{classes} has been removed from #{node.gsub('.local', '')}.json" }
    system "echo '#{JSON.dump(data)}' | jq . > #{file_name}" if apply
  end
end