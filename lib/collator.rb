# A brutal splicer for "things that support source maps"
module Collator
  
# Fetches the files and source maps. Has one public method
# get() which returns a Response (an object that should have
# Response#body for the response body string and Response#headers
# for the response headers. You can use it in concert with Capybara
# or Rack::Test, at your leisure. You can also make it fetch stuff off
# the filesystem - but since our compilers are mounted as a Rack app
# it makes much more sense for us to use that same Rack app to build us
# the sources
class Crawler
  # What gets returned from get()
  class Response < Struct.new :body, :headers
  end
  
  # Returns a Response with body and headers hash. If something
  # unexpected happens, raise from here
  def get(url)
    raise "Needs to be implemented"
  end
end

# Accumulator for sources and their source maps.
# http://blog.safaribooksonline.com/2013/12/06/source-maps-uglifyjs2-coffeescript/
# https://github.com/mishoo/UglifyJS2/issues/145
# http://stackoverflow.com/questions/14207983
class Splicer
  # Creates a new Splicer, doesn't accept any arguments
  def initialize
    @sources = StringIO.new
    @maps = []
  end

  # //# sourceMappingURL=/js/components/player-buttons.js.map
  SOURCEMAP_HEAD = Regexp.escape('sourceMappingURL=')
  # Do not assume JS comment syntax - CSS has source maps too
  SOURCEMAP_LINE_RE = /(^(.+)#{SOURCEMAP_HEAD}(.+))$/

  # Extracts the source map URL from the passed body or headers.
  # Map mentioned inline in the body has precedence over
  # SourceMap and X-SourceMap headers
  def source_map_url_from(body, headers)
    if body =~ SOURCEMAP_LINE_RE
      sourcemap_url = $3.gsub(/(\s)([^\s]+)$/, '') # Remove the "..map */ CSS closing comment"
      return sourcemap_url
    elsif headers['SourceMap']
      headers['SourceMap']
    else
      headers['X-SourceMap']
    end
  end
  
  # Adds a script at url and it's source map body (JSON string).
  # If the source map argument is omitted the source will be treated
  # as "unmapped" and spliced into the output "as is"
  def add_script(url, source, source_map_body = nil)
    without_sourcemap_trailer = remove_sourcemap_declaration(source)
    if source_map_body
      @maps << SourceMap::Map.from_json(source_map_body)
    else
      @maps << generate_identity_map(url, without_sourcemap_trailer)
    end
    @sources.puts(without_sourcemap_trailer)
  end
  
  # Generate a source map which refers a whole chunk of the concatenated
  # body (the whole passed source_body) to the file at source_url. It's an
  # identity map because it maps code to itself basically.
  def generate_identity_map(source_url, source_body)
    mp = []
    source_body.split("\n").each_with_index do | line, n |
      last_col = line.length
      mp << SourceMap::Mapping.new(source_url, SourceMap::Offset.new(n, 0), SourceMap::Offset.new(n, 0))
      mp << SourceMap::Mapping.new(source_url, SourceMap::Offset.new(n, last_col), SourceMap::Offset.new(n, last_col))
    end
    SourceMap::Map.new(mp)
  end
  
  # Returns the compiled script string that 
  # can be written into a file. 
  # NOTE: The returned script will not include the sourcemap URL declaration!
  def compile_script_string
    @sources.string
  end
  
  # Returns the compiled source map string that 
  # can be written into a file
  def compile_sourcemap_string
    JSON.dump(compile_sourcemap)
  end
  
  private
  
  # Concatenates the source maps that have been buffered so far.
  # They add up recursively, adding offsets as they go.
  # It's horrible we have to do this but UglifyJS2 does not support
  # source map sections
  def compile_sourcemap
    combo_map = nil
    # SourceMap::Map#+ does source map merges, so...
    @maps.each_with_index do | map_object |
      combo_map = (combo_map ? combo_map + map_object : map_object)
    end
    combo_map.as_json # to_json of this one does not conform to ActiveSupport
  end
  
  # Strips the passed string of it's source map declaration.
  # The declaration is usually added after the code, and it
  # will disturb the offsets when we concatenate files together.
  def remove_sourcemap_declaration(source)
    # Doing an rstrip() is essential here - otherwise we disturb the line counts
    # in the source maps (line offsets in the concatenated source)
    source.gsub(SOURCEMAP_LINE_RE, '').rstrip
  end
end

class Build
  attr_reader :basename
  attr_accessor :extension
  
  def initialize
    timestamp = Time.now.utc.strftime("%Y.%m.%d.%H.%M") # UTC timestamp to the minute
    @basename = "build.#{timestamp}"
  end
  
  def crawl_and_splice(file_urls)
    crawler = Crawler.new
    buf = Splicer.new
    
    # Crawl all the passed URLs and pull up all of 
    # their related compiled bodies and maps into the Splicer
    file_urls.each do | js_file_url |
      
      response = crawler.get js_file_url
      
      compiled_body = response.body
      compiled_body.force_encoding("ASCII-8BIT") # Ensure the thing arrives as binary
      
      # Try to detect a source map
      sourcemap_url = buf.source_map_url_from(compiled_body, crawler.last_response.headers)
      if sourcemap_url
        # And the source map...
        puts "Fetched #{js_file_url} + source map #{sourcemap_url}"
        
        # Fetch the source map and record the offset
        response = crawler.get(sourcemap_url)
        buf.add_script(js_file_url, compiled_body, response.body)
      else
        puts "Fetched #{js_file_url}"
        buf.add_script(js_file_url, compiled_body, nil)
      end
    end
    
    buf
  end
  
  # Run a block with the working directory set to
  # working_dir (useful for JS-based tools that expect to be
  # in the working directory at call time)
  def in_directory(working_dir)
    old_dir = Dir.pwd
    begin
      Dir.chdir working_dir
      yield
    ensure
      Dir.chdir old_dir
    end
  end
  
  def spliced_script_and_sourcemap(file_urls)
    buf = crawl_and_splice(file_urls)
    [buf.compile_script_string, buf.compile_sourcemap_string] 
  end
  
  def collate_and_uglify_to_cwd(file_urls)
    buf = crawl_and_splice(file_urls)
    
    destination = "#{basename}.js"
    min_destination = "#{basename}.min.js"
    map_min_destination = "#{basename}.min.map"
    
    oog = Uglifier.new :input_source_map => buf.compile_sourcemap_string
    
    puts "Smashing the resulting JS with UglifyJS"
    
    uglified, source_map = oog.compile_with_map(buf.compile_script_string)
    uglified << "\n"
    uglified << ('//# sourceMappingURL=%s' % map_min_destination)
    
    File.open(min_destination, 'wb') do | f |
      f.write uglified
    end
    
    File.open(map_min_destination, 'wb') do | f |
      f.write source_map
    end
  end
  
end
end