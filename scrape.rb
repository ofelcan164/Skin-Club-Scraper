require "awesome_print"
require "watir"
require 'pry'
require 'csv'

class CaseScraper
  attr_reader :case_items, :case_price, :case_name, :cases, :expected_return, :expected_profit, :crawling, :not_found, :to_file, :refresh_files, :urls, :home_url, :cur_url

  def initialize(cases: [], to_file: false, refresh_files: false)
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
    @refresh_files = refresh_files
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

  def refresh_browser_state

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

    urls.each do |url|
      @cur_url = url
      case_name = url.split('/').last
      filename = "cases/#{case_name}.txt" if to_file
      with_stdout_to_file(filename: filename) do
        scrape_page(url)
      end

      ap "--- Scraped #{filename.split('/').last[0...-4]} ---" if to_file
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
    ap ap top_x_by_(:max_gain_percent, x: x, dir: :bottom)
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

      stats if !not_found && !refresh_files
      reset_values
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

  def stats
    puts "Case Name:"
    ap case_name
    puts "Case Cost:"
    ap case_price
    puts "Expected Return $:"
    ap expected_return
    puts "Expected Profit $:"
    ap expected_profit
    puts "Expected Return %:"
    ap expected_percent_return = (expected_return / case_price)*100 if case_price != 0
    puts "Expected Profit %:"
    ap expected_percent_profit = (expected_profit / case_price)*100 if case_price != 0
    puts "Maximum Loss $:"
    ap max_loss = (case_price - (case_items.map { |x| x[:price] }).min).abs
    puts "Maximum Loss %:"
    ap max_loss_percent = (max_loss / case_price)*100 if case_price != 0
    puts "Maximum Gain $:"
    ap max_gain = (case_price - (case_items.map { |x| x[:price] }).max).abs
    puts "Maximum Gain  %:"
    ap max_gain_percent = (max_gain / case_price)*100 if case_price != 0

    @stats[case_name] = { case_price: case_price, 
                          expected_return_dollars: expected_return, 
                          expected_profit_dollars: expected_profit, 
                          expected_percent_return: expected_percent_return, 
                          expected_percent_profit: expected_percent_profit,
                          max_loss: max_loss,
                          max_loss_percent: max_loss_percent,
                          max_gain: max_gain,
                          max_gain_percent: max_gain_percent,
                          url: cur_url
                        }
  end

  def get_stats
    @stats
  end

  def stats_to_csv(ranking: :expected_percent_profit)
    hashes = get_stats.sort_by { |k, h| h[ranking]}.reverse
    column_names = [:rank, :name] + hashes.first.last.keys
    s = CSV.generate do |csv|
      csv << column_names
      hashes.each.with_index(1) do |x, i|
        csv << ([i, x.first] + x.last.values)
      end
    end
    File.write("stats_#{ranking.to_s}.csv", s)
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
      puts 'retying getting case urls in 30 secs'
      sleep 30
      get_case_urls
    end
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
scraper = CaseScraper.new(to_file: true)
scraper.crawl!
rankings = [:expected_percent_profit, :expected_profit_dollars, :max_loss_percent, :max_loss, :max_gain_percent, :max_gain]
rankings.each { |r| scraper.stats_to_csv(ranking: r) }
# scraper.scrape_page 'https://skin.club/en/cases/open/el-classico-case'
# scraper.test
scraper.browser.close