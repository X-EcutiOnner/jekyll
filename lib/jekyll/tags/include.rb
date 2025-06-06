# frozen_string_literal: true

module Jekyll
  module Tags
    class IncludeTag < Liquid::Tag
      VALID_SYNTAX = %r!
        ([\w-]+)\s*=\s*
        (?:"([^"\\]*(?:\\.[^"\\]*)*)"|'([^'\\]*(?:\\.[^'\\]*)*)'|([\w.-]+))
      !x.freeze
      VARIABLE_SYNTAX = %r!
        (?<variable>[^{]*(\{\{\s*[\w\-.]+\s*(\|.*)?\}\}[^\s{}]*)+)
        (?<params>.*)
      !mx.freeze

      FULL_VALID_SYNTAX = %r!\A\s*(?:#{VALID_SYNTAX}(?=\s|\z)\s*)*\z!.freeze
      VALID_FILENAME_CHARS = %r!^[\w/.\-()+~\#@]+$!.freeze
      INVALID_SEQUENCES = %r![./]{2,}!.freeze

      def initialize(tag_name, markup, tokens)
        super
        markup  = markup.strip
        matched = markup.match(VARIABLE_SYNTAX)
        if matched
          @file = matched["variable"].strip
          @params = matched["params"].strip
        else
          @file, @params = markup.split(%r!\s+!, 2)
        end
        validate_params if @params
        @tag_name = tag_name
      end

      def syntax_example
        "{% #{@tag_name} file.ext param='value' param2='value' %}"
      end

      def parse_params(context)
        params = {}
        @params.scan(VALID_SYNTAX) do |key, d_quoted, s_quoted, variable|
          value = if d_quoted
                    d_quoted.include?('\\"') ? d_quoted.gsub('\\"', '"') : d_quoted
                  elsif s_quoted
                    s_quoted.include?("\\'") ? s_quoted.gsub("\\'", "'") : s_quoted
                  elsif variable
                    context[variable]
                  end

          params[key] = value
        end
        params
      end

      def validate_file_name(file)
        if INVALID_SEQUENCES.match?(file) || !VALID_FILENAME_CHARS.match?(file)
          raise ArgumentError, <<~MSG
            Invalid syntax for include tag. File contains invalid characters or sequences:

              #{file}

            Valid syntax:

              #{syntax_example}

          MSG
        end
      end

      def validate_params
        unless FULL_VALID_SYNTAX.match?(@params)
          raise ArgumentError, <<~MSG
            Invalid syntax for include tag:

            #{@params}

            Valid syntax:

            #{syntax_example}

          MSG
        end
      end

      # Grab file read opts in the context
      def file_read_opts(context)
        context.registers[:site].file_read_opts
      end

      # Render the variable if required
      def render_variable(context)
        Liquid::Template.parse(@file).render(context) if VARIABLE_SYNTAX.match?(@file)
      end

      def tag_includes_dirs(context)
        context.registers[:site].includes_load_paths.freeze
      end

      def locate_include_file(context, file, safe)
        includes_dirs = tag_includes_dirs(context)
        includes_dirs.each do |dir|
          path = PathManager.join(dir, file)
          return path if valid_include_file?(path, dir.to_s, safe)
        end
        raise IOError, could_not_locate_message(file, includes_dirs, safe)
      end

      def render(context)
        site = context.registers[:site]

        file = render_variable(context) || @file
        validate_file_name(file)

        path = locate_include_file(context, file, site.safe)
        return unless path

        add_include_to_dependency(site, path, context)

        partial = load_cached_partial(path, context)

        context.stack do
          context["include"] = parse_params(context) if @params
          begin
            partial.render!(context)
          rescue Liquid::Error => e
            e.template_name = path
            e.markup_context = "included " if e.markup_context.nil?
            raise e
          end
        end
      end

      def add_include_to_dependency(site, path, context)
        if context.registers[:page]&.key?("path")
          site.regenerator.add_dependency(
            site.in_source_dir(context.registers[:page]["path"]),
            path
          )
        end
      end

      def load_cached_partial(path, context)
        context.registers[:cached_partials] ||= {}
        cached_partial = context.registers[:cached_partials]

        if cached_partial.key?(path)
          cached_partial[path]
        else
          unparsed_file = context.registers[:site]
            .liquid_renderer
            .file(path)
          begin
            cached_partial[path] = unparsed_file.parse(read_file(path, context))
          rescue Liquid::Error => e
            e.template_name = path
            e.markup_context = "included " if e.markup_context.nil?
            raise e
          end
        end
      end

      def valid_include_file?(path, dir, safe)
        !outside_site_source?(path, dir, safe) && File.file?(path)
      end

      def outside_site_source?(path, dir, safe)
        safe && !realpath_prefixed_with?(path, dir)
      end

      def realpath_prefixed_with?(path, dir)
        File.exist?(path) && File.realpath(path).start_with?(dir)
      rescue StandardError
        false
      end

      # This method allows to modify the file content by inheriting from the class.
      def read_file(file, context)
        File.read(file, **file_read_opts(context))
      end

      private

      def could_not_locate_message(file, includes_dirs, safe)
        message = "Could not locate the included file '#{file}' in any of #{includes_dirs}. " \
                  "Ensure it exists in one of those directories and"
        message + if safe
                    " is not a symlink as those are not allowed in safe mode."
                  else
                    ", if it is a symlink, does not point outside your site source."
                  end
      end
    end

    # Do not inherit from this class.
    # TODO: Merge into the `Jekyll::Tags::IncludeTag` in v5.0
    class OptimizedIncludeTag < IncludeTag
      def render(context)
        @site ||= context.registers[:site]

        file = render_variable(context) || @file
        validate_file_name(file)

        @site.inclusions[file] ||= locate_include_file(file)
        inclusion = @site.inclusions[file]

        add_include_to_dependency(inclusion, context) if @site.config["incremental"]

        context.stack do
          context["include"] = parse_params(context) if @params
          inclusion.render(context)
        end
      end

      private

      def locate_include_file(file)
        @site.includes_load_paths.each do |dir|
          path = PathManager.join(dir, file)
          return Inclusion.new(@site, dir, file) if valid_include_file?(path, dir)
        end
        raise IOError, could_not_locate_message(file, @site.includes_load_paths, @site.safe)
      end

      def valid_include_file?(path, dir)
        File.file?(path) && !outside_scope?(path, dir)
      end

      def outside_scope?(path, dir)
        @site.safe && !realpath_prefixed_with?(path, dir)
      end

      def realpath_prefixed_with?(path, dir)
        File.realpath(path).start_with?(dir)
      rescue StandardError
        false
      end

      def add_include_to_dependency(inclusion, context)
        page = context.registers[:page]
        return unless page&.key?("path")

        absolute_path = \
          if page["collection"]
            @site.in_source_dir(@site.config["collections_dir"], page["path"])
          else
            @site.in_source_dir(page["path"])
          end

        @site.regenerator.add_dependency(absolute_path, inclusion.path)
      end
    end

    class IncludeRelativeTag < IncludeTag
      def load_cached_partial(path, context)
        context.registers[:cached_partials] ||= {}
        context.registers[:cached_partials][path] ||= parse_partial(path, context)
      end

      def tag_includes_dirs(context)
        Array(page_path(context)).freeze
      end

      def page_path(context)
        page, site = context.registers.values_at(:page, :site)
        return site.source unless page

        site.in_source_dir File.dirname(resource_path(page, site))
      end

      private

      def resource_path(page, site)
        path = page["path"]
        path = File.join(site.config["collections_dir"], path) if page["collection"]
        path.delete_suffix("/#excerpt")
      end

      # Since Jekyll 4 caches convertibles based on their path within the only instance of
      # `LiquidRenderer`, initialize a new LiquidRenderer instance on every render of this
      # tag to bypass caching rendered output of page / document.
      def parse_partial(path, context)
        LiquidRenderer.new(context.registers[:site]).file(path).parse(read_file(path, context))
      rescue Liquid::Error => e
        e.template_name = path
        e.markup_context = "included " if e.markup_context.nil?
        raise e
      end
    end
  end
end

Liquid::Template.register_tag("include", Jekyll::Tags::OptimizedIncludeTag)
Liquid::Template.register_tag("include_relative", Jekyll::Tags::IncludeRelativeTag)
