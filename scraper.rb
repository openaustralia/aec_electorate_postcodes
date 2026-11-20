#!/usr/bin/env ruby
# frozen_string_literal: true

# Scrapes which federal electorate(s) each Australian locality and postcode is
# in, from the Australian Electoral Commission's locality search.
#
# The search with no filter lists every electorate. Each electorate's page
# lists its localities, with the state, postcode, the current electorate(s),
# the electorate(s) after any redistribution, and other localities sharing
# the postcode. A locality split between electorates has one link per
# electorate in the same cell.
#
# Both lists are ASP.NET GridViews, paged 20 rows at a time by posting the
# page's form back with __EVENTTARGET and __EVENTARGUMENT (Page$N) set.
#
# Used by openaustralia-parser's parse-postcodes.rb to load the postcode
# lookup on OpenAustralia.org.au and They Vote for You. See
# https://github.com/openaustralia/openaustralia/issues/1060

require "bundler/setup"
Bundler.require

require "scraperwiki"
require "mechanize"

# Scrapes the AEC locality search into the data table
class Scraper
  LISTING_URL = "https://electorate.aec.gov.au/LocalitySearchResults.aspx"
  ELECTORATES_TABLE = "#ContentPlaceHolderBody_gridViewElectorates"
  LOCALITIES_TABLE = "#ContentPlaceHolderBody_gridViewLocalities"
  FORM_ID = "formMaster"
  UNIQUE_KEY = %w[state locality postcode other_localities electorate electorate_type].freeze

  # Raised instead of saving when the scraped data looks incomplete, so the
  # previous run's data is kept
  class IncompleteData < StandardError; end

  def self.run
    new.run
  end

  def initialize
    @agent = Mechanize.new
    if ENV["MORPH_AUSTRALIAN_PROXY"]
      # On morph.io set the environment variable MORPH_AUSTRALIAN_PROXY to
      # http://morph:password@au.proxy.oaf.org.au:8888 replacing password with
      # the real password.
      puts "Using Australian proxy..."
      @agent.agent.set_proxy(ENV["MORPH_AUSTRALIAN_PROXY"])
    end
    @requests = 0
  end

  def run
    puts "Running ruby #{RUBY_VERSION}"
    electorates = scrape_electorates
    puts "Found #{electorates.size} electorates"
    localities = electorates.to_h do |name, url|
      rows = scrape_localities(url)
      puts "#{name}: #{rows.size} records"
      [name, rows]
    end
    records = self.class.validate!(localities)
    save(records)
    puts "", "Finished - saved #{records.size} records from #{@requests} requests"
  end

  # Electorate names mapped to the URLs of their locality lists
  def self.parse_electorates(doc)
    data_rows(doc.at(ELECTORATES_TABLE)).to_h do |row|
      link = row.at("a")
      [clean(link.text), URI.join(LISTING_URL, link["href"]).to_s]
    end
  end

  # One record for each locality and electorate, current or redistributed
  def self.parse_localities(doc)
    data_rows(doc.at(LOCALITIES_TABLE)).flat_map do |row|
      state, locality, postcode, current, redistributed, other = row.xpath("./td").to_a
      locality_record = {
        "state" => clean(state.text),
        "locality" => clean(locality.text),
        "postcode" => clean(postcode.text),
        "other_localities" => clean(other.text),
      }
      { "current" => current, "redistributed" => redistributed }.flat_map do |type, cell|
        cell.css("a").map do |link|
          locality_record.merge("electorate" => clean(link.text), "electorate_type" => type)
        end
      end
    end
  end

  # The page number shown, or nil when the list fits on one page
  def self.current_page_number(doc)
    doc.at("tr.pagingLink span")&.text&.to_i
  end

  # The [__EVENTTARGET, __EVENTARGUMENT] that fetches the page after the
  # current one, or nil on the last page. Later pages are behind a "..." link,
  # so this looks for the next page number rather than collecting links.
  def self.next_page_postback(doc)
    current = current_page_number(doc)
    return unless current

    doc.css("tr.pagingLink a").each do |link|
      postback = link["href"].to_s.match(/__doPostBack\('([^']+)','([^']+)'\)/)&.captures
      return postback if postback&.last == "Page$#{current + 1}"
    end
    nil
  end

  # Checks every electorate has localities, and every locality's current
  # electorate is in the list, then returns all the records
  def self.validate!(localities)
    empty = localities.select { |_name, rows| rows.empty? }.keys
    raise IncompleteData, "No localities found for #{empty.join(', ')}" if empty.any?

    records = localities.values.flatten.uniq
    current = records.select { |r| r["electorate_type"] == "current" }.map { |r| r["electorate"] }.uniq
    unknown = current - localities.keys
    raise IncompleteData, "Electorates not in the list: #{unknown.join(', ')}" if unknown.any?

    missing = localities.reject { |name, rows| rows.any? { |r| r["electorate"] == name } }.keys
    raise IncompleteData, "Electorates missing from their own pages: #{missing.join(', ')}" if missing.any?

    odd_postcodes = records.map { |r| r["postcode"] }.uniq.grep_v(/\A\d{4}\z/)
    puts "WARNING: #{odd_postcodes.size} postcodes aren't 4 digits: #{odd_postcodes.join(', ')}" if odd_postcodes.any?

    records
  end

  def self.data_rows(table)
    raise IncompleteData, "Results table not found" unless table

    table.xpath("./tr | ./tbody/tr").reject { |row| %w[headingLink pagingLink].include?(row["class"]) }
  end

  def self.clean(text)
    text.tr(" ", " ").strip
  end

  private_class_method :data_rows, :clean

  private

  def scrape_electorates
    electorates = {}
    each_page(LISTING_URL) { |page| electorates.merge!(self.class.parse_electorates(page)) }
    electorates
  end

  def scrape_localities(url)
    rows = []
    each_page(url) { |page| rows.concat(self.class.parse_localities(page)) }
    rows
  end

  def each_page(url)
    page = fetch { @agent.get(url) }
    loop do
      yield page
      target, argument = self.class.next_page_postback(page)
      break unless target

      expected = self.class.current_page_number(page) + 1
      form = page.form_with(id: FORM_ID)
      form["__EVENTTARGET"] = target
      form["__EVENTARGUMENT"] = argument
      page = fetch { @agent.submit(form) }
      shown = self.class.current_page_number(page)
      raise IncompleteData, "Asked for page #{expected} of #{url} but got #{shown}" unless shown == expected
    end
  end

  def fetch
    @requests += 1
    yield
  end

  # Replaces the previous run's data in one transaction, so electorates that
  # no longer exist are removed and a failure part way through keeps the old data
  def save(records)
    ScraperWiki.sqliteexecute("BEGIN")
    begin
      ScraperWiki.sqliteexecute("DELETE FROM data")
    rescue SqliteMagic::NoSuchTable
      # First run
    end
    ScraperWiki.save_sqlite(UNIQUE_KEY, records)
    ScraperWiki.sqliteexecute("COMMIT")
  end
end

# Run the scraper whilst allowing this file to be required in tests without auto-execution
Scraper.run if __FILE__ == $PROGRAM_NAME
