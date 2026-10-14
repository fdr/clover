# frozen_string_literal: true

require_relative "spec_helper"

# Two allocations give their VMs the same random ephemeral_net6. The second
# must wait for the first, and then retry with another subnet. This needs two
# real DB connections, so it opts out of the wrapping rollback-only
# transaction and cleans up its own committed rows.
RSpec.describe Vm, :no_db_transaction do
  let(:vm_host) { create_vm_host(net6: "fd10:9b0b:6b4b:8fb0::/64") }
  let(:project) { Project.create(name: "net6-retry") }
  let(:vms) { Array.new(2) { create_vm(project_id: project.id, name: "net6-retry-#{it}") } }

  before { @skip_leaked_thread_check = true }

  after do
    DB[:vm].where(id: vms.map(&:id)).delete
    DB[:project].where(id: project.id).delete
    DB[:vm_host].where(id: vm_host.id).delete
    DB[:sshable].where(id: vm_host.id).delete
  end

  def waiting_on_a_lock?
    DB[:pg_stat_activity].where(datname: DB.get(Sequel.function(:current_database)), wait_event_type: "Lock").count > 0
  end

  it "retries with another subnet when a concurrent allocation takes the same one" do
    vms
    net6 = vm_host.ip6_random_vm_network.to_s
    saved = Queue.new
    release = Queue.new
    first = Thread.new do
      DB.transaction do
        vms[0].update(ephemeral_net6: net6)
        saved.push(true)
        release.pop
      end
    end

    begin
      raise "the first allocation did not save" unless saved.pop(timeout: 10)

      second = Thread.new do
        DB.transaction do
          vms[1].set(vm_host_id: vm_host.id, ephemeral_net6: net6)
          vms[1].save_with_ephemeral_net6_error_retrying(vm_host)
        end
      end
      # Commit the first allocation once the second waits on its row.
      deadline = Time.now + 10
      sleep 0.01 until waiting_on_a_lock? || Time.now > deadline
    ensure
      release.push(true)
      first.join(5)
    end

    second.value
    vms.each(&:reload)
    expect(vms[1].ephemeral_net6.to_s).not_to eq(net6)
    # The retry saves every column the first attempt would have saved.
    expect(vms[1].vm_host_id).to eq(vm_host.id)
    expect(vms[0].ephemeral_net6.to_s).to eq(net6)
  end
end
