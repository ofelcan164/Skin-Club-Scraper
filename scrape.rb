require "awesome_print"
require "watir"
require 'pry'
require 'csv'

class CaseScraper
  attr_reader :case_items, :case_price, :case_name, :cases, :expected_return, :expected_profit, :crawling, :not_found, :to_file, :refresh, :urls, :home_url, :cur_url, :include_free

  def initialize(cases: [], to_file: false, refresh: false, include_free: false)
    @case_items = []
    @case_price = 0
    @cases = cases
    @base_url = 'https://skin.club/en/cases/open/'
    @home_url = 'https://skin.club/en/'
    @crawling = false
    @stats = {}
    @expected_return = 0
    @expected_profit = 0
    @to_file = to_file
    @refresh = refresh
    @include_free = include_free
    Watir.default_timeout = 5
  end
  
  def browser
    # configuring Chrome to run in headless mode
    options = Selenium::WebDriver::Chrome::Options.new 
    options.add_argument("--headless")
    options.add_argument("--disable-gpu")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    @browser ||= Watir::Browser.new(:chrome, options: options)
  end

  def reset_values
    @case_items = []
    @case_price = 0
    @expected_return = 0
    @expected_profit = 0
    @not_found = false
  end

  def with_stdout_to_file(filename: nil)
    old_stdout = STDOUT.clone
    $stdout.reopen(filename, 'w') if filename
    yield
  ensure
    $stdout.reopen(old_stdout)
  end

  def crawl!
    @crawling = true
    get_case_urls

    if refresh
      urls.each do |url|
        @cur_url = url
        case_name = url.split('/').last
        filename = "cases/#{case_name}.txt" if to_file
        with_stdout_to_file(filename: filename) do
          scrape_page(url)
          stats unless not_found
          print_stats unless not_found
          reset_values
        end

        ap "--- Scraped #{filename.split('/').last[0...-4]} ---" if to_file
      end
    else
      add_new_stats
      load_new_stats_from_site
    end

    filename = "max-min-stats.txt" if to_file
    with_stdout_to_file(filename: filename) do 
      puts_max_profit
    end
    @crawling = false
  end

  def puts_max_profit
    x = 10
    puts "\n\n------------\n"
    ap "Top #{x} casess for expected profit as a percent of case price"
    ap top_x_by_(:expected_percent_profit, x: x)
    
    puts "\n\n------------\n"
    ap "Bottom #{x} cases for expected profit as a percent of case price"
    ap top_x_by_(:expected_percent_profit, x: x, dir: :bottom)

    puts "\n\n------------\n"
    ap "Top #{x} cases for expected profit in dollars"
    ap top_x_by_(:expected_profit_dollars, x: x)
    
    puts "\n\n------------\n"
    ap "Bottom #{x} cases for expected profit in dollars"
    ap top_x_by_(:expected_profit_dollars, x: x, dir: :bottom)

    puts "\n\n------------\n"
    ap "Top #{x} cases for max possible loss as a percent of case price"
    ap top_x_by_(:max_loss_percent, x: x, dir: :bottom) # Reversed since lower loss is good

    puts "\n\n------------\n"
    ap "Bottom #{x} cases for max possible loss as a percent of case price"
    ap top_x_by_(:max_loss_percent, x: x) # Not reversed since higher (negative) loss is bad

    puts "\n\n------------\n"
    ap "Top #{x} cases for max possible gain as a percent of case price"
    ap top_x_by_(:max_gain_percent, x: x)

    puts "\n\n------------\n"
    ap "Bottom #{x} cases for max possible gain as a percent of case price"
    ap top_x_by_(:max_gain_percent, x: x, dir: :bottom)
  end

  def top_x_by_(col, x: 5, dir: :top)
    # sort_by defaults to low - high sorting, so reverse to get high to low by default
    sorted_stats = get_stats.sort_by { |name, stats| stats[col] }.reverse
    sorted_stats = if dir == :bottom
      sorted_stats.reverse
    else
      sorted_stats
    end.take(x).to_h

    sorted_stats.map.with_index(1) {|a,i| {i => {name: a.first}.merge(a.last)}}.reduce(:merge)
  end

  def case_url(c)
    @base_url + c
  end

  def clean_text(elm)
    split_text = elm.text.split('-')
    split_text.first.gsub('$', '').gsub('%', '').strip
  end

  def on_screen_text(option)
    return if crawling
    hyphens = ' ------------------------- '
    puts case option
    when :case_price
      hyphens + 'Scraping for case price' + hyphens
    when :case_name
      hyphens + 'Scraping for case name' + hyphens
    when :items
      hyphens + 'Scraping for case items' + hyphens
    end
  end

  def scrape_page(url)
    browser.goto url
    begin
      not_found_elm = browser.element(css: 'div.wrap-404')
      if not_found_elm.present?
        @not_found = true
        ap "🔴🔴🔴🔴🔴🔴 #{c.to_s} NOT FOUND"
        return
      end
      on_screen_text(:case_name)
      @case_name = clean_text(browser.element(css: 'div.case-title > h1').wait_until(&:present?))
      ap @case_name unless crawling
      on_screen_text(:case_price)
      @case_price = clean_text(browser.element(css: 'span[data-qa="sticker_case_price_element"].price').wait_until(&:present?)).to_f
      ap @case_price unless crawling

      button = browser.element(css: '[data-qa="check_odds_range_button"]')
      button.click!

      wrapper = browser.element(css: 'div.simplebar-content-wrapper').wait_until(&:present?)
      wrapper.hover
      wrapper.click!
      row_header = wrapper.element(css: 'div.row.head').wait_until(&:present?)
      row_header.click!
      row_header.hover
      sleep 2
      rows = wrapper.elements(css: 'div.row[data-v-515712f2][data-v-0adadd59].row')

      on_screen_text(:items)
      ap rows.length
      rows.each do |item|
        next if item.classes.include? 'head'
        item.hover
        item.click!
        
        name_wrapper = item.element(css: 'p.name').wait_until(&:present?)
        name_wrapper.hover
        name_wrapper.click!
        name = clean_text(name_wrapper.element(css: 'span.weapon-name').wait_until(&:present?)) + ' | ' +
          clean_text(name_wrapper.element(css: 'span.weapon-finish').wait_until(&:present?))
        price = clean_text(item.element(css: 'div.price-cell').wait_until(&:present?)).to_f
        chance = clean_text(item.element(css: 'div.odds-cell').wait_until(&:present?)).to_f / 100
    
        ap name unless crawling
        @case_items << {chance: chance, price: price}
      end

      ap "-----Items Scraped!-----" unless crawling

      get_return
      get_profit
    rescue Watir::Wait::TimeoutError => e
      puts e
    end
  end

  def get_return
    @expected_return = case_items.map do |item|
      item[:price]*item[:chance]
    end.inject(&:+)
  end

  def get_profit
    @expected_profit = expected_return - case_price 
  end

  def print_stats
    s = @stats[case_name]
    puts "Case Name:"
    ap case_name
    puts "Case Cost:"
    ap s[:case_price]
    puts "Expected Return $:"
    ap s[:expected_return_dollars]
    puts "Expected Profit $:"
    ap s[:expected_profit_dollars]
    puts "Expected Return %:"
    ap s[:expected_percent_return]
    puts "Expected Profit %:"
    ap s[:expected_percent_profit]
    puts "Minimum Profit $:"
    ap s[:min_profit]
    puts "Minimum Profit %:"
    ap s[:min_profit_percent]
    puts "Minimum Loss $:"
    ap s[:min_loss]
    puts "Minimum Loss %:"
    ap s[:min_loss_percent]
    puts "Average Non-Profit Loss"
    ap s[:avg_nonprofit_loss]
    puts "% Chance of Profit"
    ap s[:profit_chance]
    puts "Maximum Loss $:"
    ap s[:max_loss]
    puts "Maximum Loss %:"
    ap s[:max_loss_percent]
    puts "Maximum Gain $:"
    ap s[:max_gain]
    puts "Maximum Gain %:"
    ap s[:max_gain_percent]
  end

  def stats
    expected_percent_return = ((expected_return / case_price)*100 if case_price != 0) || 100
    expected_percent_profit = ((expected_profit / case_price)*100 if case_price != 0) || 100
    min_profit = case_items.map {  |item| item[:price] - case_price }.sort.reject { |item| item < 0 }.first
    min_profit_percent = ((min_profit / case_price)*100 if case_price != 0) if min_profit || 100
    min_loss = case_items.map { |item| item[:price] - case_price }.sort.reject { |item| item >= 0 }.last || 0
    min_loss_percent = ((min_loss / case_price)*100 if case_price != 0) || 100
    avg_nonprofit_loss = case_items.reject { |item| (item[:price] - case_price) > 0 }.map { |item| item[:price] }
    avg_nonprofit_loss_len = avg_nonprofit_loss.length
    avg_nonprofit_loss = ((avg_nonprofit_loss.inject(&:+) / avg_nonprofit_loss_len) if avg_nonprofit_loss_len != 0) || -1*case_price
    avg_nonprofit_loss_percent = (avg_nonprofit_loss / case_price) if case_price != 0 || 0
    profitable_items = case_items.reject {  |item| (item[:price] - case_price) < 0 }
    profit_chance = (profitable_items.map { |item| item[:chance] }.inject(&:+) || 0) * 100
    max_loss = (case_price - (case_items.map { |x| x[:price] }).min).abs
    max_loss_percent = ((max_loss / case_price)*100 if case_price != 0)  || 100
    max_gain = (case_price - (case_items.map { |x| x[:price] }).max).abs
    max_gain_percent = ((max_gain / case_price)*100 if case_price != 0)  || 100

    @stats[case_name] = { case_price: case_price, 
                          expected_return_dollars: expected_return, 
                          expected_profit_dollars: expected_profit, 
                          expected_percent_return: expected_percent_return, 
                          expected_percent_profit: expected_percent_profit,
                          min_profit: min_profit,
                          min_profit_percent: min_profit_percent,
                          profit_chance: profit_chance,
                          avg_nonprofit_loss: avg_nonprofit_loss,
                          min_loss: min_loss,
                          min_loss_percent: min_loss_percent,
                          max_loss: max_loss,
                          max_loss_percent: max_loss_percent,
                          max_gain: max_gain,
                          max_gain_percent: max_gain_percent,
                          url: cur_url
                        }
  end

  def load_stats
    if File.exists?('stats_.csv')
      CSV.foreach('stats_.csv', headers: true, header_converters: :symbol, converters: [CSV::Converters[:float]]) do |row|
        row.delete(:rank)
        name = row[:name]
        row.delete(:name)
        @stats[name] = row.to_h
        @case_name = row[:name]
        @case_price = row[:case_price]
        @expected_return = row[:expected_return_dollars]
        @expected_profit = row[:expected_profit_dollars]
      end
      ap "--- Scraped stats from CSV ---"
    else
      ap "🔴🔴🔴🔴🔴🔴 Refresh set to false but stats_.csv not_found 🔴🔴🔴🔴🔴🔴"
    end
  end

  def load_new_stats_from_site
    get_case_urls

    stats_urls = @stats.map { |k,v| v[:url] }
    urls.each do |url|
      next if stats_urls.include?(url)
      @cur_url = url
      case_name = url.split('/').last
      filename = "cases/#{case_name}.txt" if to_file
      with_stdout_to_file(filename: filename) do
        scrape_page(url)
        stats unless not_found
        print_stats unless not_found
        reset_values
      end

      ap "--- Scraped #{filename.split('/').last[0...-4]} ---" if to_file
    end
  end

  def add_new_stats
    # TODO
    load_stats
    stats
  end

  def get_stats
    @stats
  end

  def get_stats_headers
    get_stats.first.last.keys.reject { |k| %i[case_price url].include?  k}
  end

  def stats_to_csv(ranking: nil)
    hashes = if ranking
      get_stats.sort_by { |k, h| h[ranking]}.reverse
    else
      get_stats
    end
    # hashes looks like:
    #   { <case_name> => { case_price: ..., expected_return_dollars: ..., expected_profit_dollars: ..., ..... }}
    column_names = [:rank, :name] + hashes.first.last.keys
    file = CSV.generate do |csv|
      csv << column_names
      hashes.each.with_index(1) do |x, i|
        csv << ([i, x.first] + x.last.values)
      end
    end
    filename = if include_free
      "stats_#{ranking.to_s}_with_free.csv"
    else
      "stats_#{ranking.to_s}.csv"
    end
    File.write("stats_#{ranking.to_s}.csv", file)
    puts "----- Wrote to #{filename} ----- "
  end

  def get_case_urls
    @urls = if cases.any?
      cases.map do |c|
        case_url(c)
      end
    else
      browser.goto home_url
      wrapper = browser.element(css: 'div#app-vue3').wait_until(&:present?)
      wait_until_this = wrapper.element(css: 'div.feast-banner-inner').wait_until(&:present?)
      crates = wrapper.elements(css: 'a.case-entity')
      crates.map(&:href)
    end

    if urls.length == 0
      puts 'retrying getting case urls in 15 seconds'
      sleep 15
      get_case_urls
    end

    # Add free cases
    if include_free
      @urls << case_url('lvl-3')
      range = (10..120).step(10)
      @urls += range.map { |x| case_url("lvl-#{x}")}
    end
  end

  def refresh!
    @refresh = true
  end

  def test
    browser.goto home_url
    wrapper = browser.element(css: 'div#app-vue3').wait_until(&:present?)
    wait_until_this = wrapper.element(css: 'div.feast-banner-inner').wait_until(&:present?)
    crates = wrapper.elements(css: 'a.case-entity')
    crates.map(&:href)

    i = 0
    crates.each do |crate|
      return if i == 10
      browser.goto crate.href
      i += 1
    end

    
  end
end

# some_cases = %w{ the-last-dance cobblestone-1v4 glovescase karambit_knives top_battle el-classico-case exclusive covert pickle-world diamond superior_overt maneki-neko knife hanami_case steel-samurai cyberpsycho lady_luck easy_m4 easy_ak47 easy_awp ct_pistols_farm t_pistols_farm desrt_eagle_farm easy_knife full-flash overtimes-case mid_case butterfly_knives easy-business}
scraper = CaseScraper.new()
# scraper.refresh!
# scraper.crawl!
# scraper.stats_to_csv
scraper.load_stats
rankings = scraper.get_stats_headers
rankings.each { |r| scraper.stats_to_csv(ranking: r) }
scraper.browser.close