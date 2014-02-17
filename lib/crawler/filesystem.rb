class Collator::FilesystemCrawler < Collator::Crawler
  def initialize(path_to_dir)
    @dir = File.expand_path(path_to_dir)
  end
  
  # Returns a Response with body and headers. If something
  # unexpected happens, raise from here
  def get(url)
    path = File.join(@dir, url)
    raise "No such file: #{path}" unless File.exist?(path)
    Response.new(File.read(path), headers = {})
  end
end