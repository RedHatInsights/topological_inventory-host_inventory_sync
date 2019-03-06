require "concurrent"
require "json"
require "manageiq-messaging"
require 'rest_client'
require "topological_inventory/logging"
require "topological_inventory-ingress_api-client"

module TopologicalInventory
  class HostInventorySync
    include Logging

    attr_reader :source, :sns_topic

    def initialize(topological_inventory_api, host_inventory_api, queue_host, queue_port)
      self.queue_host                = queue_host
      self.queue_port                = queue_port
      self.topological_inventory_api = topological_inventory_api
      self.host_inventory_api        = host_inventory_api
    end

    def run
      logger.info("Starting Host Inventory sync...")
      client = ManageIQ::Messaging::Client.open(default_messaging_opts.merge(:host => queue_host, :port => queue_port))

      queue_opts = {
        :service     => "platform.topological-inventory.persister-output-stream",
        :persist_ref => "host_inventory_sync_worker"
      }

      # Can't use 'subscribe_messages' until https://github.com/ManageIQ/manageiq-messaging/issues/38 is fixed
      # client.subscribe_messages(queue_opts.merge(:max_bytes => 500000)) do |messages|
      begin
        client.subscribe_topic(queue_opts) do |message|
          process_message(message)
        end
      ensure
        client&.close
      end
    end

    private

    attr_accessor :log, :queue_host, :queue_port, :topological_inventory_api, :host_inventory_api

    def process_message(message)
      payload        = message.payload
      account_number = payload["external_tenant"]
      source         = payload["source"]
      x_rh_identity  = Base64.encode64({"identity" => {"account_number" => account_number}}.to_json)

      unless payload["external_tenant"]
        logger.error("Skipping payload because of missing :external_tenant. Payload: #{payload}")
        return
      end

      vms = extract_vms(payload)
      return if payload.empty? # No vms were found

      logger.info("#{vms.size} VMs found for account_number: #{account_number} and source: #{source}.")

      logger.info("Fetching #{vms.size} Topological Inventory VMs from API.")
      topological_inventory_vms = get_topological_inventory_vms(vms, x_rh_identity)
      logger.info("Fetched #{topological_inventory_vms.size} Topological Inventory VMs from API.")

      logger.info("Syncing #{topological_inventory_vms.size} Topological Inventory VMs with Host Inventory")
      updated_topological_inventory_vms = []
      topological_inventory_vms.each do |host|
        # Skip processing if we've already created this host in Host Based
        next if !host["host_inventory_uuid"].nil? && !host["host_inventory_uuid"].empty?

        data         = {
          :display_name  => host["name"],
          :external_id   => host["source_ref"],
          :mac_addresses => host["mac_addresses"],
          :account       => account_number
        }
        created_host = JSON.parse(create_host_inventory_hosts(x_rh_identity, data).body)

        updated_topological_inventory_vms << TopologicalInventoryIngressApiClient::Vm.new(
          :source_ref          => host["source_ref"],
          :host_inventory_uuid => created_host["id"],
        )
      end

      logger.info(
        "Synced #{topological_inventory_vms.size} Topological Inventory VMs with Host Inventory. "\
        "Created: #{updated_topological_inventory_vms.size}, "\
        "Skipped: #{topological_inventory_vms.size - updated_topological_inventory_vms.size}"
      )

      return if updated_topological_inventory_vms.empty?

      logger.info("Updating Topological Inventory with #{updated_topological_inventory_vms.size} VMs.")
      save_vms_to_topological_inventory(updated_topological_inventory_vms, source)
      logger.info("Updated Topological Inventory with #{updated_topological_inventory_vms.size} VMs.")
    rescue => e
      logger.error(e.message)
      logger.error(e.backtrace.join("\n"))
    end

    def save_vms_to_topological_inventory(topological_inventory_vms, source)
      # TODO(lsmola) if VM will have subcollections, this will need to send just partial data, otherwise all subcollections
      # would get deleted. Alternative is having another endpoint than :vms, for doing update only operation. Partial data
      # are not supported without timestamp for update (at least for now), since that is just being added to skeletal
      # precreate.
      ingress_api_client.save_inventory(
        :inventory => TopologicalInventoryIngressApiClient::Inventory.new(
          :schema      => TopologicalInventoryIngressApiClient::Schema.new(:name => "Default"),
          :source      => source,
          :collections => [
            TopologicalInventoryIngressApiClient::InventoryCollection.new(:name => :vms, :data => topological_inventory_vms)
          ],
        )
      )
    end

    def ingress_api_client
      TopologicalInventoryIngressApiClient::DefaultApi.new
    end

    def create_host_inventory_hosts(x_rh_identity, data)
      RestClient::Request.execute(
        :method  => :post,
        :payload => data.to_json,
        :url     => "#{host_inventory_api}v1/hosts",
        :headers => {"Content-Type" => "application/json", "x-rh-identity" => x_rh_identity}
      )
    end

    def get_host_inventory_hosts(x_rh_identity)
      RestClient::Request.execute(
        :method  => :get,
        :url     => "#{host_inventory_api}v1/hosts",
        :headers => {"x-rh-identity" => x_rh_identity}
      )
    end

    def extract_vms(payload)
      vms         = payload.dig("payload", "vms") || {}
      changed_vms = (vms["updated"] || []).map { |x| x["id"] }
      created_vms = (vms["created"] || []).map { |x| x["id"] }
      deleted_vms = (vms["deleted"] || []).map { |x| x["id"] }

      (changed_vms + created_vms + deleted_vms).compact
    end

    def get_topological_inventory_vms(vms, x_rh_identity)
      # TODO(lsmola) replace with batch filtering once Topological Inventory implements that
      vms.map do |id|
        get_topological_inventory_vm(x_rh_identity, id)
      end.compact
    end

    def get_topological_inventory_vm(x_rh_identity, id)
      JSON.parse(
        RestClient::Request.execute(
          :method  => :get,
          :url     => "#{topological_inventory_api}v0.1/vms/#{id}",
          :headers => {"x-rh-identity" => x_rh_identity}).body
      )
    rescue RestClient::NotFound
      logger.info("Vm #{id} was not found in Topological Inventory")
      nil
    end

    def default_messaging_opts
      {
        :protocol   => :Kafka,
        :client_ref => "persister-worker",
        :group_ref  => "persister-worker",
      }
    end
  end
end
