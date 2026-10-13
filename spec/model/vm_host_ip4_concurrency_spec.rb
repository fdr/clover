# frozen_string_literal: true

require_relative "spec_helper"

# Concurrent allocations on one host must pick different IPv4 addresses
# instead of colliding on assigned_vm_address's unique key. This needs two
# real DB connections, so it opts out of the wrapping rollback-only
# transaction and cleans up its own committed rows.
RSpec.describe VmHost, :no_db_transaction do
  let(:vm_host) { create_vm_host }

  before { @skip_leaked_thread_check = true }

  after do
    DB[:ipv4_address].where(cidr: DB[:address].where(routed_to_host_id: vm_host.id).select(:cidr)).delete
    DB[:address].where(routed_to_host_id: vm_host.id).delete
    DB[:vm_host].where(id: vm_host.id).delete
    DB[:sshable].where(id: vm_host.id).delete
  end

  # Runs the block while another allocation has picked an address on the
  # host and not committed, and yields that address.
  def while_another_allocation_picks
    picked = Queue.new
    release = Queue.new
    other = Thread.new do
      DB.transaction do
        picked.push(vm_host.ip4_random_vm_network.first.to_s)
        release.pop
      end
    rescue => e
      picked.push(e)
    end

    begin
      ip = picked.pop(timeout: 10)
      raise ip if ip.is_a?(Exception)
      raise "the other allocation did not pick in time" if ip.nil?
      raise "the other allocation found no address" if ip.empty?

      DB.transaction(rollback: :always) do
        DB.run("SET LOCAL lock_timeout = '1s'")
        yield ip
      end
    ensure
      release.push(true)
      other.join(5)
    end
  end

  it "picks an address that another allocation has not picked" do
    Address.create(cidr: "128.0.0.0/31", routed_to_host_id: vm_host.id).populate_ipv4_addresses
    while_another_allocation_picks do |taken|
      # The pick is random, so pick more than once.
      picks = Array.new(8) { vm_host.ip4_random_vm_network.first&.to_s }
      expect(picks.uniq).to eq(["128.0.0.0", "128.0.0.1"] - [taken])
    end
  end

  it "finds no address, without waiting, when another allocation has picked the last one" do
    Address.create(cidr: "128.0.0.0/32", routed_to_host_id: vm_host.id).populate_ipv4_addresses
    while_another_allocation_picks do
      expect(vm_host.ip4_random_vm_network).to eq([nil, nil])
    end
  end
end
