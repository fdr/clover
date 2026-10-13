# frozen_string_literal: true

require_relative "spec_helper"

# Concurrent allocations must pick different IPv4 addresses instead of both
# picking one and colliding on assigned_vm_address's unique key. This needs
# two real DB connections, so it opts out of the wrapping rollback-only
# transaction and cleans up its own committed rows.
RSpec.describe VmHost, :no_db_transaction do
  let(:vm_host) { create_vm_host }
  let!(:address) { Address.create(cidr: "128.0.0.0/30", routed_to_host_id: vm_host.id).tap(&:populate_ipv4_addresses) }

  before { @skip_leaked_thread_check = true }

  after do
    DB[:ipv4_address].where(cidr: address.cidr).delete
    DB[:address].where(id: address.id).delete
    DB[:vm_host].where(id: vm_host.id).delete
    DB[:sshable].where(id: vm_host.id).delete
  end

  def with_locked_addresses(ips)
    ready = Queue.new
    release = Queue.new
    holder = Thread.new do
      DB.transaction do
        DB[:ipv4_address].where(ip: ips.map { Sequel.cast(it, :inet) }).for_update.all
        ready.push(true)
        release.pop
      end
    end

    begin
      raise "holder never locked addresses" unless ready.pop(timeout: 10)

      DB.transaction(rollback: :always) do
        DB.run("SET LOCAL lock_timeout = '1s'")
        yield
      end
    ensure
      release.push(true)
      holder.join(5)
    end
  end

  it "skips addresses another allocation has picked but not yet committed" do
    with_locked_addresses(%w[128.0.0.0 128.0.0.1 128.0.0.2]) do
      expect(vm_host.ip4_random_vm_network.first.to_s).to eq("128.0.0.3")
    end
  end

  it "finds no address rather than waiting when every free one is picked" do
    with_locked_addresses(%w[128.0.0.0 128.0.0.1 128.0.0.2 128.0.0.3]) do
      expect(vm_host.ip4_random_vm_network).to eq([nil, nil])
    end
  end
end
