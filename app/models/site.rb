require 'bcrypt'
require 'uri'
require 'active_support/number_helper'

class Site < ActiveRecord::Base
  class ServiceUnavailable < StandardError; end

  include ActiveSupport::NumberHelper

  class << self
    def before_remove_const
      reset
    end

    def instance
      Thread.current[:__site__] ||= cache{ first_or_create(defaults) }
    end

    def reset
      Rails.cache.delete('__site__')
      Thread.current[:__site__] = nil
    end

    def authenticate(username, password)
      instance.authenticate(username, password)
    end

    def email_protocol
      instance.email_protocol
    end

    def enabled?
      instance.enabled?
    end

    def formatted_threshold_for_moderation
      instance.formatted_threshold_for_moderation
    end

    def formatted_threshold_for_response
      instance.formatted_threshold_for_response
    end

    def formatted_threshold_for_debate
      instance.formatted_threshold_for_debate
    end

    def host
      instance.host
    end

    def host_with_port
      instance.host_with_port
    end

    def constraints_for_public
      instance.constraints_for_public
    end

    def moderate_host
      instance.moderate_host
    end

    def moderate_host_with_port
      instance.moderate_host_with_port
    end

    def constraints_for_moderation
      instance.constraints_for_moderation
    end

    def opened_at_for_closing(time = Time.current)
      instance.opened_at_for_closing(time)
    end

    def closed_at_for_opening(time = Time.current)
      instance.closed_at_for_opening(time)
    end

    def port
      instance.port
    end

    def protected?
      instance.protected?
    end

    def reload
      Thread.current[:__site__] = nil
    end

    def touch(*names)
      instance.touch(*names)
    end

    def defaults
      {
        title:                      default_title,
        url:                        default_url,
        email_from:                 default_email_from,
        feedback_email:             default_feedback_email,
        username:                   default_username,
        password:                   default_password,
        enabled:                    default_enabled,
        protected:                  default_protected,
        petition_duration:          default_petition_duration,
        minimum_number_of_sponsors: default_minimum_number_of_sponsors,
        maximum_number_of_sponsors: default_maximum_number_of_sponsors,
        threshold_for_moderation:   default_threshold_for_moderation,
        threshold_for_response:     default_threshold_for_response,
        threshold_for_debate:       default_threshold_for_debate
      }
    end

    private

    def cache(&block)
      Rails.cache.fetch('__site__', { expires_in: 5.minutes }, &block)
    end

    def default_title
      ENV.fetch('SITE_TITLE', 'Petition parliament')
    end

    def default_url
      if ENV.fetch('EPETITIONS_PROTOCOL', 'https') == 'https'
        URI::HTTPS.build(default_url_components).to_s
      else
        URI::HTTP.build(default_url_components).to_s
      end
    end

    def default_url_components
      [nil, default_host, default_port, nil, nil, nil]
    end

    def default_host
      ENV.fetch('EPETITIONS_HOST', 'petition.parliament.uk')
    end

    def default_port
      ENV.fetch('EPETITIONS_PORT', '443').to_i
    end

    def default_email_from
      ENV.fetch('EPETITIONS_FROM', %{"Petitions: UK Government and Parliament" <no-reply@#{default_host}>})
    end

    def default_feedback_email
      ENV.fetch('EPETITIONS_FEEDBACK', %{"Petitions: UK Government and Parliament" <feedback@#{default_host}>})
    end

    def default_username
      ENV.fetch('SITE_USERNAME', nil).presence
    end

    def default_password
      ENV.fetch('SITE_PASSWORD', nil).presence
    end

    def default_enabled
      !ENV.fetch('SITE_ENABLED', '1').to_i.zero?
    end

    def default_protected
      !ENV.fetch('SITE_PROTECTED', '0').to_i.zero?
    end

    def default_petition_duration
      ENV.fetch('PETITION_DURATION', '6').to_i
    end

    def default_minimum_number_of_sponsors
      ENV.fetch('MINIMUM_NUMBER_OF_SPONSORS', '5').to_i
    end

    def default_maximum_number_of_sponsors
      ENV.fetch('MAXIMUM_NUMBER_OF_SPONSORS', '20').to_i
    end

    def default_threshold_for_moderation
      ENV.fetch('THRESHOLD_FOR_MODERATION', '5').to_i
    end

    def default_threshold_for_response
      ENV.fetch('THRESHOLD_FOR_RESPONSE', '10000').to_i
    end

    def default_threshold_for_debate
      ENV.fetch('THRESHOLD_FOR_DEBATE', '100000').to_i
    end
  end

  column_names.map(&:to_sym).each do |column|
    define_singleton_method(column) do |*args, &block|
      instance.public_send(column, *args, &block)
    end
  end

  attr_reader :password

  def authenticate(username, password)
    self.username == username && self.password_digest == password
  end

  def email_protocol
    uri.scheme
  end

  def formatted_threshold_for_moderation
    number_to_delimited(threshold_for_moderation)
  end

  def formatted_threshold_for_response
    number_to_delimited(threshold_for_response)
  end

  def formatted_threshold_for_debate
    number_to_delimited(threshold_for_debate)
  end

  def host
    uri.host
  end

  def host_with_port
    "#{host}#{port_string}"
  end

  def constraints_for_public
    { protocol: protocol, host: host, port: port }
  end

  def moderate_host
    @moderate_host ||= Rails.env.development? ? host : "moderate.#{host}"
  end

  def moderate_host_with_port
    "moderate.#{host}#{port_string}"
  end

  def constraints_for_moderation
    { protocol: protocol, host: moderate_host, port: port }
  end

  def password_digest
    BCrypt::Password.new(super)
  end

  def port
    uri.port
  end

  def password=(new_password)
    @password = new_password.presence

    if @password
      self.password_digest = BCrypt::Password.create(@password, cost: 10)
    else
      self.password_digest = nil
    end
  end

  def opened_at_for_closing(time = Time.current)
    time.end_of_day - petition_duration.months
  end

  def closed_at_for_opening(time = Time.current)
    time.end_of_day + petition_duration.months
  end

  validates :title, presence: true, length: { maximum: 50 }
  validates :url, presence: true, length: { maximum: 50 }
  validates :email_from, presence: true, length: { maximum: 100 }
  validates :feedback_email, presence: true, length: { maximum: 100 }
  validates :petition_duration, presence: true, numericality: { only_integer: true }
  validates :minimum_number_of_sponsors, presence: true, numericality: { only_integer: true }
  validates :maximum_number_of_sponsors, presence: true, numericality: { only_integer: true }
  validates :threshold_for_moderation, presence: true, numericality: { only_integer: true }
  validates :threshold_for_response, presence: true, numericality: { only_integer: true }
  validates :threshold_for_debate, presence: true, numericality: { only_integer: true }
  validates :username, presence: true, length: { maximum: 30 }, if: :protected?
  validates :password, length: { maximum: 30 }, confirmation: true, if: :protected?

  validate if: :protected? do
    errors.add(:password, :blank) unless password_digest?
  end

  # Force early definition of attribute methods
  # so that cached versions get properly built
  define_attribute_methods

  private

  def port_string
    standard_port? ? '' : ":#{port}"
  end

  def protocol
    "#{uri.scheme}://"
  end

  def standard_port
    case protocol
      when 'https://' then 443
      else 80
    end
  end

  def standard_port?
    port == standard_port
  end

  def uri
    @uri ||= URI.parse(url)
  end
end
