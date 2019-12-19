#!/usr/bin/env ruby

require 'net/http'
require 'nokogiri'
require 'rmagick'
require 'async'
require 'async/http/internet'
require 'thread'
$sem = Mutex.new

def get_url_fragment(search_term, job_id)
  search_term = search_term.gsub(' ', '_')
  search_url = "https://manganelo.com/search/#{search_term}"
  uri = URI.parse(search_url)
  req = Net::HTTP.new(uri.host, uri.port)
  req.use_ssl = true
  res = req.get(uri.request_uri)
  document = Nokogiri::HTML(res.body)
  options = document.css('.story_item').map do |search_item|
    {
        title: search_item.css('.story_name a')[0].content,
        url: search_item.css('a')[0].attr('href').split('/').last
    }
  end

  (0..[6, options.length - 1].min).each do |i|
    puts "#{i + 1}: #{options[i][:title]}"
  end

  puts 'Enter number for which you want to download: '
  option = STDIN.gets.gsub(/[ \n]/, '').to_i
  `echo #{options[option - 1][:title]} > build/#{job_id}/title.t`
  options[option - 1][:url]
end

def async_image(url, i, page, job_id)
  Async.run do
    internet = Async::HTTP::Internet.new
    # Make a new internet:

    # Issues a GET request to Google:
    response = internet.get(url)
    response.save("build/#{job_id}/Chapter_#{i}/page_#{page}.jpg")

    # The internet is closed for business:
    internet.close
    img = Magick::Image::read("build/#{job_id}/Chapter_#{i}/page_#{page}.jpg").first
    if img.columns > img.rows
      img.rotate! 90
      img.write("build/#{job_id}/Chapter_#{i}/page_#{page}.jpg")
    end
  end
end

def compile_pdfs(start_chapter, end_chapter, job_id)
  puts "Writing #{start_chapter} to #{end_chapter}"
  title = `cat build/#{job_id}/title.t`
  image_list = []
  (start_chapter..end_chapter).each do |chap|
    dir = "./build/#{job_id}/Chapter_#{chap}"
    num_pages = Dir[File.join(dir, '**', '*')].count { |file| File.file?(file)}
    for num in 0..num_pages - 1
      image_list.push("build/#{job_id}/Chapter_#{chap}/page_#{num}.jpg")
    end
  end
  img = Magick::ImageList.new(*image_list)
  img.write("out_#{job_id}/#{title}_chap_#{start_chapter}-#{end_chapter}.pdf")
  puts "Done writing chapters #{start_chapter}-#{end_chapter}"
  update_progress(job_id)
end

def update_progress(job_id)
  $progress += 100 / $total_progress
  `echo #{$progress} > progress_#{job_id}.t`
end

if ARGV.length < 4
  puts 'usage is "./downloader.rb id search_term vol1_start,vol2_start... vol1_end, vol2_end..."'
  raise RuntimeError
end

start_chapters = ARGV[2].split(',').map(&:to_i)
end_chapters = ARGV[3].split(',').map(&:to_i)
job_id = ARGV[0]
`rm -rf build/#{job_id}` if File.exist?("build/#{job_id}")
if ARGV.length > 4
  `mkdir build/#{job_id}`
  `touch build/#{job_id}/title.t`
  `echo #{ARGV[4]} > build/#{job_id}/title.t`
end
Dir.mkdir('build') unless File.exist?('build')
Dir.mkdir("out_#{job_id}") unless File.exist?("out_#{job_id}")
puts ARGV[1]
if ARGV[1].include? '_'
  fragment = ARGV[1]
else
  fragment = get_url_fragment(ARGV[1], job_id)
end
url_base = "https://manganelo.com/chapter/#{fragment}/chapter_"
`rm progress_#{job_id}.t`
`touch progress_#{job_id}.t`
`echo 0 > progress_#{job_id}.t`
$progress = 0
$total_progress = start_chapters.length
for vol in 0..start_chapters.length - 1
  $total_progress += end_chapters[vol] - start_chapters[vol] + 1
end
threads = []
for vol in 0..start_chapters.length - 1
  start_chapter = start_chapters[vol]
  end_chapter = end_chapters[vol]
  for i in start_chapter..end_chapter
    puts "Chapter #{i}"
    uri = URI.parse("#{url_base}#{i}")
    req = Net::HTTP.new(uri.host, uri.port)
    req.use_ssl = true
    res = req.get(uri.request_uri)
    document = Nokogiri::HTML(res.body)
    Dir.mkdir "build/#{job_id}/Chapter_#{i}"
    page = 0
    Async do
      document.css('.vung-doc').css('img').each do |img|
        url = img.attr('src')
        async_image(url, i, page, job_id)
        page += 1
      end
    end
    update_progress
  end
  tmp = start_chapter
  tmp2 = end_chapter
  t = Thread.new do
    compile_pdfs(tmp, tmp2, job_id)
  end

  threads.push(t)
end

threads.each(&:join)