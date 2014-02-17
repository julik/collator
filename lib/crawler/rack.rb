class Collator::RackCrawler < Collator::Crawler
  include Rack::Test::Methods
  
  # Returns the app as per Rack::Test protocol
  def app
    vitrine = Vitrine::App.new
    vitrine.settings.set :root, APP_DIR
    vitrine
  end
  
  # Returns a Response with body and headers. If something
  # unexpected happens, raise from here
  def get(url)
    super
    raise "Something went wrong - #{last_response.status}" unless last_response.ok?
    Response.new(last_response.body, last_response.headers)
  end
end