require 'uuidtools'

module UUIDHelper
  def after_validation()
    self.id ||= UUIDTools::UUID.timestamp_create().to_s
  end

  def before_create()
    self.id ||= UUIDTools::UUID.timestamp_create().to_s
    true
  end
end

module VersionFu
  def self.included(base)
    base.extend ClassMethods
  end

  module ClassMethods
    def point_in_time(options={}, &block)
      return if self.included_modules.include? VersionFu::InstanceMethods
      __send__ :include, VersionFu::InstanceMethods
      include UUIDHelper

      cattr_accessor :versioned_columns

      # Setup versions association
      class_eval do
        @@end_of_time = Time.utc(9999, 1, 1, 1, 1)

        has_many :versions, :class_name  => self.to_s,
                            :foreign_key => "base_id",
                            :primary_key => "base_id",
                            :order => "valid_start" do
          def latest
            find :last
          end                    
        end

        named_scope :old_versions, :conditions => ["valid_end != ?", @@end_of_time]

        named_scope :current_versions, :conditions => ["valid_end = ?", @@end_of_time]

        before_save :check_for_new_version

        # find first version before the given version
        def self.before(version)
          find :first, :order => 'valid_start desc',
            :conditions => ["base_id = ? and valid_start < ?", version.base_id, version.valid_start]
        end

        # find first version after the given version.
        def self.after(version)
          find :last, :order => 'valid_start',
            :conditions => ["base_id = ? and valid_start > ?", version.base_id, version.valid_start]
        end

        def previous
          self.class.before(self)
        end

        def next
          self.class.after(self)
        end
      end
      
      # Version parent association
      self.belongs_to self.to_s.demodulize.underscore.to_sym, 
        :class_name  => self.to_s,
        :foreign_key => "base_id"
      
      if self.table_exists?
        # Finally setup which columns to version
        self.versioned_columns =  new.attributes.keys - 
          ['created_at', 'updated_at', 'valid_start', 'valid_end', 'base_id']
      else
        ActiveRecord::Base.logger.warn "Base Table not found"
      end
    end

  end


  module InstanceMethods
    @@end_of_time = Time.utc(9999, 1, 1, 1, 1)

    def find_version(date)
      versions.find :first, :conditions=>['valid_start <= ? and valid_end > ?', date, date]
    end
    
    def now_rounded
      now = Time.now.xmlschema
      Time.xmlschema(now)
    end

    def check_for_new_version
      #three possible cases:
      if !id && !base_id
          #a totally new object
          self.id = UUIDTools::UUID.timestamp_create().to_s
          self.base_id = id          
          self.valid_start = now_rounded
          self.valid_end = @@end_of_time
      elsif id && base_id
          #an edit to an existing object; may need to create a new
          #version
          instantiate_revision if create_new_version? && base_id != id
      elsif !id && base_id
          #a new version automatically created; no need to make a new version
          self.id = UUIDTools::UUID.timestamp_create().to_s
      end
      
      true # Never halt save
    end
    
    # This the method to override if you want to have more control over when to version
    def create_new_version?
      # Any versioned column changed?
      self.class.versioned_columns.detect {|a| __send__ "#{a}_changed?"}
    end
    
    def instantiate_revision
      new_version = versions.build
      versioned_columns.each do |attribute|
        new_version.__send__ "#{attribute}=", __send__(attribute)
      end

      new_version.valid_start = valid_start
      new_version.valid_end = now_rounded
      new_version.base_id = id

      self.valid_start = new_version.valid_end
      self.valid_end = @@end_of_time
    end

    def end_of_time
      return @@end_of_time
     end

  end
end
