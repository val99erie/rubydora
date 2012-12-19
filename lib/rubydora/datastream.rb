module Rubydora
  # This class represents a Fedora datastream object
  # and provides helper methods for creating and manipulating
  # them. 
  class Datastream
    extend ActiveModel::Callbacks
    define_model_callbacks :save, :create, :destroy
    define_model_callbacks :initialize, :only => :after

    include ActiveModel::Dirty

    class_attribute :eager_load_datastream_content
    self.eager_load_datastream_content = false

    attr_reader :digital_object, :dsid

    # mapping datastream attributes (and api parameters) to datastream profile names
    DS_ATTRIBUTES = {:controlGroup => :dsControlGroup, :dsLocation => :dsLocation, :altIDs => nil, :dsLabel => :dsLabel, :versionable => :dsVersionable, :dsState => :dsState, :formatURI => :dsFormatURI, :checksumType => :dsChecksumType, :checksum => :dsChecksum, :mimeType => :dsMIME, :logMessage => nil, :ignoreContent => nil, :lastModifiedDate => nil, :content => nil, :asOfDateTime => nil}
    DS_DEFAULT_ATTRIBUTES = { :controlGroup => 'M', :dsState => 'A', :versionable => true }

    define_attribute_methods DS_ATTRIBUTES.keys

    # accessors for datastream attributes 
    DS_ATTRIBUTES.each do |attribute, profile_name|
      define_method attribute.to_s do
        var = "@#{attribute.to_s}".to_sym
        if instance_variable_defined?(var)
          instance_variable_get var
        elsif profile.has_key? profile_name.to_s
           profile[profile_name.to_s]
        else
          default_attributes[attribute.to_sym]
        end
      end

      class_eval %Q{
      def #{attribute.to_s}= val
        validate_#{attribute.to_s}!(val) if respond_to?(:validate_#{attribute.to_s}!, true)
        #{attribute.to_s}_will_change! unless val == #{attribute.to_s}
        @#{attribute.to_s} = val
      end
      }
    end

    DS_READONLY_ATTRIBUTES = [ :dsCreateDate , :dsSize, :dsVersionID ]
    DS_READONLY_ATTRIBUTES.each do |attribute|
      class_eval %Q{
      def #{attribute.to_s}
        @#{attribute} || profile['#{attribute.to_s}'] || default_attributes[:#{attribute}]
      end
      }

      def dsChecksumValid
        profile(:validateChecksum=>true)['dsChecksumValid']
      end
    end


    # Create humanized accessors for the DS attribute  (dsState -> state, dsCreateDate -> createDate)
    (DS_ATTRIBUTES.keys + DS_READONLY_ATTRIBUTES).select { |k| k.to_s =~ /^ds/ }.each do |attribute|
      simple_attribute = attribute.to_s.sub(/^ds/, '')
      simple_attribute = simple_attribute[0].chr.downcase + simple_attribute[1..-1]

      alias_method simple_attribute, attribute

      if self.respond_to? "#{attribute}="
        alias_method "#{simple_attribute}=", "#{attribute}="
      end
    end


    def asOfDateTime asOfDateTime = nil
      if asOfDateTime == nil
        return @asOfDateTime
      end

      return self.class.new(@digital_object, @dsid, @options.merge(:asOfDateTime => asOfDateTime))
    end

    def self.default_attributes
      DS_DEFAULT_ATTRIBUTES
    end

    def default_attributes
      @default_attributes ||= self.class.default_attributes
    end

    def default_attributes= attributes
      @default_attributes = default_attributes.merge attributes
    end

    ##
    # Initialize a Rubydora::Datastream object, which may or
    # may not already exist in the datastore.
    #
    # Provides `after_initialize` callback for extensions
    # 
    # @param [Rubydora::DigitalObject]
    # @param [String] Datastream ID
    # @param [Hash] default attribute values (used esp. for creating new datastreams)
    def initialize digital_object, dsid, options = {}, default_instance_attributes = {}
      _run_initialize_callbacks do
        @digital_object = digital_object
        @dsid = dsid
        @options = options
        @default_attributes = default_attributes.merge(default_instance_attributes)
        options.each do |key, value|
          self.send(:"#{key}=", value)
        end
      end
    end

    # Helper method to get digital object pid
    def pid
      digital_object.pid
    end

    # Does this datastream already exist?
    # @return [Boolean]
    def new?
      digital_object.nil? || digital_object.new? || profile_xml.blank?
    end

    # Retrieve the content of the datastream (and cache it)
    # @return [String]
    def content
      return @content if new?

      @content ||= datastream_content

      if @content.kind_of? IO
        begin
          @content.rewind
          @content.read
        ensure
          @content.rewind
        end
      else
        @content
      end
    end
    alias_method :read, :content

    def datastream_content
      return nil if new?

      @datastream_content ||=begin
        options = { :pid => pid, :dsid => dsid }
        options[:asOfDateTime] = asOfDateTime if asOfDateTime

        repository.datastream_dissemination options
      rescue RestClient::ResourceNotFound
      end
    end

    # Get the URL for the datastream content
    # @return [String]
    def url
      options = { }
      options[:asOfDateTime] = asOfDateTime if asOfDateTime
      repository.datastream_url(pid, dsid, options) + "/content"
    end

    # Set the content of the datastream
    # @param [String or IO] 
    # @return [String or IO]
    def content= new_content
       content_will_change! if (self.eager_load_datastream_content and content != new_content) or (@content.nil? or @content != new_content)
       @content = new_content
    end

    # Content_will_change! would be dynamically created by ActiveModel::Dirty, but it would eagerly load the content.
    # We don't want to do that.
    def content_will_change!
      raise "Can't change values on older versions" if @asOfDateTime
      changed_attributes['content'] = nil
    end

    def content_changed?
      return false if ['E','R'].include? controlGroup
      return true if new? and !content.blank? # new datastreams must have content

      return true unless content == datastream_content


      super
    end

    def changed?
      super || content_changed?
    end

    def has_content?
      # persisted objects are required to have content
      return true unless new?

      # type E and R objects should have content.
      return !dsLocation.blank? if ['E','R'].include? controlGroup

      # if we've set content, then we have content.

      # return true if instance_variable_defined? :@content

      @content.is_a?(IO) || !content.blank?
    end

    # Retrieve the datastream profile as a hash (and cache it)
    # @param opts [Hash] :validateChecksum if you want fedora to validate the checksum
    # @return [Hash] see Fedora #getDatastream documentation for keys
    def profile opts= {}
      if @profile && !(opts[:validateChecksum] && !@profile.has_key?('dsChecksumValid'))
        ## Force a recheck of the profile if they've passed :validateChecksum and we don't have dsChecksumValid
        return @profile
      end
      
      return @profile = {} unless digital_object.respond_to? :repository
      
      @profile = begin
        xml = profile_xml(opts)

        (self.profile_xml_to_hash(xml) unless xml.blank?) || {}
      end
    end

    def profile_xml opts = {}
      @profile_xml = nil unless opts.empty?
      
      @profile_xml ||= begin

        options = { :pid => pid, :dsid => dsid }
        options.merge!(opts)
        options[:asOfDateTime] = asOfDateTime if asOfDateTime
        options[:validateChecksum] = true if repository.config[:validateChecksum]
        repository.datastream(options)
      rescue RestClient::Unauthorized => e
        raise e
      rescue RestClient::ResourceNotFound
        # the datastream is new
        ''
      end
    end

    def profile= profile_xml
      @profile = self.profile_xml_to_hash(profile_xml)
    end

    def profile_xml_to_hash profile_xml
      profile_xml.gsub! '<datastreamProfile', '<datastreamProfile xmlns="http://www.fedora.info/definitions/1/0/management/"' unless profile_xml =~ /xmlns=/
      doc = Nokogiri::XML(profile_xml)
      h = doc.xpath('/management:datastreamProfile/*', {'management' => "http://www.fedora.info/definitions/1/0/management/"} ).inject({}) do |sum, node|
                   sum[node.name] ||= []
                   sum[node.name] << node.text
                   sum
                 end.reject { |key, values| values.empty? }
      h.select { |key, values| values.length == 1 }.each do |key, values|
        h[key] = values.reject { |x| x.empty? }.first 
      end

      h['dsSize'] &&= h['dsSize'].to_i rescue h['dsSize']
      h['dsCreateDate'] &&= Time.parse(h['dsCreateDate']) rescue h['dsCreateDate']
      h['dsChecksumValid'] &&= h['dsChecksumValid'] == 'true' 
      h['dsVersionable'] &&= h['dsVersionable'] == 'true' 
      h
    end

    def versions
      versions_xml = repository.datastream_versions(:pid => pid, :dsid => dsid)
      return [] if versions_xml.nil?
      versions_xml.gsub! '<datastreamProfile', '<datastreamProfile xmlns="http://www.fedora.info/definitions/1/0/management/"' unless versions_xml =~ /xmlns=/
      doc = Nokogiri::XML(versions_xml)
      doc.xpath('//management:datastreamProfile', {'management' => "http://www.fedora.info/definitions/1/0/management/"} ).map do |ds|
        self.class.new @digital_object, @dsid, :profile => ds.to_s, :asOfDateTime => ds.xpath('management:dsCreateDate', 'management' => "http://www.fedora.info/definitions/1/0/management/").text
      end
    end

    # Add datastream to Fedora
    # @return [Rubydora::Datastream]
    def create
      check_if_read_only
      run_callbacks :create do
        repository.add_datastream to_api_params.merge({ :pid => pid, :dsid => dsid, :content => content })
        reset_profile_attributes
        self.class.new(digital_object, dsid, @options)
      end
    end

    # Modify or save the datastream
    # @return [Rubydora::Datastream]
    def save
      check_if_read_only
      run_callbacks :save do
        return create if new?
        repository.modify_datastream to_api_params.merge({ :pid => pid, :dsid => dsid })
        reset_profile_attributes
        self.class.new(digital_object, dsid, @options)
      end
    end

    # Purge the datastream from Fedora
    # @return [Rubydora::Datastream] `self`
    def delete
      check_if_read_only
      run_callbacks :destroy do
        repository.purge_datastream(:pid => pid, :dsid => dsid) unless self.new?
        digital_object.datastreams.delete(dsid)
        reset_profile_attributes
        self
      end
    end

    def datastream_will_change!
      attribute_will_change! :profile
    end

    protected
    # datastream parameters 
    # @return [Hash]
    def to_api_params
      h = default_api_params
      valid_changed_attributes = changes.keys.map { |x| x.to_sym }.select { |x| DS_ATTRIBUTES.key? x }
      valid_changed_attributes += [:content] if content_changed? and !valid_changed_attributes.include? :content
      ## if we don't provide a mimeType, application/octet-stream will be used instead
      (valid_changed_attributes | [:mimeType]).each do |attribute|
        h[attribute.to_sym] = send(attribute) unless send(attribute).nil?
      end

      h
    end

    # default datastream parameters
    # @return [Hash]
    def default_api_params
      return default_attributes.dup if new?
      {}
    end

    # reset all profile attributes
    # @return [Hash]
    def reset_profile_attributes
      @profile = nil
      @profile_xml = nil
      @datastream_content = nil
      @changed_attributes = {}
    end

    # repository reference from the digital object
    # @return [Rubydora::Repository]
    def repository
      digital_object.repository
    end

    def asOfDateTime= val
      @asOfDateTime = val
    end

    def check_if_read_only
      raise "Can't change values on older versions" if @asOfDateTime
    end

    def validate_dsLocation! val
      URI.parse(val) unless val.nil?
    end

    private
    def attribute_will_change! *args
      check_if_read_only
      super
    end
  end
end
