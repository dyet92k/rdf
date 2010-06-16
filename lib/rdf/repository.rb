module RDF
  ##
  # An RDF repository.
  #
  # @example Creating a transient in-memory repository
  #   repository = RDF::Repository.new
  #
  # @example Checking whether a repository is readable/writable
  #   repository.readable?
  #   repository.writable?
  #
  # @example Checking whether a repository is persistent or transient
  #   repository.persistent?
  #   repository.transient?
  #
  # @example Checking whether a repository is empty
  #   repository.empty?
  #
  # @example Checking how many statements a repository contains
  #   repository.count
  #
  # @example Checking whether a repository contains a specific statement
  #   repository.has_statement?(statement)
  #
  # @example Enumerating statements in a repository
  #   repository.each_statement { |statement| statement.inspect! }
  #
  # @example Inserting statements into a repository
  #   repository.insert(*statements)
  #   repository.insert(statement)
  #   repository.insert([subject, predicate, object])
  #   repository << statement
  #   repository << [subject, predicate, object]
  #
  # @example Deleting statements from a repository
  #   repository.delete(*statements)
  #   repository.delete(statement)
  #   repository.delete([subject, predicate, object])
  #
  # @example Deleting all statements from a repository
  #   repository.clear!
  #
  class Repository
    include RDF::Countable
    include RDF::Enumerable
    include RDF::Queryable
    include RDF::Mutable
    include RDF::Durable

    ##
    # Returns the options passed to this repository when it was constructed.
    #
    # @return [Hash{Symbol => Object}]
    attr_reader :options

    ##
    # Returns the {URI} of this repository.
    #
    # @return [URI]
    attr_reader :uri

    ##
    # Returns the title of this repository.
    #
    # @return [String]
    attr_reader :title

    ##
    # Loads one or more RDF files into a new transient in-memory repository.
    #
    # @param  [String, Array<String>] filenames
    # @yield  [repository]
    # @yieldparam [Repository]
    # @return [void]
    def self.load(filenames, options = {}, &block)
      self.new(options) do |repository|
        [filenames].flatten.each do |filename|
          repository.load(filename, options)
        end

        if block_given?
          case block.arity
            when 1 then block.call(repository)
            else repository.instance_eval(&block)
          end
        end
      end
    end

    ##
    # Initializes this repository instance.
    #
    # @param  [Hash{Symbol => Object}] options
    # @option options [URI, #to_s]    :uri (nil)
    # @option options [String, #to_s] :title (nil)
    # @yield  [repository]
    # @yieldparam [Repository] repository
    def initialize(options = {}, &block)
      @options = options.dup
      @uri     = @options.delete(:uri)
      @title   = @options.delete(:title)

      # Provide a default in-memory implementation:
      send(:extend, Implementation) if self.class.equal?(RDF::Repository)

      if block_given?
        case block.arity
          when 1 then block.call(self)
          else instance_eval(&block)
        end
      end
    end

    ##
    # Returns a developer-friendly representation of this object.
    #
    # @return [String]
    def inspect
      sprintf("#<%s:%#0x(%s)>", self.class.name, object_id, uri.to_s)
    end

    ##
    # Outputs a developer-friendly representation of this object to
    # `stderr`.
    #
    # @return [void]
    def inspect!
      each_statement { |statement| statement.inspect! }
      nil
    end

    ##
    # @see RDF::Repository
    module Implementation
      ##
      # @private
      def self.extend_object(obj)
        obj.instance_variable_set(:@data, {})
        super
      end

      ##
      # Returns `true` if this repository supports `feature`.
      #
      # @param  [Symbol, #to_sym] feature
      # @return [Boolean]
      # @since  0.1.10
      def supports?(feature)
        case feature.to_sym
          when :context   then true   # statement contexts / named graphs
          when :inference then false  # forward-chaining inference
          else false
        end
      end

      ##
      # Returns `false` to indicate that this repository is nondurable.
      #
      # @return [Boolean]
      # @see    RDF::Durable#durable?
      def durable?
        false
      end

      ##
      # Returns `true` if this repository contains no RDF statements.
      #
      # @return [Boolean]
      # @see    RDF::Enumerable#empty?
      def empty?
        @data.empty?
      end

      ##
      # Returns the number of RDF statements in this repository.
      #
      # @return [Integer]
      # @see    RDF::Enumerable#count
      def count
        count = 0
        @data.each do |c, ss|
          ss.each do |s, ps|
            ps.each do |p, os|
              count += os.size
            end
          end
        end
        count
      end

      ##
      # Returns `true` if this repository contains the given RDF statement.
      #
      # @param  [Statement] statement
      # @return [Boolean]
      # @see    RDF::Enumerable#has_statement?
      def has_statement?(statement)
        s, p, o, c = statement.to_quad
        @data.has_key?(c) &&
          @data[c].has_key?(s) &&
          @data[c][s].has_key?(p) &&
          @data[c][s][p].include?(o)
      end

      ##
      # Enumerates each RDF statement in this repository.
      #
      # @yield  [statement]
      # @yieldparam [Statement] statement
      # @return [Enumerator]
      # @see    RDF::Enumerable#each_statement
      def each(&block)
        if block_given?
          # Note that to iterate in a more consistent fashion despite
          # possible concurrent mutations to `@data`, we use `#dup` to make
          # shallow copies of the nested hashes before beginning the
          # iteration over their keys and values.
          @data.dup.each do |c, ss|
            ss.dup.each do |s, ps|
              ps.dup.each do |p, os|
                os.dup.each do |o|
                  block.call(RDF::Statement.new(s, p, o, :context => c))
                end
              end
            end
          end
        else
          enum_statement
        end
      end

      ##
      # Inserts the given RDF statement into the underlying storage.
      #
      # @param  [RDF::Statement] statement
      # @return [void]
      def insert_statement(statement)
        unless has_statement?(statement)
          s, p, o, c = statement.to_quad
          @data[c] ||= {}
          @data[c][s] ||= {}
          @data[c][s][p] ||= []
          @data[c][s][p] << o
        end
      end

      ##
      # Deletes the given RDF statement from the underlying storage.
      #
      # @param  [RDF::Statement] statement
      # @return [void]
      def delete_statement(statement)
        if has_statement?(statement)
          s, p, o, c = statement.to_quad
          @data[c][s][p].delete(o)
          @data[c][s].delete(p) if @data[c][s][p].empty?
          @data[c].delete(s) if @data[c][s].empty?
          @data.delete(c) if @data[c].empty?
        end
      end

      ##
      # Deletes all RDF statements from this repository.
      #
      # @return [void]
      # @see    RDF::Mutable#clear
      def clear_statements
        @data.clear
      end

      protected :insert_statement
      protected :delete_statement
      protected :clear_statements
    end # module Implementation
  end # class Repository
end # module RDF
