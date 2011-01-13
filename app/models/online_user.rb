#noinspection RubyResolve
require 'digest/sha1'

class OnlineUser < ActiveRecord::Base

  belongs_to :captive_portal

  validates_uniqueness_of :username, :scope => :captive_portal_id
  # TODO: validate password format (?? How ?? We have to be consistent with others class password attribute)
  validates_presence_of :password
  validates_uniqueness_of :cp_session_token, :scope => :captive_portal_id

  validates_inclusion_of :radius, :in => [ true, false ]

  validates_numericality_of :session_timeout, :allow_nil => true
  validates_numericality_of :idle_timeout, :allow_nil => true

  validates_numericality_of :max_upload_bandwidth, :greater_than => 0, :allow_nil => true
  validates_numericality_of :max_download_bandwidth, :greater_than => 0, :allow_nil => true

  validates_numericality_of :uploaded_octets, :greater_than_or_equal_to => 0
  validates_numericality_of :downloaded_octets, :greater_than_or_equal_to => 0
  validates_numericality_of :uploaded_packets, :greater_than_or_equal_to => 0
  validates_numericality_of :downloaded_packets, :greater_than_or_equal_to => 0

  validates_format_of :mac_address, :with => /\A([0-9a-f]{2}:){5}[0-9a-f]{2}\Z/
  validates_format_of :ip_address,
                      :with => /\A((([0-9])|([1-9][0-9])|(1[0-9][0-9])|(2[0-4][0-9])|(25[0-5]))\.){3}([0-9])|([1-9][0-9])|(1[0-9][0-9])|(2[0-4][0-9])|(25[0-5])\Z/

  before_create {
      # Generates the cp_session_token. Where applicable this id it's used also as a unique RADIUS session id.
    self.cp_session_token = Digest::SHA1.hexdigest(self.username + self.password + self.ip_address +
                                                       self.mac_address + Time.new.to_s)
  }

  after_create {
      # Let the user pass through the firewall...
    worker = MiddleMan.worker(:captive_portal_worker)
    worker.add_user(
        :args => {
            :cp_interface => self.captive_portal.cp_interface,
            :address => self.ip_address,
            :mac => self.mac_address,
            :max_upload_bandwidth => self.max_upload_bandwidth,
            :max_download_bandwidth => self.max_download_bandwidth
        }
    )
  }

  before_destroy {
    # This could be invoked from a worker, so we must use async_ here to
    # avoid deadlocks
    worker = MiddleMan.worker(:captive_portal_worker)
    worker.async_remove_user(
        :args => {
            :cp_interface => self.captive_portal.cp_interface,
            :address => self.ip_address,
            :mac => self.mac_address
        }
    )
  }

  def initialize(options = {})
    options[:uploaded_octets] ||= 0
    options[:downloaded_octets] ||= 0
    options[:uploaded_packets] ||= 0
    options[:downloaded_packets] ||= 0
    super(options)
    self.last_activity = Time.now
  end

  def update_activity!(uploaded_octets, downloaded_octets, uploaded_packets, downloaded_packets)
    unless uploaded_octets == self.uploaded_octets and downloaded_octets == self.downloaded_octets
      self.uploaded_octets = uploaded_octets
      self.downloaded_octets = downloaded_octets
      self.uploaded_packets = uploaded_packets
      self.downloaded_packets = downloaded_packets
      self.last_activity = Time.new
      self.save!
    else
      false
    end
  end

  def RADIUS_user?
    self.radius
  end

  def local_user?
    ! self.radius
  end

  def session_time_interval
    (Time.now - self.created_at).to_i
  end

  def last_activity_interval
    (Time.now - self.last_activity).to_i
  end

  def inactive?
    return false if self.idle_timeout.nil?
    self.last_activity_interval > self.idle_timeout
  end

  def expired?
    return false if self.session_timeout.nil?
    self.session_time_interval > self.session_timeout
  end

  def last_activity
    read_attribute(:last_activity)
  end

  def refresh!
    uploaded_octets, downloaded_octets = octets_counters
    uploaded_packets, downloaded_packets = packets_counters
    update_activity!(uploaded_octets, downloaded_octets, uploaded_packets, downloaded_packets)
  end

  protected
  def octets_counters
    worker = MiddleMan.worker(:captive_portal_worker)
    worker.get_user_bytes_counters(
        :args => {
            :cp_interface => self.captive_portal.cp_interface,
            :address => self.ip_address,
            :mac => self.mac_address
        }
    )
  end

  def packets_counters
    worker = MiddleMan.worker(:captive_portal_worker)
    worker.get_user_packets_counters(
        :args => {
            :cp_interface => self.captive_portal.cp_interface,
            :address => self.ip_address,
            :mac => self.mac_address
        }
    )
  end

end
