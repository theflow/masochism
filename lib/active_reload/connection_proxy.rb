module ActiveReload
  class MasterDatabase < ActiveRecord::Base
    self.abstract_class = true
    establish_connection configurations[RAILS_ENV]['master_database'] || configurations['master_database'] || RAILS_ENV
  end

  class SlaveDatabase < ActiveRecord::Base
    self.abstract_class = true
    def self.name
      ActiveRecord::Base.name
    end
    establish_connection configurations[RAILS_ENV]['slave_database'] || RAILS_ENV
  end

  class ConnectionProxy
    def initialize(master, slave)
      @slave   = slave.connection
      @master  = master.connection
      @current = @slave
    end

    attr_accessor :slave, :master

    def self.setup!
      if slave_defined?
        setup_for ActiveReload::MasterDatabase, ActiveReload::SlaveDatabase
      else
        setup_for ActiveReload::MasterDatabase
      end
    end

    def self.slave_defined?
      ActiveRecord::Base.configurations[RAILS_ENV]['slave_database']
    end

    def self.setup_for(master, slave = nil)
      slave ||= ActiveRecord::Base
      slave.send :include, ActiveRecordConnectionMethods
      ActiveRecord::Observer.send :include, ActiveReload::ObserverExtensions
      ActiveRecord::Base.active_connections[slave.name] = new(master, slave)
    end

    def with_master
      set_to_master!
      yield
    ensure
      set_to_slave!
    end

    def set_to_master!
      return if @current == @master

      logger.info "Switching to Master"
      @current = @master
    end

    def set_to_slave!
      return if @current == @slave

      logger.info "Switching to Slave"
      @current = @slave
    end

    delegate :insert, :update, :delete, :create_table, :rename_table, :drop_table, :add_column, :remove_column,
      :change_column, :change_column_default, :rename_column, :add_index, :remove_index, :initialize_schema_information,
      :dump_schema_information, :execute, :columns, :to => :master

    def transaction(start_db_transaction = true, &block)
      with_master { @current.transaction(start_db_transaction, &block) }
    end

    def method_missing(method, *args, &block)
      @current.send(method, *args, &block)
    end
  end

  module ActiveRecordConnectionMethods
    def self.included(base)
      base.alias_method_chain :reload, :master
    end

    def reload_with_master(*args, &block)
      if connection.class.name == "ActiveReload::ConnectionProxy"
        connection.with_master { reload_without_master }
      else
        reload_without_master
      end
    end
  end

  # extend observer to always use the master database
  # observers only get triggered on writes, so shouldn't be a performance hit
  # removes a race condition if you are using conditionals in the observer
  module ObserverExtensions
    def self.included(base)
      base.alias_method_chain :update, :masterdb
    end

    # Send observed_method(object) if the method exists.
    def update_with_masterdb(observed_method, object) #:nodoc:
      if object.class.connection.respond_to?(:with_master)
        object.class.connection.with_master do
          update_without_masterdb(observed_method, object)
        end
      else
        update_without_masterdb(observed_method, object)
      end
    end
  end
end
