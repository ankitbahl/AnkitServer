require 'sinatra'
require 'sinatra/cors'
require 'webrick/ssl'
require 'webrick/https'
require 'combine_pdf'
require 'nokogiri'
require 'net/http'
require 'uri'
require 'json'
require 'zip'
require 'securerandom'
require 'http'


webrick_options = {
    :Port               => 6969,
    :Logger             => WEBrick::Log::new($stderr, WEBrick::Log::DEBUG),
    :DocumentRoot       => "/ruby/htdocs",
    :SSLEnable          => false,
    :SSLVerifyClient    => OpenSSL::SSL::VERIFY_NONE,
    :SSLCertificate     => OpenSSL::X509::Certificate.new(  File.open("cert.pem").read),
    :SSLPrivateKey      => OpenSSL::PKey::RSA.new(          File.open("privkey.pem").read),
    :SSLCertName        => [ [ "CN",WEBrick::Utils::getservername ] ],
    :Host => "0.0.0.0"
}
class ZipFileGenerator
  # Initialize with the directory to zip and the location of the output archive.
  def initialize(input_dir, output_file)
    @input_dir = input_dir
    @output_file = output_file
  end

  # Zip the input directory.
  def write
    entries = Dir.entries(@input_dir) - %w[. ..]

    ::Zip::File.open(@output_file, ::Zip::File::CREATE) do |zipfile|
      write_entries entries, '', zipfile
    end
  end

  private

  # A helper method to make the recursion work.
  def write_entries(entries, path, zipfile)
    entries.each do |e|
      zipfile_path = path == '' ? e : File.join(path, e)
      disk_file_path = File.join(@input_dir, zipfile_path)

      if File.directory? disk_file_path
        recursively_deflate_directory(disk_file_path, zipfile, zipfile_path)
      else
        put_into_archive(disk_file_path, zipfile, zipfile_path)
      end
    end
  end

  def recursively_deflate_directory(disk_file_path, zipfile, zipfile_path)
    zipfile.mkdir zipfile_path
    subdir = Dir.entries(disk_file_path) - %w[. ..]
    write_entries subdir, zipfile_path, zipfile
  end

  def put_into_archive(disk_file_path, zipfile, zipfile_path)
    zipfile.add(zipfile_path, disk_file_path)
  end
end

class Server < Sinatra::Base
  File.open('captcha_secret.txt').each do |cap|
    CAPTCHA_KEY = cap.strip
  end
  $Store = {
      jobs: {
      }
  }
  configure do
    enable :cross_origin
  end

  before do
    response.headers['Access-Control-Allow-Origin'] = '*'
  end
  File.open('userpass.txt').each do |auth|
	  $AUTH_KEY = auth.strip
  end
  # post '/merge' do
  #   File.open('files.zip', 'w') do |f|
  #       f.write(request.body.read.to_s)
  #   end
  #   `mkdir files`
  #   `mv files.zip files/`
  #   `yes | unzip files/files.zip -d files/`
  #   `rm files.zip`
  #   files = `ls files/ | grep -i .pdf`.split("\n")
  #   puts files
  #   pdf = CombinePDF.new
  #   files.each do |file|
  #     pdf << CombinePDF.load("files/#{file}")
  #   end
  #   pdf.save "combined.pdf"
  #   `mv combined.pdf public/combined.pdf`
  #   `rm -rf files`
  #   File.read(File.join('public', 'combined.pdf'))
  # end

  def randomString
    SecureRandom.base64
  end

  def auth
    unless $Store.key?'auth'
      puts 'No one has logged in yet'
      status(401)
      return false
    end

    if $Store['auth'][:expiry] < Time.now.to_i
      puts('Token Expired')
      status(401)
      return false
    end

    auth_token = params['auth']
    puts 'received token:'
    puts auth_token
    if auth_token != $Store['auth'][:value]
      puts('Invalid Token')
      status(401)
      return false
    end

    # token is valid, refresh
    $Store['auth'][:expiry] = Time.now.to_i + 3600 * 2
    return true
  end

  def validateCaptcha(captcha)
    body = {
        'secret': CAPTCHA_KEY,
        'response': captcha
    }

  # Send the request
    response = HTTP.post('https://www.google.com/recaptcha/api/siteverify', :form => body)
    puts response.to_s
    return JSON.parse(response.to_s)['success']
  end

  def sanitize_input(str)
    chars = str.split('')
    chars.each do |c|
      if (c =~ /[a-zA-Z0-9_ ,\-]/).nil?
        puts "#{c} is bad char"
        return false
      end
    end
    true
  end

  post '/login' do
    body = JSON.parse(request.body.read)
    captcha = body['captcha']
    unless validateCaptcha(captcha)
      puts 'bad captcha'
      status(401)
      return
    end
    auth_token = body['auth']
    if auth_token == $AUTH_KEY
      if $Store.key?('auth') and $Store['auth'][:expiry] >= Time.now.to_i
        token = $Store['auth'][:value]
        $Store['auth'][:expiry] = Time.now.to_i + 3600 * 24
        expiry = $Store['auth'][:expiry]
      else
        token = randomString
        expiry = Time.now.to_i + 3600 * 24

        $Store['auth'] = {
            value: token,
            expiry: expiry
        }
      end
      return {
          token: token,
          expiry: expiry
      }.to_json
    else
      puts 'bad pass'
      status(401)
    end
  end

  get '/manga-names/:name' do
    return unless auth
    search_term = params['name']
    search_term = search_term.gsub(' ', '_')
    search_url = "https://manganelo.com/search/#{search_term}"
    uri = URI.parse(search_url)
    req = Net::HTTP.new(uri.host, uri.port)
    req.use_ssl = true
    res = req.get(uri.request_uri)
    document = Nokogiri::HTML(res.body)
    document.css('.story_item').map do |search_item|
      {
          title: search_item.css('.story_name a')[0].content,
          url: search_item.css('a')[0].attr('href').split('/').last,
          pic: search_item.css('img')[0].attr('src')
      }
    end.to_json
  end

  post '/manga' do
    return unless auth
    id = rand(1..10000)
    while $Store[:jobs].key?(id)
      id = rand(1..10000)
    end
    url = params['url']
    name = params['name']
    arg1 = params['arg1']
    arg2 = params['arg2']
    puts url
    puts name
    puts arg1
    puts arg2
    args = "#{id} #{url} #{arg1} #{arg2} #{name}"
    unless sanitize_input(args)
      'bad input!'
    end
    command = "ruby ./downloader.rb #{args} && zip -r output_#{id}.zip out_#{id} && mv output_#{id}.zip public/output_#{id}.zip && touch done_#{id}.t"
    pid = spawn(command)
    Process.detach(pid)
    $Store[:jobs][id] = true
    'started'
  end

  get '/manga' do
    return unless auth
    `rm progress_#{id}.t`
    `rm out/out_#{id}.zip`
    send_file 'public/output.zip', :filename => 'output.zip', :type => 'Application/octet-stream'
  end

  get '/progress' do
    return unless auth
    if File.exist? 'done.t'
      'done'
    else
      `cat ./progress.t`
    end
  end

  #
  # FILE SERVER
  #

  get '/keys' do
    return unless auth
    path = params['path']
    val = Dir.entries("public/#{path}").select {|f| !File.directory? f}.map do |key|
      {
        path: "#{path}/#{key.gsub("\\", "/")}",
        size: File.size("public/#{path}/#{key}"),
        lastModified: File.mtime("public/#{path}/#{key}").to_i,
        isDirectory: File.directory?("public/#{path}/#{key}")
      }
    end.to_json
    return val
  end

  get '/file' do
    return unless auth
    path = params['path']
    send_file "public/#{path}", :filename => path.split('/')[-1],:type => 'Application/octet-stream'
  end

  get '/folder' do
    return unless auth
    `rm public/folder.zip`
    path = "public/#{params['path']}"
    output_path = 'public/folder.zip'
    zf = ZipFileGenerator.new(path, output_path)
    zf.write
    send_file output_path, :filename => 'folder.zip', :type => 'Application/octet-stream'
  end

  post '/upload' do
    return unless auth
    path = params['path']
    filename = params[:file][:filename]
    file = params[:file][:tempfile]
    File.open("./public/#{path}/#{filename}", 'wb') do |f|
      f.write(file.read)
    end
    'Success'
  end

  options "*" do
    response.headers["Allow"] = "GET, PUT, POST, DELETE, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type, Accept, X-User-Email, X-Auth-Token, captcha, auth"
    response.headers["Access-Control-Allow-Origin"] = "*"
    200
  end

end

Rack::Handler::WEBrick.run Server, webrick_options
