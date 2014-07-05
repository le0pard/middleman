require 'pathname'
require 'set'

module Middleman
  module CoreExtensions
    # API for watching file change events
    class FileWatcher < Extension
      # Regexes in this list will filter out filenames of files that shouldn't cause file change notifications.
      IGNORE_LIST = [
        /^bin(\/|$)/,
        /^\.bundle(\/|$)/,
        /^vendor(\/|$)/,
        /^node_modules(\/|$)/,
        /^\.sass-cache(\/|$)/,
        /^\.cache(\/|$)/,
        /^\.git(\/|$)/,
        /^\.gitignore$/,
        /\.DS_Store/,
        /^\.rbenv-.*$/,
        /^Gemfile$/,
        /^Gemfile\.lock$/,
        /~$/,
        /(^|\/)\.?#/,
        /^tmp\//
      ]

      attr_reader :api

      # Before parsing config, load the data/ directory
      def before_configuration
        app.config.define_setting :file_watcher_ignore, IGNORE_LIST, 'Regexes for paths that should be ignored when they change.'

        @api = API.new(app)
        app.add_to_config_context :files, &method(:api)
      end

      def after_configuration
        app.config[:file_watcher_ignore] << %r{^#{app.config[:build_dir]}(\/|$)}
        @api.reload_path('.')
      end

      # Core File Change API class
      class API
        extend Forwardable

        attr_reader :app
        attr_reader :known_paths

        def_delegator :@app, :logger

        # Initialize api and internal path cache
        def initialize(app)
          @app = app
          @known_paths = Set.new

          @_changed = []
          @_deleted = []
        end

        # Add callback to be run on file change
        #
        # @param [nil,Regexp] matcher A Regexp to match the change path against
        # @return [Array<Proc>]
        def changed(matcher=nil, &block)
          @_changed << [block, matcher] if block_given?
          @_changed
        end

        # Add callback to be run on file deletion
        #
        # @param [nil,Regexp] matcher A Regexp to match the deleted path against
        # @return [Array<Proc>]
        def deleted(matcher=nil, &block)
          @_deleted << [block, matcher] if block_given?
          @_deleted
        end

        # Notify callbacks that a file changed
        #
        # @param [Pathname] path The file that changed
        # @return [void]
        def did_change(path)
          path = Pathname(path)
          logger.debug "== File Change: #{path}"
          @known_paths << path
          run_callbacks(path, :changed)
        end

        # Notify callbacks that a file was deleted
        #
        # @param [Pathname] path The file that was deleted
        # @return [void]
        def did_delete(path)
          path = Pathname(path)
          logger.debug "== File Deletion: #{path}"
          @known_paths.delete(path)
          run_callbacks(path, :deleted)
        end

        # Manually trigger update events
        #
        # @param [Pathname] path The path to reload
        # @param [Boolean] only_new Whether we only look for new files
        # @return [void]
        def reload_path(path, only_new=false)
          # chdir into the root directory so Pathname can work with relative paths
          Dir.chdir @app.root_path do
            path = Pathname(path)
            return unless path.exist?

            glob = (path + '**').to_s
            subset = @known_paths.select { |p| p.fnmatch(glob) }

            ::Middleman::Util.all_files_under(path, &method(:ignored?)).each do |filepath|
              next if only_new && subset.include?(filepath)

              subset.delete(filepath)
              did_change(filepath)
            end

            subset.each(&method(:did_delete)) unless only_new
          end
        end

        # Like reload_path, but only triggers events on new files
        #
        # @param [Pathname] path The path to reload
        # @return [void]
        def find_new_files(path)
          reload_path(path, true)
        end

        def exists?(path)
          p = Pathname(path)
          p = p.relative_path_from(Pathname(@app.root)) unless p.relative?
          @known_paths.include?(p)
        end

        # Whether this path is ignored
        # @param [Pathname] path
        # @return [Boolean]
        def ignored?(path)
          path = path.to_s
          app.config[:file_watcher_ignore].any? { |r| path =~ r }
        end

        protected

        # Notify callbacks for a file given an array of callbacks
        #
        # @param [Pathname] path The file that was changed
        # @param [Symbol] callbacks_name The name of the callbacks method
        # @return [void]
        def run_callbacks(path, callbacks_name)
          path = path.to_s
          send(callbacks_name).each do |callback, matcher|
            next unless matcher.nil? || path.match(matcher)
            @app.instance_exec(path, &callback)
          end
        end
      end
    end
  end
end
