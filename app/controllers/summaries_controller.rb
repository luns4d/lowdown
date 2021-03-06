class SummaryQuery
  extend ActiveModel::Naming
  include ActiveModel::Conversion

  attr_accessor :start_date, :end_date, :after_end_date
  attr_accessor :provider, :reporting_agency, :complete
  attr_accessor :allocation_id_list, :allocation_ids, :adjustment_notes_contain

  def convert_date(obj, base)
    Date.new(obj["#{base}(1i)"].to_i, obj["#{base}(2i)"].to_i)
  end

  def initialize(params)
    params ||= {}
    if params["start_date(1i)"].present?
      @start_date = convert_date(params, "start_date")
    elsif params["start_date"].present?
      @start_date = Date.parse(params["start_date"])
    end
    if params["end_date(1i)"].present?
      @end_date = convert_date(params, "end_date")
    elsif params["end_date"].present?
      @end_date = Date.parse(params["end_date"])
    end
    if @start_date.blank? || @end_date.blank?
      @start_date   = Date.today - 1.month - Date.today.day + 1.day
      @end_date     = @start_date
    end
    @after_end_date       = Date.new(@end_date.year,@end_date.month,1) + 1.month

    @reporting_agency     = params[:reporting_agency].to_i  if params[:reporting_agency].present?
    @allocation_id_list   = params[:allocation_id_list]     if params[:allocation_id_list].present?
    @provider             = params[:provider].to_i          if params[:provider].present?
    @complete             = true if params[:complete] == 'Yes'
    @complete             = false if params[:complete] == 'No'
    @allocation_ids       = @allocation_id_list.split.map{|al| al.to_i} if @allocation_id_list.present?
    @adjustment_notes_contain = params[:adjustment_notes_contain] if params[:adjustment_notes_contain]
  end

  def persisted?
    false
  end
  
  def has_dates?
    start_date.present? && end_date.present?
  end

  def apply_conditions(summaries)
    summaries = summaries.for_date_range(start_date,after_end_date) if start_date
    summaries = summaries.for_provider(provider) if provider.present? && provider != 0 
    summaries = summaries.with_no_provider if provider == 0
    summaries = summaries.for_reporting_agency(reporting_agency) if reporting_agency.present? && reporting_agency != 0 
    summaries = summaries.with_no_reporting_agency if reporting_agency == 0
    summaries = summaries.data_entry_complete if complete 
    summaries = summaries.data_entry_not_complete if complete == false
    summaries = summaries.for_allocation_id(allocation_ids) if allocation_ids.present?
    summaries = summaries.adjustment_notes_contain(adjustment_notes_contain) if adjustment_notes_contain.present?
    summaries
  end

  def providers
    na_provider = Provider.new(name: "<Not Applicable>")
    na_provider.id = 0
    [na_provider] + Provider.providers_in_allocations.default_order
  end

  def reporting_agencies
    na_reporting_agency = Provider.new(name: "<Not Applicable>")
    na_reporting_agency.id = 0
    [na_reporting_agency] + Provider.reporting_agencies.default_order
  end
end

class SummariesController < ApplicationController

  before_filter :require_admin_user, except: [:index, :edit]

  def index
    attributes_to_sum = %w{total_cost in_district_trips out_of_district_trips trips total_miles driver_hours_paid driver_hours_volunteer total_driver_hours}
    @grand_totals = {}
    @page_totals = {}

    @query = SummaryQuery.new(params[:q])
    @filtered_summaries = @query.
        apply_conditions(Summary).
        current_versions.
        includes(:allocation,:summary_rows).
        joins(:allocation).
        order('allocations.name,summaries.period_start')
    @summaries = @filtered_summaries.paginate page: params[:page]
    @allocations = Allocation.summary_collection_method.order(:name)
    attributes_to_sum.each do |attribute|
      @grand_totals[attribute.to_sym] = @filtered_summaries.inject(0){|sum,item| sum + (item.send(attribute) || 0)}
      @page_totals[attribute.to_sym]  = @summaries.inject(0){|sum,item| sum + (item.send(attribute) || 0)}
    end
  end

  def new
    @summary = Summary.new
    
    POSSIBLE_TRIP_PURPOSES.each do |purpose|
      @summary.summary_rows.build(purpose: purpose)
    end
    prep_edit 
  end

  def create
    @summary = Summary.new(safe_params)
    if ! @summary.summary_rows.size == POSSIBLE_TRIP_PURPOSES.size * 2
      flash.now[:alert] = "You must fill in all summary rows (even if just with zeros)"
      render :new
    end
    prep_edit
    if @summary.save
      flash[:alert] = "Successfully created summary for allocation \"#{@summary.allocation.name}\" for #{@summary.period_start.strftime('%B %Y')}"
      redirect_to new_summary_path 
    else
      render :new
    end
  end

  def edit
    @summary = Summary.find params[:id]
    prep_edit
    @versions = @summary.versions.reverse
  end

  def update
    old_version = Summary.find(params[:summary][:id])
    @summary = old_version.current_version

    prep_edit
    @versions = @summary.versions.reverse

    #gather up the old row objects
    old_rows = @summary.summary_rows.map &:dup
    @summary.attributes = safe_params

    create_new_version = @summary.create_new_version?

    if @summary.save
      #this created a new prior version, to which we want to reassign the
      #newly-created old-valued summary rows
      prev = @summary.previous
      if prev && create_new_version
        for row in old_rows
          row.summary_id=prev.id
          row.save!
        end
      end

      rows = @summary.summary_rows
      #and ensure that there are all rows for the current summary
      for purpose in POSSIBLE_TRIP_PURPOSES
        found = false
        for row in rows
          if row.purpose == purpose
            found = true
            break
          end
        end
        if not found
          SummaryRow.create(summary_id: @summary.id)
        end
      end
      redirect_to edit_summary_path(@summary)
    else
      render :edit
    end
  end
  
  def delete
    @summary = Summary.find params[:id]
    
    if @summary.versions.size == 1
      if @summary.latest?    
        @summary.summary_rows.each &:delete
        @summary.delete # avoid callbacks or else delete will be halted
      end
    
      redirect_to summaries_path, notice: "Summary successfully deleted"
    else
      render :edit, notice: "All previous versions must be deleted first"
    end 
  end

  def delete_version
    @summary = Summary.find params[:id]
    
    unless @summary.latest?    
      @summary.summary_rows.each &:delete
      @summary.delete # avoid callbacks or else delete will be halted
    end
    
    redirect_to edit_summary_path(@summary.base_id)
  end

  def bulk_update
    updated = 0

    @query = SummaryQuery.new(params[:q])
    unless @query.has_dates?
      flash[:alert] = "Cannot update without date range"
    else
      updated = @query.apply_conditions(Summary.current_versions.data_entry_not_complete).update_all(complete: true)
      flash[:alert] = "Updated #{view_context.pluralize updated, "record"}"
    end
    redirect_to summaries_path(q: params[:q])
  end

  def adjustments
    @query = SummaryQuery.new(params[:q])
    @summaries = @query.
        apply_conditions(Summary).
        revisions.
        includes(:allocation,:summary_rows).
        order('summaries.valid_start DESC').
        paginate page: params[:page]
  end

  private

    def safe_params
      params.require(:summary).permit(
        :allocation_id,
        :period_start,
        :adjustment_notes,
        :total_miles,
        :turn_downs,
        :unduplicated_riders,
        :driver_hours_paid,
        :driver_hours_volunteer,
        :escort_hours_volunteer,
        :administrative_hours_volunteer,
        :funds,
        :donations,
        :agency_other,
        :administrative,
        :operations,
        :vehicle_maint,
        :complete,
        summary_rows_attributes: [
          :id,
          :purpose,
          :in_district_trips,
          :out_of_district_trips
        ]
      )
    end

    def prep_edit
      @grouped_allocations = [] 
      Provider.with_summary_data.order(:name).each do |p|
        @grouped_allocations << [p.name, p.active_summary_allocations_as_of(@summary.try :period_start).map {|a| [a.select_label,a.id]}]
      end
      @grouped_allocations << ['<No provider>', Allocation.summary_required.active_as_of(@summary.try :period_start).where(provider_id: nil).map {|a| [a.name,a.id]}]
    end
end
