class Trip < ActiveRecord::Base
  require 'bigdecimal'
  extend FiscalYear

  class << self

    def date_range(start_date, after_end_date)
      start_date = start_date.to_date
      after_end_date = after_end_date.to_date
      where("trips.date >= ? AND trips.date < ?",start_date,after_end_date)
    end

    def version_group_count
      Trip.find_by_sql("SELECT COUNT(*) FROM (SELECT DISTINCT valid_start, adjustment_notes FROM trips where valid_start <> imported_at) AS x").first['count'].to_i
    end

    def completed_trip_count_for_valid_start(valid_start)
      Trip.select("COUNT(*) + SUM(guest_count) + SUM(attendant_count) AS count").completed.for_valid_start(valid_start).reorder('').first['count'].to_i
    end

    def exclude_customers_earlier_in_fiscal_year(options)
      special_where = ""
      special_where << "AND complete=true " if options[:pending]
      special_where << "AND lower(customer_type)='honored'" if options[:elderly_and_disabled_only]
      where_clause = "NOT EXISTS (
            SELECT id
            FROM trips AS t
            WHERE result_code = 'COMP' AND
              date >= ranges.fiscal_year_start_date AND date < ranges.start_date AND
              valid_end = '9999-01-01 01:01:00.000000' AND
              trips.allocation_id = t.allocation_id AND
              trips.customer_id = t.customer_id #{special_where}
          )"
      where(where_clause)
    end

    def summary_purpose(trip_purpose)
      TRIP_PURPOSE_TO_SUMMARY_PURPOSE.fetch(trip_purpose, trip_purpose)
    end

    def trip_purposes_from_summary_purpose(summary_purpose)
      result = []
      TRIP_PURPOSE_TO_SUMMARY_PURPOSE.each {|k, v| result << k if v == summary_purpose }
      result
    end

    def for_date_ranges(date_ranges)
      rows = ["('#{date_ranges.first[:start_date].to_s(:db)}'::date, '#{date_ranges.first[:after_end_date].to_s(:db)}'::date, '#{fiscal_year_start_date(date_ranges.first[:start_date]).to_s(:db)}'::date)"]
      date_ranges[1..-1].each do |range|
        rows << "('#{range[:start_date].to_s(:db)}', '#{range[:after_end_date].to_s(:db)}', '#{fiscal_year_start_date(range[:start_date]).to_s(:db)}')"
      end
      join = "CROSS JOIN (VALUES #{rows.join(', ')}) AS ranges (start_date, after_end_date, fiscal_year_start_date)"
      joins(join).where("trips.date >= ranges.start_date AND trips.date < ranges.after_end_date")
    end
  end

  stampable updater_attribute: :updated_by,
            creator_attribute: :updated_by,
            creator_association: :trip_creator,
            updater_association: :trip_updater
  point_in_time
  belongs_to :pickup_address, class_name: "Address", foreign_key: "pickup_address_id"
  belongs_to :dropoff_address, class_name: "Address", foreign_key: "dropoff_address_id"
  belongs_to :home_address, class_name: "Address", foreign_key: "home_address_id"
  belongs_to :allocation
  belongs_to :run
  belongs_to :customer
  belongs_to :trip_import

  after_validation :set_duration_and_mileage
  after_save :apportion_shared_rides
  after_create :apportion_new_run_based_trips

  attr_accessor :bulk_import, :secondary_update, :do_not_version

  scope :default_order,             -> { order :start_at }
  scope :completed,                 -> { where result_code: 'COMP' }
  scope :data_entry_complete,       -> { where complete: true }
  scope :data_entry_not_complete,   -> { where complete: false }
  scope :shared,                    -> { where 'trips.routematch_share_id IS NOT NULL' }
  scope :elderly_and_disabled_only, -> { where 'lower(customer_type) = ?', 'honored' }
  scope :without_no_shows,          -> { where "trips.result_code <> ?","NS" }
  scope :without_cancels,           -> { where "trips.result_code <> ?","CANC" }
  scope :washington_medicaid_nonmedical, -> {
          joins(allocation: {project: :funding_source}).
          where(funding_sources: {funding_source_name: 'SPD'})
        }
  scope :multnomah_medicaid_nonmedical, -> {
          joins(allocation: {project: :funding_source}).
          where(projects: {project_number: '1094'})
        }
  scope :multnomah_ads, -> {
          joins(allocation: {project: :funding_source}).
          where(funding_sources: {funding_source_name: 'Multnomah ADS'})
        }
  scope :washington_davs, -> {
          joins(allocation: {project: :funding_source}).
          where(funding_sources: {funding_source_name: 'Washington Co DAVS'})
        }
  scope :billed_per_hour, -> { where("allocations.name ILIKE '%hourly%'") }
  scope :billed_per_trip, -> { where("allocations.name NOT ILIKE '%hourly%'") }
  scope :for_allocation,    lambda {|allocation|    where(allocation_id: allocation.id) }
  scope :for_allocation_id, lambda {|allocation_id| where(allocation_id: allocation_id) }
  scope :for_run,           lambda {|run_id|        where(run_id: run_id) }
  scope :for_valid_start,   lambda {|valid_start|   where(valid_start: valid_start) }
  scope :for_share,         lambda {|share_id|      where(routematch_share_id: share_id) }
  scope :for_result_code,   lambda {|result_code|   where(result_code: result_code) }
  scope :for_import,        lambda {|import_id|     where(trip_import_id: import_id)}
  scope :for_valid_start,   lambda {|valid_start|   where(valid_start: valid_start) }
  scope :for_trip_purpose,  lambda {|trip_purpose|  where(purpose_type: self.trip_purposes_from_summary_purpose(trip_purpose)) }
  scope :for_date_range,
        lambda {|start_date,after_end_date| where("date >= ? AND date < ?",start_date,after_end_date) }
  scope :for_customer_last_name_like,
        lambda {|name| where("trips.customer_id IN (SELECT id FROM customers WHERE LOWER(last_name) LIKE ?)",
        "%#{name.downcase}%") }
  scope :for_customer_first_name_like,
        lambda {|name| where("trips.customer_id IN (SELECT id FROM customers WHERE LOWER(first_name) LIKE ?)",
        "%#{name.downcase}%") }
  scope :for_original_override_like,
        lambda {|override| where("LOWER(trips.original_override) LIKE ?", "%#{override.downcase}%") }
  scope :for_program_id,
        lambda {|program_id| where("trips.allocation_id IN (SELECT id FROM allocations WHERE program_id = ?)",
        program_id)}
  scope :for_provider,
        lambda {|provider_id| where("trips.allocation_id IN (SELECT id FROM allocations WHERE provider_id = ?)",
        provider_id)}
  scope :for_reporting_agency,
        lambda {|provider_id| where("trips.allocation_id IN (SELECT id FROM allocations WHERE reporting_agency_id = ?)",
        provider_id)}
  scope :grouped_by_adjustment, -> {
          select("trips.valid_start, trips.adjustment_notes, COUNT(*) AS cnt, " +
          "MIN(date) as min_date, MAX(date) AS max_date, MIN(trips.id) as id").
          group("trips.valid_start, trips.adjustment_notes").
          order("trips.valid_start DESC").
          where("valid_start <> imported_at")
        }
  scope :index_includes, -> {
          includes(:pickup_address, :dropoff_address, :run, :customer,
          allocation: [:provider,{project: :funding_source},:override]).
          joins(:allocation)
        }
  scope :grouped_revisions, -> {
          select("DISTINCT valid_start, adjustment_notes").
          where("valid_start <> imported_at")
        }
  scope :trip_count, -> { select("SUM(attendant_count) + SUM(guest_count) + COUNT(*) AS trip_count").reorder('') }

  RESULT_CODES = {
    'Completed'   => 'COMP',
    'Turned Down' => 'TD',
    'No Show'     => 'NS',
    'Unmet Need'  => 'UNMET',
    'Cancelled'   => 'CANC'
  }

  def created_by
    return first_version.updated_by
  end

  def completed?
    result_code == 'COMP'
  end

  def shared?
    routematch_share_id.present?
  end

  def bpa_provider?
    (allocation.provider.provider_type == "BPA Provider")
  end

  def updated_by_user
    return (self.updated_by.nil? ? User.find(:first) : User.find(self.updated_by))
  end

  def customers_served
    guest_count + attendant_count + 1
  end

  def summary_purpose
    self.class.summary_purpose purpose_type
  end

  def chronological_versions
    return self.versions.sort{|t1,t2|t1.updated_at <=> t2.updated_at}.reverse
  end

  def wheelchair?
    if mobility == "Ambulatory" || (mobility =~ /can transfer/i)
      false
    elsif mobility.nil?
      nil
    else
      true
    end
  end

  def washington_medicaid_nonmedical_billable_mileage
    if self.estimated_trip_distance_in_miles < 5
      return BigDecimal("0")
    elsif self.estimated_trip_distance_in_miles < 20
      return BigDecimal((self.estimated_trip_distance_in_miles - 5).to_s).round(2)
    else
      return BigDecimal("15")
    end
  end

  def premium_billing_method
    allocation.premium_billing_method
  end

  def ads_partner_cost
    unless allocation.provider.provider_type == "BPA Provider"
      if premium_billing_method == 'Per Trip'
        if allocation.county == 'Multnomah'
          BigDecimal.new("6.35")
        elsif allocation.county == 'Washington'
          BigDecimal.new("5")
        end
      elsif premium_billing_method == 'Volunteer'
        BigDecimal.new("0")
      end
    end
  end

  def ads_taxi_cost
    if allocation.provider.provider_type == "BPA Provider"
      apportioned_fare
    end
  end

  def ads_scheduling_cost
    if premium_billing_method == 'Per Trip'
      if allocation.county == 'Multnomah'
        BigDecimal.new("3.08")
      elsif allocation.county == 'Washington'
        BigDecimal.new("2.46")
      end
    elsif premium_billing_method == 'Volunteer'
      BigDecimal.new("0")
    end
  end

  def ads_total_cost
    unless ads_partner_cost.nil? && ads_taxi_cost.nil? && ads_scheduling_cost.nil?
      cost = BigDecimal.new((ads_partner_cost || 0) + (ads_taxi_cost || 0) + (ads_scheduling_cost || 0))
    end
  end

  def provider
    allocation.try(:provider)
  end

  def create_revision_with_known_attributes_without_callbacks(attrs)
    old_version = versions.build self.attributes.merge( attrs )

    old_version.valid_end = now_rounded
    old_version.should_run_callbacks = false
    old_version.save!(validate: false)
  end

private

  def create_new_version?
    !do_not_version?
  end

  def do_not_version?
    do_not_version == true || do_not_version.to_i == 1 || !complete || !complete_was
  end

  def set_duration_and_mileage
    unless secondary_update
      if completed? && (allocation.run_collection_method == 'trips')
        self.duration = (end_at - start_at).to_i unless end_at.nil? || start_at.nil?
        if odometer_end.nil? || odometer_start.nil? || odometer_start == 0
          if bpa_billing_distance && bpa_billing_distance > 0
            self.mileage = bpa_billing_distance
          elsif odometer_start == 0 && odometer_end && odometer_end > 0
            self.mileage = odometer_end
          else
            self.mileage = 0
          end
        else
          self.mileage = odometer_end - odometer_start
        end
        if routematch_share_id.blank?
          self.apportioned_fare = fare unless fare.nil?
          self.apportioned_duration = duration unless duration.nil?
          self.apportioned_mileage = mileage unless mileage.nil?
        end
      end
    end
  end

  def apportion_shared_rides
    unless secondary_update || bulk_import
      return if should_run_callbacks == false

      # currently shared, update new routematch_share rides
      reapportion_trips_for_routematch_share_id( routematch_share_id ) if shared?

      if routematch_share_id_changed?
        # previously shared, update old routematch_share rides
        if routematch_share_id_change.first.present?
          reapportion_trips_for_routematch_share_id( routematch_share_id_change.first )
        end
      end
    end
    return true
  end

  def reapportion_trips_for_routematch_share_id(rms_id)
    r = Trip.current_versions.completed.where(routematch_share_id: rms_id, date: date).order(:end_at,:created_at).all
    trip_count    = r.size
    ride_duration = (r.map(&:end_at).max - r.map(&:start_at).min).to_i
    ride_mileage  = r.map(&:odometer_end).max - r.map(&:odometer_start).min
    ride_cost     = r.sum(:fare)
    all_est_miles = r.sum(:estimated_trip_distance_in_miles)
    has_rate_data = !r.map(&:estimated_individual_fare).include?(nil)
    if has_rate_data
      all_estimated_individual_fares = r.sum(:estimated_individual_fare)
    end

    # Keep a tally of apportionments made so any remainder can be applied to the last trip.
    ride_duration_remaining = ride_duration
    ride_mileage_remaining = ride_mileage
    ride_cost_remaining = ride_cost

    trip_position = 0

    for t in r
      trip_position += 1
      # Avoid infinite recursion
      t.secondary_update = true

      this_mileage_ratio = t.estimated_trip_distance_in_miles / all_est_miles

      this_trip_duration = (ride_duration.to_f * this_mileage_ratio).floor
      ride_duration_remaining = (ride_duration_remaining - this_trip_duration)
      t.apportioned_duration = this_trip_duration + ( trip_position == trip_count ? ride_duration_remaining : 0 )

      this_trip_mileage = (ride_mileage * this_mileage_ratio * 100).floor.to_f / 100
      ride_mileage_remaining = (ride_mileage_remaining - this_trip_mileage).round(2)
      t.apportioned_mileage = this_trip_mileage + ( trip_position == trip_count ? ride_mileage_remaining : 0 )

      if has_rate_data
        this_fare_ratio = t.estimated_individual_fare / all_estimated_individual_fares
        this_trip_cost = (ride_cost * this_fare_ratio * 100).floor.to_f / 100
      else
        this_trip_cost = (ride_cost * this_mileage_ratio * 100).floor.to_f / 100
      end
      ride_cost_remaining = (ride_cost_remaining - this_trip_cost).round(2)
      t.apportioned_fare = this_trip_cost + ( trip_position == trip_count ? ride_cost_remaining : 0 )
      t.do_not_version = true
      t.save!
    end
  end

  def apportion_new_run_based_trips
    if !should_run_callbacks
      return true
    end
    unless secondary_update || bulk_import
      self.run.save!
    end
  end
end
