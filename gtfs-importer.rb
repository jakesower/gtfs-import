#
# GTFS IMPORTER
#
# This script will import a GTFS zip file as specified here:
# https://developers.google.com/transit/gtfs/reference?hl=en
#
# It will create an ArcGIS item for each required or optional file provided,
# and a feature service for stops.txt (see PUBLISH_STEP_ACTIONS in code). It
# will ignore any files that are not listed in the specification. It will then
# mark each created item as public, open data.
#
# Requirements:
# The following gems are required: zip, concurrent, arcgis-ruby.
#
# Usage:
# The Config module contains all of the parts you need to change. Note that you
# can leave GROUP_ID as nil if you want the script to automatically create a
# group for you.
#
# After that, simply run it from the command line! It should take less than a
# minute to run.
#

require 'rubygems'
require 'zip'
require 'concurrent'
require 'arcgis-ruby'


module Config
  HOST = "https://www.arcgis.com/sharing/rest"
  USERNAME = "myusername"
  PASSWORD = "mypassword"
  GROUP_ID = nil
  FILE = File.open("/path/to/gtfs/file.zip")
end


# Reference: 
class GTFSImport
  # Define the list of files that comprise a GTFS zip
  REQUIRED_FILES = [
    "agency.txt",
    "stops.txt",
    "routes.txt",
    "trips.txt",
    "stop_times.txt",
    "calendar.txt"
  ]

  OPTIONAL_FILES = [
    "calendar_dates.txt",
    "fare_attributes.txt",
    "fare_rules.txt",
    "shapes.txt",
    "frequencies.txt",
    "transfers.txt",
    "feed_info.txt"
  ]

  PUBLISH_STEP_ACTIONS = {
    "stops.txt" => {
      "name" => "Stops",
      "locationType" => "coordinates",
      "latitudeFieldName" => "stop_lat",
      "longitudeFieldName" => "stop_lon"
    },
  }


  #
  # Kick off the import process--a group may optionally be passed in to receive
  # the files, otherwise one will be created with the name "GTFS Import"
  #
  def self.import
    dir = Dir.mktmpdir

    begin
      files = extract_files(zip_file: Config::FILE, dir: dir)

      valid = (REQUIRED_FILES - files.map{|f| f[:file_name]}).empty?
      raise "Invalid GTFS format. No files were uploaded." unless valid

      # Strip out nonstandard files
      files = files.select{|f| (REQUIRED_FILES + OPTIONAL_FILES).include?(f[:file_name])}

      # Begin making the appropriate API calls
      # TODO: pull this from config!
      connection = Arcgis::Connection.new(
        host: Config::HOST,
        username: Config::USERNAME,
        password: Config::PASSWORD
      )

      # Create a new group if necessary
      group_id = Config::GROUP_ID || begin
        puts "Creating GTFS Group"
        group = connection.group.create(
          title: "GTFS Import",
          access: "account",
          description: "An import of GTFS data"
        )
        group["group"]["id"]
      end

      requests = []

      # Set up ArcGIS requests based on if it's going to be a simple file
      # upload or something to be published as a feature service.
      files.each do |item|
        args = {connection: connection, item: item, group_id: group_id}
        if PUBLISH_STEP_ACTIONS[item[:file_name]]
          requests += feature_item(args)
        else
          requests += simple_item(args)
        end
      end

      # The created requests are run concurrently. Block on each until they've
      # all been run. If we hit any errors, we'll throw them at the end.
      errors = []
      requests.each do |r|
        r.value
        if r.rejected?
          errors << r.reason
        end
      end
      if errors.empty?
        puts "Everything has been imported successfully. Yay!"
      else
        raise errors.join("\n")
      end

    ensure
      FileUtils.remove_entry dir
    end
  end


  #
  # Called for files that just get uploaded as is.
  #
  def self.simple_item(connection:, item:, group_id:)
    r_create = Concurrent::dataflow do
      puts "Creating #{item[:name]}"
      connection.user.add_item(title: item[:name], type: "CSV", tags: "gtfs",
        file: File.open(item[:path])) 
    end

    r_share = Concurrent::dataflow(r_create) do |created_item|
      puts "Sharing #{item[:name]}"
      connection.item(created_item["id"]).share(groups: group_id,
        everyone: true, org: true)
    end

    [r_create, r_share]
  end


  #
  # This creates a feature service for stops.txt--there's a chance that we can
  # extract out shapes.txt at a future time
  #
  def self.feature_item(connection:, item:, group_id:)
    # create
    r_create = Concurrent::dataflow do
      puts "Creating #{item[:name]}"
      connection.user.add_item(title: item[:name], type: "CSV", tags: "gtfs",
        file: File.open(item[:path]))
    end

    # analyze
    r_analyze = Concurrent::dataflow(r_create) do |created_item|
      puts "Analyzing #{item[:name]}"
      connection.feature.analyze(itemId: created_item["id"], filetype: "csv")
    end

    # publish
    r_publish = Concurrent::dataflow(r_create, r_analyze) do |created_item, analysis|
      puts "Publishing #{item[:name]}"
      params = {
        filetype: "csv",
        itemId: created_item["id"],
        publishParameters: analysis["publishParameters"].merge(
          PUBLISH_STEP_ACTIONS[item[:file_name]]
        )
      }

      connection.user.publish_item(params)
    end

    # share
    r_share = Concurrent::dataflow(r_publish) do |publishing|
      puts "Sharing #{item[:name]}"
      service_item_id = publishing["services"].first["serviceItemId"]
      connection.item(service_item_id).share(
        groups: group_id, everyone: true, org: true
      )
    end

    [r_create, r_analyze, r_publish, r_share]
  end


  #
  # Extract files from the GTFS zip file
  #
  def self.extract_files(zip_file:, dir:)
    Zip::File.open(zip_file) do |zip|
      zip.map do |file|
        path = "#{dir}/#{file.name}"
        out = File.open(path, 'w')

        out.write file.get_input_stream.read.force_encoding("UTF-8")
        {
          name: file.name.gsub('.txt','').split('_').map(&:capitalize).join(' '),
          file_name: file.name,
          path: path
        }
      end
    end
  end

end

GTFSImport.import
