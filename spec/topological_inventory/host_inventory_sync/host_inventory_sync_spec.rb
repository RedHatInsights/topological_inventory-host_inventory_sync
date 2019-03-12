require "topological_inventory/host_inventory_sync"

RSpec.describe TopologicalInventory::HostInventorySync do
  context "#topological_inventory_api (private)" do
    it "returns the initial url if provided" do
      expect(described_class.new("http://example.com/api/", "", "", 9092).send(:topological_inventory_api)).to eq("http://example.com/api/")
    end

    context "with service env vars set" do
      let(:url) { described_class.new(nil, "", "", 9092).send(:topological_inventory_api) }

      before do
        stub_const("ENV", {"TOPOLOGICAL_INVENTORY_API_SERVICE_HOST" => "example.com", "TOPOLOGICAL_INVENTORY_API_SERVICE_PORT" => "8080"})
      end

      it "returns a sane value" do
        expect(url).to eq("http://example.com:8080/v0.1")
      end

      context "with APP_NAME set" do
        before { ENV["APP_NAME"] = "topological-inventory" }

        it "includes the APP_NAME" do
          expect(url).to eq("http://example.com:8080/topological-inventory/v0.1")
        end

        it "uses the PATH_PREFIX with a leading slash" do
          ENV["PATH_PREFIX"] = "/this/is/a/path"
          expect(url).to eq("http://example.com:8080/this/is/a/path/topological-inventory/v0.1")
        end

        it "uses the PATH_PREFIX without a leading slash" do
          ENV["PATH_PREFIX"] = "also/a/path"
          expect(url).to eq("http://example.com:8080/also/a/path/topological-inventory/v0.1")
        end
      end
    end
  end

  context "#process_message" do
    let(:message) do
      OpenStruct.new(
        :payload => {
          "external_tenant" => account_number,
          "source"          => source,
          "payload"         => {
            "vms" => {
              "updated" => [{"id" => 1}, {"id" => 2}],
              "created" => [{"id" => 3}],
              "deleted" => [{"id" => 4}, {"id" => 5}],
            }
          }
        }
      )
    end

    let(:account_number) { "external_tenant_uuid" }
    let(:source) { "source_uuid" }

    let(:host_inventory_sync) do
      TopologicalInventory::HostInventorySync.new(
        "http://mock/api/", "http://mock/api/", "localhost", 9092)
    end

    let(:mac_addresses_1) { ["06:d5:e7:4e:c8:01", "06:d5:e7:4e:c7:01"] }
    let(:mac_addresses_2) { ["06:d5:e7:4e:c8:02"] }
    let(:mac_addresses_3) { ["06:d5:e7:4e:c8:03"] }
    let(:mac_addresses_5) { ["06:d5:e7:4e:c8:04"] }

    it "sends new hosts for create" do
      host_inventory_sync_service = host_inventory_sync
      logger                      = double
      allow(host_inventory_sync_service).to receive(:logger).and_return(logger)
      allow(logger).to receive(:info).exactly(7).times

      expect(host_inventory_sync_service).to(
        receive(:get_topological_inventory_vms)
          .with([1, 2, 3, 4, 5], "eyJpZGVudGl0eSI6eyJhY2NvdW50X251bWJlciI6ImV4dGVybmFsX3RlbmFu\ndF91dWlkIn19\n")
          .and_return(
            [
              {"id" => "1", "source_ref" => "vm1", "mac_addresses" => mac_addresses_1},
              {"id" => "2", "source_ref" => "vm2", "mac_addresses" => mac_addresses_2, "host_inventory_uuid" => ""},
              {"id" => "3", "source_ref" => "vm3", "mac_addresses" => mac_addresses_3, "host_inventory_uuid" => nil},
              {"id" => "4", "source_ref" => "vm4", "mac_addresses" => []},
              {"id" => "5", "source_ref" => "vm5", "mac_addresses" => mac_addresses_5, "host_inventory_uuid" => "host_uuid_5"},
            ]
          )
      )

      expect(host_inventory_sync_service).to(
        receive(:create_host_inventory_hosts)
          .with(*make_host_arg(mac_addresses_1, "vm1"))
          .and_return(
            mock_body({"id" => "host_uuid_1"})
          )
      )

      expect(host_inventory_sync_service).to(
        receive(:create_host_inventory_hosts)
          .with(*make_host_arg(mac_addresses_2, "vm2"))
          .and_return(
            mock_body({"id" => "host_uuid_2"})
          )
      )

      expect(host_inventory_sync_service).to(
        receive(:create_host_inventory_hosts)
          .with(*make_host_arg(mac_addresses_3, "vm3"))
          .and_return(
            mock_body({"id" => "host_uuid_3"})
          )
      )

      expect(host_inventory_sync_service).to(
        receive(:create_host_inventory_hosts)
          .with(*make_host_arg([], "vm4"))
          .and_return(
            mock_body({"id" => "host_uuid_4"})
          )
      )

      expect(host_inventory_sync_service).to(
        receive(:save_vms_to_topological_inventory).with(
          [
            TopologicalInventoryIngressApiClient::Vm.new(:source_ref => "vm1", :host_inventory_uuid => "host_uuid_1"),
            TopologicalInventoryIngressApiClient::Vm.new(:source_ref => "vm2", :host_inventory_uuid => "host_uuid_2"),
            TopologicalInventoryIngressApiClient::Vm.new(:source_ref => "vm3", :host_inventory_uuid => "host_uuid_3"),
            TopologicalInventoryIngressApiClient::Vm.new(:source_ref => "vm4", :host_inventory_uuid => "host_uuid_4"),
          ],
          source
        )
      )

      host_inventory_sync_service.send(:process_message, message)
    end

    it "skips processing when no VMs are found" do
      host_inventory_sync_service = host_inventory_sync
      logger                      = double
      allow(host_inventory_sync_service).to receive(:logger).and_return(logger)
      allow(logger).to receive(:info).exactly(5).times

      message = OpenStruct.new(
        :payload => {
          "external_tenant" => account_number,
          "source"          => source,
          "payload"         => {
          }
        }
      )

      expect(host_inventory_sync_service.send(:process_message, message)).to be_nil
    end

    it "skips processing when external tenant is missing" do
      host_inventory_sync_service = host_inventory_sync
      logger                      = double
      allow(host_inventory_sync_service).to receive(:logger).and_return(logger)
      allow(logger).to receive(:info).exactly(3).times
      allow(logger).to receive(:error).with(/Skipping payload because of missing :external_tenant/)

      message = OpenStruct.new(
        :payload => {
          "source"  => source,
          "payload" => {
          }
        }
      )

      expect(host_inventory_sync_service.send(:process_message, message)).to be_nil
    end
  end

  def make_host_arg(mac_addresses, source_ref)
    [
      "eyJpZGVudGl0eSI6eyJhY2NvdW50X251bWJlciI6ImV4dGVybmFsX3RlbmFu\ndF91dWlkIn19\n",
      {
        :mac_addresses => mac_addresses,
        :account       => account_number,
        :external_id   => source_ref,
        :display_name  => nil
      }
    ]
  end

  def mock_body(body)
    OpenStruct.new(
      :body => body.to_json
    )
  end
end
