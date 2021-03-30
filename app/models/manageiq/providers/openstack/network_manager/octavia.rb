class ManageIQ::Providers::Openstack::NetworkManager::Octavia < ::LoadBalancer
  include ManageIQ::Providers::Openstack::HelperMethods

  supports :create

  supports :delete do
    if ext_management_system.nil?
      unsupported_reason_add(:delete_security_group, _("The Security Group is not connected to an active %{table}") % {
          :table => ui_lookup(:table => "ext_management_systems")
      })
    end
  end

  supports :update do
    if ext_management_system.nil?
      unsupported_reason_add(:update_security_group, _("The Security Group is not connected to an active %{table}") % {
          :table => ui_lookup(:table => "ext_management_systems")
      })
    end
  end

  def self.parse_load_balancer(options)
    {
      :description       => "LBaaS",
      :admin_state_up    => true,
      :project_id        => options[:project_id],
      :flavor_id         => "",
      :listeners         => [
        {
          :name          => "http_listener",
          :protocol      => options[:protocol],
          :protocol_port => options[:protocol_port],
          :default_pool  => {
            :name          => "rr_pool",
            :protocol      => options[:protocol],
            :lb_algorithm  => options[:methods],
            :healthmonitor => {
              :type           => options[:healthmonitor_type],
              :delay          => "3",
              :expected_codes => "200,201,202",
              :http_method    => "GET",
              :max_retries    => 2,
              :timeout        => 1,
              :url_path       => "/index.html"
            },
            :members       => [
              {
                :address       => "192.0.2.16",
                :protocol_port => 80
              },
              {
                :address       => "192.0.2.19",
                :protocol_port => 80
              }
            ]
          }
        },
        {
          :name          => "https_listener",
          :protocol      => "HTTPS",
          :protocol_port => 443,
          :default_pool  => {
            :name => "https_pool"
          },
          :tags          => ["test_tag"]
        },
        {
          :name          => "redirect_listener",
          :protocol      => "HTTP",
          :protocol_port => 8080,
          :l7policies    => [
            {
              :action         => "REDIRECT_TO_URL",
              :name           => "redirect_policy",
              :redirect_url   => "https =>//www.example.com/",
              :admin_state_up => true
            }
          ]
        }
      ],
      :pools             => [
        {
          :name          => "https_pool",
          :protocol      => options[:protocol],
          :lb_algorithm  => options[:methods],
          :healthmonitor => {
            :type       => "HTTPS",
            :delay      => "3",
            :max_retrie => 2,
            :timeout    => 1
          },
          :members       => [
            {
              :address       => options[:members_ip],
              :protocol_port => options[:members_port]
            },
          ]
        }
      ],
      :vip_subnet_id     => options[:vip_subnet_id],
      :vip_address       => "",
      :provider          => "octavia",
      :name              => "load_balancer",
      :vip_qos_policy_id => "ec4f78ca-8da8-4e99-8a1a-e3b94595a7a3",
      :availability_zone => options[:availability_zone],
      :tags              => [""]
    }
  end

  # Load_Balancer
  def self.raw_create_load_balancer(ext_management_system, vip_subnet_id, options)
    cloud_tenant = options.delete(:cloud_tenant)
    input_lb = parse_load_balancer(options)
    load_balancer = nil
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      load_balancer = service.create_lbaas_loadbalancer(vip_subnet_id, input_lb).body
    end
  rescue => e
    _log.error("load_balancer=[#{options[:name]}], error: #{e}")
    raise MiqException::MiqLoadBalancerProvisionError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def raw_update_load_balancer(_load_balancer_id, options)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      service.update_lbaas_loadbalancer(ems_ref, options)
    end
  rescue => e
    _log.error("load_balancer=[#{name}], error: #{e}")
    raise MiqException::MiqLoadBalancerUpdateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def raw_delete_load_balancer(load_balancer_id, listener_id, pool_id)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      service.delete_lbaas_pool(pool_id)
      service.delete_lbaas_listener(listener_id)
      service.delete_lbaas_loadbalancer(load_balancer_id)
    end
  rescue => e
    _log.error("load_balancer=[#{name}], error: #{e}")
    raise MiqException::MiqLoadBalancerDeleteError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def update_load_balancer_queue(userid, load_balancer_id, options = {})
    task_opts = {
      :action => "updating Load Balancer for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'raw_update_load_balancer',
      :instance_id => id,
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => ext_management_system.my_zone,
      :args        => [load_balancer_id, options]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def delete_load_balancer_queue(userid, load_balancer_id, listener_id, pool_id)
    task_opts = {
      :action => "deleting Load Balancer for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'raw_delete_load_balancer',
      :instance_id => id,
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => ext_management_system.my_zone,
      :args        => [load_balancer_id, listener_id, pool_id]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  # Load_Balancer Listeners
  def self.raw_create_lb_listeners(ext_management_system, loadbalancer_id, protocol, protocol_port, options)
    cloud_tenant = options.delete(:cloud_tenant)
    lb_listeners = nil
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      lb_listeners = service.create_lbaas_listener(loadbalancer_id, protocol, protocol_port, options).body
    end
  rescue => e
    _log.error("load_balancer_listeners=[#{options[:name]}], error: #{e}")
    raise MiqException::MiqLoadBalancerProvisionError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def raw_update_lb_listeners(listener_id, options)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      service.update_lbaas_listener(listener_id, options)
    end
  rescue => e
    _log.error("load_balancer_listeners=[#{name}], error: #{e}")
    raise MiqException::MiqLoadBalancerUpdateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def raw_delete_lb_listeners(listener_id)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      service.delete_lbaas_listener(listener_id)
    end
  rescue => e
    _log.error("load_balancer_listeners=[#{name}], error: #{e}")
    raise MiqException::MiqLoadBalancerDeleteError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def update_lb_listeners_queue(userid, load_balancer_id, options = {})
    task_opts = {
        :action => "updating Load Balancer for user #{userid}",
        :userid => userid
    }
    queue_opts = {
        :class_name  => self.class.name,
        :method_name => 'raw_update_lb_listeners',
        :instance_id => id,
        :priority    => MiqQueue::HIGH_PRIORITY,
        :role        => 'ems_operations',
        :zone        => ext_management_system.my_zone,
        :args        => [load_balancer_id, options]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def delete_lb_listeners_queue(userid, listener_id)
    task_opts = {
        :action => "deleting Load Balancer for user #{userid}",
        :userid => userid
    }
    queue_opts = {
        :class_name  => self.class.name,
        :method_name => 'raw_delete_lb_listeners',
        :instance_id => id,
        :priority    => MiqQueue::HIGH_PRIORITY,
        :role        => 'ems_operations',
        :zone        => ext_management_system.my_zone,
        :args        => [listener_id]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  # Load_Balancer_Pools
  def self.raw_create_lb_pools(ext_management_system, listener_id, protocol, lb_algorithm, options)
    cloud_tenant = options.delete(:cloud_tenant)
    lb_pools = nil
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      lb_pools = service.create_lbaas_pool(listener_id, protocol, lb_algorithm, options).body
    end
  rescue => e
    _log.error("load_balancer_pools=[#{options[:name]}], error: #{e}")
    raise MiqException::MiqLoadBalancerProvisionError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def raw_update_lb_pools(pool_id, options)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      service.update_lbaas_pool(pool_id, options)
    end
  rescue => e
    _log.error("load_balancer_pools=[#{name}], error: #{e}")
    raise MiqException::MiqLoadBalancerUpdateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def raw_delete_lb_pools(pool_id)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      service.delete_lbaas_pool(pool_id)
    end
  rescue => e
    _log.error("load_balancer_pools=[#{name}], error: #{e}")
    raise MiqException::MiqLoadBalancerDeleteError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def update_lb_pools_queue(userid, pool_id, options = {})
    task_opts = {
        :action => "updating Load Balancer for user #{userid}",
        :userid => userid
    }
    queue_opts = {
        :class_name  => self.class.name,
        :method_name => 'raw_update_lb_pools',
        :instance_id => id,
        :priority    => MiqQueue::HIGH_PRIORITY,
        :role        => 'ems_operations',
        :zone        => ext_management_system.my_zone,
        :args        => [pool_id, options]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def delete_lb_pools_queue(userid, pool_id)
    task_opts = {
        :action => "deleting Load Balancer for user #{userid}",
        :userid => userid
    }
    queue_opts = {
        :class_name  => self.class.name,
        :method_name => 'raw_delete_lb_pools',
        :instance_id => id,
        :priority    => MiqQueue::HIGH_PRIORITY,
        :role        => 'ems_operations',
        :zone        => ext_management_system.my_zone,
        :args        => [pool_id]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  # Load_Balancer_Pool_Members
  def self.raw_create_lb_pool_members(ext_management_system, pool_id, address, protocol_port, options)
    cloud_tenant = options.delete(:cloud_tenant)
    lb_pool_members = nil
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      lb_pool_members = service.create_lbaas_pool_member(pool_id, address, protocol_port, options).body
    end
  rescue => e
    _log.error("load_balancer_pool_members=[#{options[:name]}], error: #{e}")
    raise MiqException::MiqLoadBalancerProvisionError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def raw_update_lb_pool_members(pool_id, member_id, options)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      service.update_lbaas_pool_member(pool_id, member_id, options)
    end
  rescue => e
    _log.error("load_balancer_pool_members=[#{name}], error: #{e}")
    raise MiqException::MiqLoadBalancerUpdateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def raw_delete_lb_pool_members(pool_id, member_id)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      service.delete_lbaas_pool_member(pool_id, member_id)
    end
  rescue => e
    _log.error("load_balancer_pool_members=[#{name}], error: #{e}")
    raise MiqException::MiqLoadBalancerDeleteError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def update_lb_pool_members_queue(userid, pool_id, member_id, options = {})
    task_opts = {
        :action => "updating Load Balancer for user #{userid}",
        :userid => userid
    }
    queue_opts = {
        :class_name  => self.class.name,
        :method_name => 'raw_update_lb_pool_members',
        :instance_id => id,
        :priority    => MiqQueue::HIGH_PRIORITY,
        :role        => 'ems_operations',
        :zone        => ext_management_system.my_zone,
        :args        => [pool_id, member_id, options]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def delete_lb_pool_members_queue(pool_id, member_id)
    task_opts = {
        :action => "deleting Load Balancer Pool Members for user #{userid}",
        :userid => userid
    }
    queue_opts = {
        :class_name  => self.class.name,
        :method_name => 'raw_delete_lb_pool_members',
        :instance_id => id,
        :priority    => MiqQueue::HIGH_PRIORITY,
        :role        => 'ems_operations',
        :zone        => ext_management_system.my_zone,
        :args        => [pool_id, member_id]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  # Load_Balancer_Health
  def self.raw_create_lb_health(ext_management_system, pool_id, type, delay, timeout, max_retries, options)
    cloud_tenant = options.delete(:cloud_tenant)
    lb_health = nil
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      lb_health = service.create_lbaas_healthmonitor(pool_id, type, delay, timeout, max_retries, options).body
    end
  rescue => e
    _log.error("load_balancer_health=[#{options[:name]}], error: #{e}")
    raise MiqException::MiqLoadBalancerProvisionError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def raw_update_lb_health(healthmonitor_id, options)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      service.update_lbaas_healthmonitor(healthmonitor_id, options)
    end
  rescue => e
    _log.error("load_balancer_health=[#{name}], error: #{e}")
    raise MiqException::MiqLoadBalancerUpdateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def raw_delete_lb_health(healthmonitor_id)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      service.delete_lbaas_healthmonitor(healthmonitor_id)
    end
  rescue => e
    _log.error("load_balancer_health=[#{name}], error: #{e}")
    raise MiqException::MiqLoadBalancerDeleteError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def create_lb_health_queue(userid, options = {})
    task_opts = {
        :action => "create Load Balancer Health for user #{userid}",
        :userid => userid
    }
    queue_opts = {
        :class_name  => self.class.name,
        :method_name => 'raw_create_lb_health',
        :instance_id => id,
        :priority    => MiqQueue::HIGH_PRIORITY,
        :role        => 'ems_operations',
        :zone        => ext_management_system.my_zone,
        :args        => [pool_id, type, delay, timeout, max_retries, options]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def update_lb_health_queue(userid, healthmonitor_id, options = {})
    task_opts = {
        :action => "updating Load Balancer Health for user #{userid}",
        :userid => userid
    }
    queue_opts = {
        :class_name  => self.class.name,
        :method_name => 'raw_update_lb_health',
        :instance_id => id,
        :priority    => MiqQueue::HIGH_PRIORITY,
        :role        => 'ems_operations',
        :zone        => ext_management_system.my_zone,
        :args        => [healthmonitor_id, options]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def delete_lb_health_queue(userid, healthmonitor_id)
    task_opts = {
        :action => "deleting Load Balancer Health for user #{userid}",
        :userid => userid
    }
    queue_opts = {
        :class_name  => self.class.name,
        :method_name => 'raw_delete_lb_health',
        :instance_id => id,
        :priority    => MiqQueue::HIGH_PRIORITY,
        :role        => 'ems_operations',
        :zone        => ext_management_system.my_zone,
        :args        => [healthmonitor_id]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def self.connection_options(cloud_tenant = nil)
    connection_options = {:service => "load-balancer"}
    connection_options[:tenant_name] = cloud_tenant.name if cloud_tenant
    connection_options
  end

  def self.display_name(number = 1)
    n_('Load Balancer (OpenStack)', 'Load Balancer (OpenStack)', number)
  end

  private

  def connection_options(cloud_tenant = nil)
    self.class.connection_options(cloud_tenant)
  end
end
