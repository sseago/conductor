#
#   Copyright 2011 Red Hat, Inc.
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
require 'uri'

class DeployablesController < ApplicationController
  before_filter :require_user

  def index
    clear_breadcrumbs
    save_breadcrumb(catalog_deployables_path(:viewstate => @viewstate ? @viewstate.id : nil))
    @deployables = Deployable.list_for_user(current_user, Privilege::VIEW)
    @catalog_entries = @deployables.collect { |d| d.catalog_entries.first }
    #@catalog_entries = CatalogEntry.list_for_user(current_user, Privilege::VIEW).apply_filters(:preset_filter_id => params[:catalog_entries_preset_filter], :search_filter => params[:catalog_entries_search])
    @catalog = @catalog_entries.first.catalog unless @catalog_entries.empty?
    set_header
  end

  def new
    @catalog_entry = params[:catalog_entry].nil? ? CatalogEntry.new() : CatalogEntry.new(params[:catalog_entry])
    @catalog_entry.deployable = Deployable.new unless @catalog_entry.deployable
    require_privilege(Privilege::CREATE, Deployable)
    if params[:create_from_image]
      @image = Aeolus::Image::Warehouse::Image.find(params[:create_from_image])
      @hw_profiles = HardwareProfile.frontend.list_for_user(current_user, Privilege::VIEW)
      @catalog_entry.deployable.name = @image.name
      load_catalogs
    else
      @catalog = Catalog.find(params[:catalog_id])
      require_privilege(Privilege::MODIFY, @catalog)
    end
    @form_option= params.has_key?(:from_url) ? 'from_url' : 'upload'
    respond_to do |format|
        format.html
        format.js {render :partial => @form_option}
    end
  end

  def show
    @catalog_entry = CatalogEntry.find(params[:id])
    require_privilege(Privilege::VIEW, @catalog_entry.deployable)
    save_breadcrumb(catalog_deployable_path(@catalog_entry.catalog, @catalog_entry), @catalog_entry.deployable.name)
    @providers = Provider.all
    @catalogs_options = Catalog.all.map {|c| [c.name, c.id] unless c == @catalog_entry.catalog}.compact
    add_permissions_inline(@catalog_entry.deployable)
    @image_details = @catalog_entry.deployable.get_image_details
    @image_details.each do |assembly|
      assembly.keys.each do |key|
        flash[:error] = assembly[key] if key.to_s =~ /^error\w+/
      end
    end
  end

  def create
    if params[:cancel]
      redirect_to catalog_deployables_path
      return
    end


    @catalog_entry = CatalogEntry.new(params[:catalog_entry])
    if params[:create_from_image].present?
      @catalog = @catalog_entry.catalog
      @catalog_entry.deployable = Deployable.new unless @catalog_entry.deployable
    else
      @catalog = Catalog.find(params[:catalog_id])
      @catalog_entry.catalog = @catalog
    end
    require_privilege(Privilege::MODIFY, @catalog)
    require_privilege(Privilege::CREATE, Deployable)
    @catalog_entry.deployable.owner = current_user

    if params.has_key? :url
        xml = import_xml_from_url(params[:url])
        unless xml.nil?
          #store xml_filename for url (i.e. url ends to: foo || foo.xml)
          @catalog_entry.deployable.xml_filename =  File.basename(URI.parse(params[:url]).path)
          @catalog_entry.deployable.xml = xml
        end
    elsif params[:create_from_image].present?
      hw_profile = HardwareProfile.frontend.find(params[:hardware_profile])
      require_privilege(Privilege::VIEW, hw_profile)
      @catalog_entry.deployable.set_from_image(params[:create_from_image], hw_profile)
    end

    if @catalog_entry.save
      flash[:notice] = t "catalog_entries.flash.notice.added"
      if params[:edit_xml]
        redirect_to edit_catalog_deployable_path @catalog_entry.catalog.id, @catalog_entry.id, :edit_xml =>true
      else
        redirect_to catalog_deployables_path(@catalog)
      end
    else
      flash[:warning]= t('catalog_entries.flash.warning.not_valid') if @catalog_entry.errors.has_key?(:xml)
      if params[:create_from_image].present?
        load_catalogs
        @image = Aeolus::Image::Warehouse::Image.find(params[:create_from_image])
        @hw_profiles = HardwareProfile.frontend.list_for_user(current_user, Privilege::VIEW)
        @catalog_entry.deployable.name = @image.name
      else
        params.delete(:edit_xml) if params[:edit_xml]
        @form_option = params[:catalog_entry].has_key?(:xml) ? 'upload' : 'from_url'
        @form_option = params[:catalog_entry][:deployable].has_key?(:xml) ? 'upload' : 'from_url'
      end
      render :new
    end
  end

  def edit
    @catalog_entry = CatalogEntry.find(params[:id])
    require_privilege(Privilege::MODIFY, @catalog_entry.deployable)
    @catalog = @catalog_entry.catalog
  end

  def update
    @catalog_entry = CatalogEntry.find(params[:id])
    require_privilege(Privilege::MODIFY, @catalog_entry.deployable)
    params[:catalog_entry][:deployable].delete(:owner_id) if params[:catalog_entry] and params[:catalog_entry][:deployable]

    if @catalog_entry.update_attributes(params[:catalog_entry])
      flash[:notice] = t"catalog_entries.flash.notice.updated"
      redirect_to catalog_deployable_path(@catalog_entry.catalog, @catalog_entry)
    else
      render :action => 'edit'
    end
  end

  def multi_destroy
    @catalog = nil
    CatalogEntry.find(params[:catalog_entries_selected]).to_a.each do |d|
      require_privilege(Privilege::MODIFY, d.catalog)
      require_privilege(Privilege::MODIFY, d.deployable)
      @catalog = d.catalog
      # Don't do this when we're managing deployables independently
      d.deployable.destroy
      d.destroy
    end
    redirect_to catalog_path(@catalog)
  end

  def destroy
    catalog_entry = CatalogEntry.find(params[:id])
    require_privilege(Privilege::MODIFY, catalog_entry.catalog)
    require_privilege(Privilege::MODIFY, catalog_entry.deployable)
    @catalog = catalog_entry.catalog
    # Don't do this when we're managing deployables independently
    catalog_entry.deployable.destroy
    catalog_entry.destroy

    respond_to do |format|
      format.html { redirect_to catalog_path(@catalog) }
    end
  end

  def filter
    original_path = Rails.application.routes.recognize_path(params[:current_path])
    original_params = Rack::Utils.parse_nested_query(URI.parse(params[:current_path]).query)
    redirect_to original_path.merge(original_params).merge("catalog_entries_preset_filter" => params[:catalog_entries_preset_filter], "catalog_entries_search" => params[:catalog_entries_search])
  end

  private

  def set_header
    @header = [
      { :name => 'checkbox', :class => 'checkbox', :sortable => false },
      { :name => t("catalog_entries.index.name"), :sort_attr => :name },
      { :name => t("catalogs.index.catalog_name"), :sortable => false },
      { :name => t("catalog_entries.index.deployable_xml"), :sortable => :url }
    ]
  end

  def load_catalogs
    @catalogs = Catalog.list_for_user(current_user, Privilege::MODIFY)
  end

  def import_xml_from_url(url)
    begin
      response = RestClient.get(url, :accept => :xml)
      if response.code == 200
        response
      end
    rescue RestClient::Exception, SocketError, URI::InvalidURIError
      flash[:error] = t('catalog_entries.flash.warning.not_valid_or_reachable', :url => url)
      nil
    end
  end
end