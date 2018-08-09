# frozen_string_literal: true

# Copyright 2018 Tristan Robert

# This file is part of ForemanFogProxmox.

# ForemanFogProxmox is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# ForemanFogProxmox is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with ForemanFogProxmox. If not, see <http://www.gnu.org/licenses/>.

require 'test_plugin_helper'
require 'models/compute_resources/compute_resource_test_helpers'
require 'unit/foreman_fog_proxmox/proxmox_test_helpers'

module ForemanFogProxmox

  class ProxmoxTest < ActiveSupport::TestCase
    include ComputeResourceTestHelpers
    include ForemanFogProxmox::ProxmoxTestHelpers

    should validate_presence_of(:url)
    should validate_presence_of(:user)
    should validate_presence_of(:password)
    should allow_value('root@pam').for(:user)
    should_not allow_value('root').for(:user)
    should_not allow_value('a').for(:url)
    should allow_values('http://foo.com', 'http://bar.com/baz').for(:url)

    test "#associated_host matches any NIC" do
      mac = 'ca:d0:e6:32:16:97'
      host = FactoryBot.create(:host, :mac => mac)
      cr = FactoryBot.build_stubbed(:proxmox_cr)
      vm = mock('vm', :mac => mac)
      assert_equal host, (as_admin { cr.associated_host(vm) })
    end

    describe "destroy_vm" do
      it "handles situation when vm is not present" do
        cr = mock_cr_servers(ForemanFogProxmox::Proxmox.new, empty_servers)
        cr.expects(:find_vm_by_uuid).raises(ActiveRecord::RecordNotFound)
        assert cr.destroy_vm('abc')
      end
    end

    describe "find_vm_by_uuid" do
      it "raises Foreman::Exception when the uuid does not match" do
        cr = mock_node_servers(ForemanFogProxmox::Proxmox.new, empty_servers)
        assert_raises Foreman::Exception do
          cr.find_vm_by_uuid('100')
        end
      end
  
      it "raises RecordNotFound when the compute raises retrieve error" do
        exception = Fog::Proxmox::Errors::ServiceError.new(StandardError.new('VM not found'))
        cr = mock_node_servers(ForemanFogProxmox::Proxmox.new, servers_raising_exception(exception))
        assert_raises ActiveRecord::RecordNotFound do
          cr.find_vm_by_uuid('qemu_100')
        end
      end
    end

    describe "host_interfaces_attrs" do
      before do
        @cr = FactoryBot.build_stubbed(:proxmox_cr)
      end
  
      it "raises Foreman::Exception when physical identifier is empty" do
        physical_nic = FactoryBot.build(:nic_base_empty)
        host = FactoryBot.build(:host_empty, :interfaces => [physical_nic])
        err = assert_raises Foreman::Exception do
          @cr.host_interfaces_attrs(host)
        end
        assert err.message.end_with?('Identifier interface[0] required.')
      end
  
      it "raises Foreman::Exception when physical identifier does not match net[k] with k integer" do
        physical_nic = FactoryBot.build(:nic_base_empty, :identifier => 'eth0')
        host = FactoryBot.build(:host_empty, :interfaces => [physical_nic])
        err = assert_raises Foreman::Exception do
          @cr.host_interfaces_attrs(host)
        end
        assert err.message.end_with?('Invalid identifier interface[0]. Must be net[n] with n integer >= 0')
      end
  
      it "sets compute id with identifier, ip and ip6" do
        ip = IPAddr.new(1, Socket::AF_INET).to_s
        ip6 = Array.new(4) { '%x' % rand(16**4) }.join(':') + '::1'
        physical_nic = FactoryBot.build(:nic_base_empty, :identifier => 'net0', :ip => ip, :ip6 => ip6)
        host = FactoryBot.build(:host_empty, :interfaces => [physical_nic])
        nic_attributes = @cr.host_interfaces_attrs(host).values.select(&:present?)
        nic_attr = nic_attributes.first
        assert_equal 'net0', nic_attr[:id]
        assert_equal ip, nic_attr[:ip]
        assert_equal ip6, nic_attr[:ip6]
      end
    end

    describe "host_compute_attrs" do
      before do
        @cr = FactoryBot.build_stubbed(:proxmox_cr)
      end
  
      it "raises Foreman::Exception when server ostype does not match os family" do
        operatingsystem = FactoryBot.build(:solaris)
        physical_nic = FactoryBot.build(:nic_base_empty, :identifier => 'net0', :primary => true)
        host = FactoryBot.build(:host_empty, :interfaces => [physical_nic], :operatingsystem => operatingsystem, :compute_attributes => { 'type' => 'qemu', 'config_attributes' => { 'ostype' => 'l26' } })
        err = assert_raises Foreman::Exception do
          @cr.host_compute_attrs(host)
        end
        assert err.message.end_with?('Operating system family Solaris is not consistent with l26')
      end

      it "sets container hostname with host name" do
        physical_nic = FactoryBot.build(:nic_base_empty, :identifier => 'net0', :primary => true)
        host = FactoryBot.build(:host_empty, :interfaces => [physical_nic], :compute_attributes => { 'type' => 'lxc', 'config_attributes' => { 'hostname' => '' } })
        @cr.host_compute_attrs(host)
        assert_equal host.name, host.compute_attributes['config_attributes']['hostname']
      end
    end


  describe 'save_vm' do
    before do
      @cr = FactoryBot.build_stubbed(:proxmox_cr)
    end

    it 'saves modified server config' do
      uuid = 'qemu_100'
      config = mock('config')
      config.stubs(:attributes).returns({ :cores => '' })
      vm = mock('vm')
      vm.stubs(:config).returns(config)
      vm.stubs(:container?).returns(false)
      @cr.stubs(:find_vm_by_uuid).returns(vm)
      attr = { 'vmid' => '100', 'type' => 'qemu', 'node' => 'pve', 'templated' => '0', 'config_attributes' => { 'cores' => '1', 'cpulimit' => '1' } }
      @cr.stubs(:parse_server_vm).returns({ 'vmid' => '100', 'cores' => '1', 'cpulimit' => '1' })
      expected_attr = { :cores => '1', :cpulimit => '1' }
      vm.expects(:update, expected_attr)
      @cr.save_vm(uuid,attr)
    end

    it 'saves modified container config' do
      uuid = 'lxc_100'
      config = mock('config')
      config.stubs(:attributes).returns({ :cores => '' })
      vm = mock('vm')
      vm.stubs(:config).returns(config)
      vm.stubs(:container?).returns(true)
      @cr.stubs(:find_vm_by_uuid).returns(vm)
      attr = { 'vmid' => '100', 'type' => 'lxc', 'node' => 'pve', 'templated' => '0', 'config_attributes' => { 'cores' => '1', 'cpulimit' => '1' } }
      @cr.stubs(:parse_container_vm).returns({ 'vmid' => '100', 'cores' => '1', 'cpulimit' => '1' })
      expected_attr = { :cores => '1', :cpulimit => '1' }
      vm.expects(:update, expected_attr)
      @cr.save_vm(uuid,attr)
    end
  end


  end
end
